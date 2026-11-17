import { keyframeFileRoutes } from './keyframe-files.mjs';
import { imageGenerations } from './image-generations.mjs';
import { gpuAdmission as createGPUAdmission } from './gpu-admission.mjs';
import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { createReadStream, mkdirSync } from 'node:fs';
import { mkdir, stat, rename, rm, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { APIError, requireThat, uuid, nonempty, dateString, validateGaussian, validateVideo, validateJPEG } from './validation.mjs';
import { receiveUpload, uploadMime } from './uploads.mjs';
import { validateCaptureMetadata } from './capture-v2.mjs';
import { makeViewerDerivative, VIEWER_VERSION, VIEWER_BUDGETS } from './viewer.mjs';
import { reconstructionStudyStore } from './reconstruction-studies.mjs';
import { videoReconstructionStore } from './video-reconstructions.mjs';
import { resumableUploads } from './resumable-upload.mjs';
import { KEYFRAME_PACK_MIME, MAX_KEYFRAME_PACK, extractKeyframePack, packPublic } from './keyframe-pack.mjs';

const VERSION = '0.1.0';
const CONSENT = '2026-10-22-v1';
const MAX_VIDEO = 500 * 1024 * 1024;
const MAX_MODEL = 150 * 1024 * 1024;
const MAX_PREVIEW = 5 * 1024 * 1024;
const MAX_CAPTURE_METADATA = 16 * 1024 * 1024;
const QUESTS = { first_light: 'lobby', rest_stop: 'rest', connecting_paths: 'road', green_corner: 'green', reading_nook: 'reading', market_stall: 'stall', repair_view: 'road' };
const sha = value => createHash('sha256').update(value).digest('hex');
const now = () => new Date().toISOString();
const parse = value => value ? JSON.parse(value) : null;
const json = (res, status, body) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(JSON.stringify(body));
};

// A GameSnapshot contains required IDs inside session/video/event records. Remove
// those records rather than nulling their IDs, which would break Swift Codable.
// Unknown/custom game JSON stays supported; only matching source references change.
function scrubGameBackup(value, deletedSessionIds, deletedAssetIds = new Set()) {
  const deletedReference = item => typeof item === 'string' && (deletedSessionIds.has(item) || deletedAssetIds.has(item));
  function scrub(item, key = '') {
    if (Array.isArray(item)) {
      let remaining = item;
      if (key === 'sessions') remaining = item.filter(entry => !deletedSessionIds.has(entry?.session?.id));
      if (key === 'videos') remaining = item.filter(entry => !deletedSessionIds.has(entry?.sessionId));
      if (key === 'events') remaining = item.filter(entry => !deletedSessionIds.has(entry?.sessionId) && !deletedAssetIds.has(entry?.assetId));
      if (key === 'sourceSessionIds') remaining = item.filter(entry => !deletedSessionIds.has(entry));
      return remaining.map(entry => scrub(entry));
    }
    if (item && typeof item === 'object') {
      if (key === 'pendingRequest' && (deletedSessionIds.has(item.id) || deletedSessionIds.has(item.parentSessionId))) return null;
      return Object.fromEntries(Object.entries(item).map(([name, entry]) => [name, scrub(entry, name)]));
    }
    return deletedReference(item) ? null : item;
  }
  return scrub(value);
}

async function bodyJSON(req, limit = 1024 * 1024) {
  requireThat((req.headers['content-type'] ?? '').split(';')[0] === 'application/json', 415, 'content_type', 'Send application/json.');
  const chunks = [];
  let length = 0;
  for await (const chunk of req) {
    length += chunk.length;
    requireThat(length <= limit, 413, 'body_too_large', 'JSON request exceeds the allowed size.');
    chunks.push(chunk);
  }
  let result;
  try { result = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new APIError(400, 'invalid_json', 'Request body is not valid JSON.'); }
  requireThat(result && typeof result === 'object' && !Array.isArray(result), 400, 'invalid_json', 'Expected a JSON object.');
  return result;
}

/** Create a persistent service without listening; used by CLI and integration tests.
 * closeDatabase() must be called after server.close() when embedding the service.
 */
export function createServer({ dataDir, adminToken, logger = console, limits = {}, gpuAdmission = null, imageGeneration = null, imageBridge = null } = {}) {
  requireThat(nonempty(dataDir, 4096), 500, 'configuration', 'A data directory is required.');
  requireThat(typeof adminToken === 'string' && adminToken.length >= 32, 500, 'configuration', 'Admin token must contain at least 32 characters.');
  const root = path.resolve(dataDir);
  const tmpRoot = path.join(root, '.tmp');
  mkdirSync(tmpRoot, { recursive: true });
  const db = new DatabaseSync(path.join(root, 'pocketworld.sqlite'));
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
    PRAGMA busy_timeout = 5000;
    CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, tokenHash TEXT NOT NULL UNIQUE, createdAt TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, userId TEXT NOT NULL, json TEXT NOT NULL, videoPath TEXT, videoHash TEXT, videoSize INTEGER, videoMime TEXT, previewPath TEXT);
    CREATE INDEX IF NOT EXISTS sessions_owner ON sessions(userId);
    CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, sessionId TEXT NOT NULL UNIQUE, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS assets (id TEXT PRIMARY KEY, sessionId TEXT NOT NULL UNIQUE, userId TEXT NOT NULL, json TEXT NOT NULL, filePath TEXT NOT NULL, byteSize INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS rewards (sessionId TEXT PRIMARY KEY, userId TEXT NOT NULL, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, userId TEXT NOT NULL, sessionId TEXT, assetId TEXT, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS games (userId TEXT PRIMARY KEY, json TEXT NOT NULL, updatedAt TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS tombstones (id TEXT PRIMARY KEY, userId TEXT NOT NULL, deletedAt TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS audit (id TEXT PRIMARY KEY, sessionId TEXT, json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS captures_v2 (id TEXT PRIMARY KEY, userId TEXT NOT NULL, createJson TEXT NOT NULL, rgbPath TEXT, rgbHash TEXT, rgbSize INTEGER, rgbMime TEXT, metadataPath TEXT, metadataHash TEXT, metadataSize INTEGER, receiptId TEXT, verifiedAt TEXT, validationJson TEXT, createdAt TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS captures_v2_owner ON captures_v2(userId);
    CREATE TABLE IF NOT EXISTS capture_tombstones_v2 (id TEXT PRIMARY KEY, userId TEXT NOT NULL, deletedAt TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS ff_links_v2 (captureId TEXT PRIMARY KEY, userId TEXT NOT NULL, sessionId TEXT NOT NULL UNIQUE, createdAt TEXT NOT NULL, FOREIGN KEY(captureId) REFERENCES captures_v2(id));
  `);
  // Keyframe pack columns (2026-11-09): added in place so existing databases keep their rows.
  {
    const columns = new Set(db.prepare('PRAGMA table_info(captures_v2)').all().map(c => c.name));
    for (const [name, type] of Object.entries({ keyframesPath: 'TEXT', keyframesHash: 'TEXT', keyframesSize: 'INTEGER', keyframesJson: 'TEXT' })) {
      if (!columns.has(name)) db.exec(`ALTER TABLE captures_v2 ADD COLUMN ${name} ${type}`);
    }
  }
  const locks = new Map();
  const studies = reconstructionStudyStore(db);
  const videoReconstructions = videoReconstructionStore(db, { dataDir: root });
  const admitGPU = typeof gpuAdmission === 'function' ? gpuAdmission : gpuAdmission ? createGPUAdmission(gpuAdmission) : null;
  const checkGPU = async roles => {
    if (admitGPU && roles.length) await admitGPU(roles,
      db.prepare("SELECT role FROM video_reconstruction_tasks_v2 WHERE status = 'queued'").all().map(row => row.role).concat(Array(images.countQueued()).fill('image')));
  };
  const images = imageGenerations(db,{root,config:imageGeneration,bridge:imageBridge,locked,checkGPU,sendFile,json,bodyJSON});
  const keyframeFiles = keyframeFileRoutes({root,ownCapture,captureStatus,acceptKeyframes,locked,bodyJSON,json});
  const registerWindows = new Map();
  const adminHash = Buffer.from(sha(adminToken));
  const errors = { malformed: 'Check the request fields and retry.' };

  function transaction(action) {
    db.exec('BEGIN IMMEDIATE');
    try { const result = action(); db.exec('COMMIT'); return result; }
    catch (error) { db.exec('ROLLBACK'); throw error; }
  }
  async function locked(id, action) {
    const previous = locks.get(id) ?? Promise.resolve();
    let release;
    const next = new Promise(resolve => { release = resolve; });
    locks.set(id, next);
    await previous;
    try { return await action(); }
    finally { release(); if (locks.get(id) === next) locks.delete(id); }
  }
  function sessionRow(id) {
    requireThat(uuid(id), 400, 'invalid_id', 'Invalid session ID.');
    const row = db.prepare('SELECT * FROM sessions WHERE id = ?').get(id);
    requireThat(row, 404, 'session_not_found', 'Session not found.');
    return row;
  }
  function ownSession(id, userId) {
    const row = sessionRow(id);
    requireThat(row.userId === userId, 404, 'session_not_found', 'Session not found.');
    return row;
  }
  function ownCapture(id, userId) {
    requireThat(uuid(id), 400, 'invalid_id', 'Invalid capture ID.');
    const row = db.prepare('SELECT * FROM captures_v2 WHERE id = ?').get(id);
    requireThat(row && row.userId === userId, 404, 'capture_not_found', 'Capture not found.');
    return row;
  }
  function captureStatus(row) {
    const source = parse(row.createJson);
    const validation = parse(row.validationJson);
    return { id: row.id, sceneId: source.sceneId, environment: source.environment,
      consentVersion: source.consentVersion, status: row.verifiedAt ? 'rgb_metadata_verified' : 'draft',
      rgb: row.rgbHash ? { sha256: row.rgbHash, byteSize: row.rgbSize, mime: row.rgbMime } : null,
      metadata: row.metadataHash ? { sha256: row.metadataHash, byteSize: row.metadataSize } : null,
      receipt: row.receiptId ? { captureReceiptId: row.receiptId, verifiedAt: row.verifiedAt,
        scope: 'rgb_metadata_verified', ...validation } : null,
      ...(row.keyframesHash ? { keyframes: packPublic(parse(row.keyframesJson)) } : {}),
      createdAt: row.createdAt };
  }
  function assetRow(id, userId) {
    const row = db.prepare('SELECT * FROM assets WHERE id = ?').get(id);
    requireThat(row && (!userId || row.userId === userId), 404, 'asset_not_found', 'Asset not found.');
    return row;
  }
  function saveSession(session) { db.prepare('UPDATE sessions SET json = ? WHERE id = ?').run(JSON.stringify(session), session.id); }
  function saveJob(job) { db.prepare('INSERT INTO jobs (id, sessionId, json) VALUES (?, ?, ?) ON CONFLICT(sessionId) DO UPDATE SET json = excluded.json').run(job.id, job.sessionId, JSON.stringify(job)); }
  function envelope(id) {
    const row = sessionRow(id);
    return {
      session: parse(row.json),
      job: parse(db.prepare('SELECT json FROM jobs WHERE sessionId = ?').get(id)?.json),
      asset: parse(db.prepare('SELECT json FROM assets WHERE sessionId = ?').get(id)?.json),
      reward: parse(db.prepare('SELECT json FROM rewards WHERE sessionId = ?').get(id)?.json),
    };
  }
  function ffStatus(captureId, userId) {
    const link = db.prepare('SELECT * FROM ff_links_v2 WHERE captureId = ?').get(captureId);
    if (!link) return null;
    requireThat(link.userId === userId, 404, 'capture_not_found', 'Capture not found.');
    const result = envelope(link.sessionId);
    requireThat(result.session.userId === userId && result.session.linkedCaptureId === captureId && result.job, 500, 'ff_link_invalid', 'FF task link is inconsistent.');
    const ff = { captureId, jobId: result.job.id, status: result.job.status };
    if (result.job.status === 'ready' && result.asset) {
      ff.assetId = result.asset.id;
      ff.viewerInfoPath = `/v1/assets/${result.asset.id}/viewer-info?maxPoints=60000`;
      ff.viewerPath = `/v1/assets/${result.asset.id}/viewer?maxPoints=60000`;
    }
    if (result.job.status === 'failed' && result.job.errorMessage) ff.errorMessage = result.job.errorMessage;
    return ff;
  }
  function logAudit(sessionId, action, details = {}) {
    const record = { id: randomUUID(), occurredAt: now(), action, ...details };
    db.prepare('INSERT INTO audit (id, sessionId, json) VALUES (?, ?, ?)').run(record.id, sessionId, JSON.stringify(record));
  }
  function serverEvent(userId, name, sessionId, assetId, properties = {}) {
    const event = { id: randomUUID(), name, occurredAt: now(), sessionId, assetId, properties: { ...properties, origin: 'server' } };
    db.prepare('INSERT INTO events (id, userId, sessionId, assetId, json) VALUES (?, ?, ?, ?, ?)').run(event.id, userId, sessionId ?? null, assetId ?? null, JSON.stringify(event));
  }
  function authenticate(req, admin = false) {
    const match = /^Bearer ([A-Za-z0-9_-]{32,200})$/.exec(req.headers.authorization ?? '');
    requireThat(match, 401, 'unauthorized', 'A valid bearer token is required.');
    const tokenHash = sha(match[1]);
    if (admin) {
      requireThat(timingSafeEqual(Buffer.from(tokenHash), adminHash), 401, 'unauthorized', 'Admin authentication failed.');
      return null;
    }
    const user = db.prepare('SELECT id FROM users WHERE tokenHash = ?').get(tokenHash);
    requireThat(user, 401, 'unauthorized', 'User authentication failed.');
    return user.id;
  }
  function safeFile(relative) {
    const absolute = path.resolve(root, relative);
    requireThat(absolute.startsWith(root + path.sep), 500, 'invalid_storage_path', 'Invalid storage path.');
    return absolute;
  }
  async function upload(req, limit) {
    return receiveUpload(req, tmpRoot, limit);
  }
  async function fileHash(relative) {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(safeFile(relative))) hash.update(chunk);
    return hash.digest('hex');
  }
  // Resumable original-video uploads for native captures (single-request PUT stays supported).
  const rgbUploads = resumableUploads({ limit: limits.video ?? MAX_VIDEO });
  const rgbUploadDirectory = id => safeFile(path.join('captures-v2', id, 'rgb-upload'));
  // Resumable keyframe packs for the ARKit pose cloud branch (see keyframe-pack.mjs).
  const keyframeUploads = resumableUploads({ limit: MAX_KEYFRAME_PACK, types: new Set([KEYFRAME_PACK_MIME]) });
  const keyframeUploadDirectory = id => safeFile(path.join('captures-v2', id, 'keyframes-upload'));
  /** Verifies a complete pack against the verified capture metadata and stores it, once. */
  async function acceptKeyframes(row, id, userId, file) {
    if (row.keyframesHash) {
      requireThat(row.keyframesHash === file.hash, 409, 'keyframes_conflict', 'This capture already has a different keyframe pack.');
      return captureStatus(row);
    }
    requireThat(row.verifiedAt && row.receiptId && row.metadataPath, 409, 'capture_incomplete', 'Verify the capture before adding keyframes.');
    requireThat(await fileHash(row.metadataPath) === row.metadataHash, 409, 'metadata_changed', 'Verified capture metadata changed.');
    const metadata = JSON.parse(await readFile(safeFile(row.metadataPath), 'utf8'));
    const relative = path.join('captures-v2', id, 'keyframes');
    const summary = await extractKeyframePack(file.temporary, safeFile(relative), { captureId: id, framesJSONL: metadata.framesJSONL });
    requireThat(summary.sha256 === file.hash && summary.byteSize === file.size, 500, 'keyframes_changed', 'Keyframe pack changed while it was stored.');
    db.prepare('UPDATE captures_v2 SET keyframesPath = ?, keyframesHash = ?, keyframesSize = ?, keyframesJson = ? WHERE id = ?')
      .run(relative, summary.sha256, summary.byteSize, JSON.stringify(summary), id);
    return captureStatus(ownCapture(id, userId));
  }
  async function requireManifestVideo(row, sha256, mime) {
    if (!row.metadataPath) return;
    const metadata = JSON.parse(await readFile(safeFile(row.metadataPath), 'utf8'));
    requireThat(metadata.manifest.videoSHA256 === sha256, 409, 'video_manifest_mismatch', 'Uploaded video does not match the immutable capture manifest.');
    requireThat(metadata.manifest.videoFile === (mime === 'video/quicktime' ? 'video.mov' : 'video.mp4'), 409, 'video_manifest_mismatch', 'Uploaded video type does not match the immutable capture manifest.');
  }
  /** Stores verified original-video bytes for a capture; shared by both upload paths. */
  async function acceptCaptureRgb(row, id, userId, mime, file) {
    if (row.rgbHash) {
      requireThat(row.rgbHash === file.hash && row.rgbMime === mime, 409, 'rgb_conflict', 'Capture already has different video bytes.');
      let intact = false;
      try { intact = await fileHash(row.rgbPath) === row.rgbHash; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (!intact) {
        await validateVideo(file.temporary);
        await mkdir(path.dirname(safeFile(row.rgbPath)), { recursive: true });
        await rm(safeFile(row.rgbPath), { force: true });
        await rename(file.temporary, safeFile(row.rgbPath));
      }
      return captureStatus(row);
    }
    await validateVideo(file.temporary);
    await requireManifestVideo(row, file.hash, mime);
    const relative = path.join('captures-v2', id, mime === 'video/quicktime' ? 'video.mov' : 'video.mp4');
    await mkdir(path.dirname(safeFile(relative)), { recursive: true });
    await rename(file.temporary, safeFile(relative));
    db.prepare('UPDATE captures_v2 SET rgbPath = ?, rgbHash = ?, rgbSize = ?, rgbMime = ? WHERE id = ?').run(relative, file.hash, file.size, mime, id);
    return captureStatus(ownCapture(id, userId));
  }
  async function sendFile(req, res, relative, mime, hash, extraHeaders = {}) {
    const absolute = safeFile(relative);
    let info;
    try { info = await stat(absolute); }
    catch { throw new APIError(404, 'file_missing', 'Stored file is unavailable.'); }
    const headers = { 'Content-Type': mime, 'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff', 'Accept-Ranges': 'bytes', ...extraHeaders };
    if (hash) headers['X-Content-SHA256'] = hash;
    const range = req.headers.range;
    let start = 0, end = info.size - 1, status = 200;
    if (range) {
      const match = /^bytes=(\d+)-(\d*)$/.exec(range);
      requireThat(match, 416, 'invalid_range', 'Only a single byte range is supported.');
      start = Number(match[1]); end = match[2] ? Math.min(Number(match[2]), end) : end;
      requireThat(Number.isSafeInteger(start) && start >= 0 && start <= end && start < info.size, 416, 'invalid_range', 'Requested range is outside the file.');
      headers['Content-Range'] = `bytes ${start}-${end}/${info.size}`; status = 206;
    }
    headers['Content-Length'] = end - start + 1;
    res.writeHead(status, headers);
    await pipeline(createReadStream(absolute, { start, end }), res);
  }
  async function viewerDerivative(row, maxPoints) {
    const asset = parse(row.json);
    const relative = path.join('sessions', row.sessionId, 'viewer', `${VIEWER_VERSION}-${maxPoints}.splat`);
    const sidecar = safeFile(relative + '.json');
    try {
      const info = JSON.parse(await readFile(sidecar, 'utf8'));
      const cached = await stat(safeFile(relative));
      if (info.derivativeVersion === VIEWER_VERSION && info.sourceSha256 === asset.sha256 && info.sourceAssetId === asset.id && info.maxPoints === maxPoints && cached.size === info.byteSize) return { relative, info };
    } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    const { bytes, info } = await makeViewerDerivative(safeFile(row.filePath), asset, maxPoints);
    await mkdir(path.dirname(sidecar), { recursive: true });
    const temporary = `${safeFile(relative)}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, bytes, { flag: 'wx' });
      await rename(temporary, safeFile(relative));
      await writeFile(sidecar, JSON.stringify(info, null, 2) + '\n');
    } finally { await rm(temporary, { force: true }); }
    return { relative, info };
  }
  async function importAsset(req, sessionId, format, tool, version, userId, plyProfile = null) {
    requireThat(plyProfile == null || (plyProfile === 'worldmirror2-probability-v1' && format === 'ply' && tool === 'WorldMirror2' && userId == null), 400, 'invalid_ply_profile', 'Only an operator may declare the verified WorldMirror2 probability export profile.');
    requireThat(nonempty(tool, 120), 400, 'tool_required', 'Record the actual reconstruction software name.');
    requireThat(version == null || nonempty(version, 120), 400, 'invalid_version', 'Invalid reconstruction version.');
    requireThat(['ply', 'splat'].includes(format), 415, 'unsupported_model', 'Export a Gaussian .ply or .splat file. SPZ is not supported in this MVP.');
    const row = sessionRow(sessionId);
    const linkedSession = parse(row.json);
    if (linkedSession.linkedCaptureId) {
      const link = db.prepare('SELECT * FROM ff_links_v2 WHERE captureId = ?').get(linkedSession.linkedCaptureId);
      const source = db.prepare('SELECT * FROM captures_v2 WHERE id = ?').get(linkedSession.linkedCaptureId);
      requireThat(link?.sessionId === sessionId && link.userId === row.userId && source?.userId === row.userId && source.verifiedAt && source.rgbHash === row.videoHash && source.metadataHash === linkedSession.linkedCaptureMetadataSHA256, 409, 'ff_source_unavailable', 'The linked source capture is unavailable or changed.');
      const linkedJob = parse(db.prepare('SELECT json FROM jobs WHERE sessionId = ?').get(sessionId)?.json);
      requireThat(tool === 'WorldMirror2' && linkedJob && ((linkedJob.status === 'processing' && uuid(linkedJob.workerClaimId)) || linkedJob.status === 'ready'), 409, 'ff_worker_required', 'Only a claimed WorldMirror2 worker may publish this FF result.');
    }
    if (userId) {
      requireThat(row.userId === userId, 404, 'session_not_found', 'Session not found.');
      requireThat(parse(row.json).captureMode === 'external_app', 409, 'wrong_capture_mode', 'This upload endpoint is for external scanner assets.');
    } else {
      const processing = db.prepare('SELECT json FROM jobs WHERE sessionId = ?').get(sessionId);
      requireThat(processing, 409, 'job_required', 'Submit the session before importing its result.');
      requireThat(parse(processing.json).status !== 'cancelled', 409, 'job_cancelled', 'Cancelled jobs require an explicit requeue before importing a result.');
    }
    const file = await upload(req, limits.model ?? MAX_MODEL);
    try {
      const existing = db.prepare('SELECT json FROM assets WHERE sessionId = ?').get(sessionId);
      if (existing) {
        const asset = parse(existing.json);
        requireThat(asset.sha256 === file.hash && asset.format === format && (asset.plyProfile ?? null) === plyProfile, 409, 'asset_conflict', 'This session already has a different result/profile. Create a linked recapture session.');
        return envelope(sessionId);
      }
      let opacityIndex;
      const validation = await validateGaussian(file.temporary, format, plyProfile ? {
        onHeader(header) { opacityIndex = header.properties.findIndex(property => property.name === 'opacity'); },
        onRecord(record) { requireThat(record[opacityIndex] >= 0 && record[opacityIndex] <= 1, 422, 'invalid_probability_opacity', 'Declared WorldMirror opacity must be a probability in [0, 1].'); },
      } : {});
      const relative = path.join('sessions', sessionId, 'result', `scene.${format}`);
      await mkdir(path.dirname(safeFile(relative)), { recursive: true });
      await rename(file.temporary, safeFile(relative));
      const session = parse(row.json);
      const timestamp = now();
      const asset = {
        id: randomUUID(), sourceSessionIds: [sessionId], kind: 'gaussian_splat', format,
        sha256: file.hash, provenance: session.provenance, reconstructionTool: tool,
        ...(version ? { reconstructionVersion: version } : {}),
        ...(plyProfile ? { plyProfile } : {}),
        lineageStatus: 'declared', qualityStatus: 'needs_review', dualUseStatus: 'not_evaluated',
        createdAt: timestamp, gaussianCount: validation.gaussianCount,
      };
      transaction(() => {
        db.prepare('INSERT INTO assets (id, sessionId, userId, json, filePath, byteSize) VALUES (?, ?, ?, ?, ?, ?)').run(asset.id, sessionId, row.userId, JSON.stringify(asset), relative, file.size);
        if (session.captureMode === 'external_app') {
          session.captureStatus = 'asset_imported'; session.submittedAt = timestamp; saveSession(session);
        }
        const job = parse(db.prepare('SELECT json FROM jobs WHERE sessionId = ?').get(sessionId)?.json) ?? { id: randomUUID(), sessionId, provider: 'manual', createdAt: timestamp };
        Object.assign(job, { status: 'ready', resultAssetId: asset.id, completedAt: timestamp });
        delete job.errorMessage; saveJob(job);
        logAudit(sessionId, 'asset_imported', { assetId: asset.id, tool, version, sha256: file.hash, validation, sourceClaim: 'Operator/user declaration; not independently verified.' });
        serverEvent(row.userId, 'result_ready', sessionId, asset.id, { captureMode: session.captureMode, environment: session.environment, provenance: session.provenance });
      });
      return envelope(sessionId);
    } finally { await rm(file.temporary, { force: true }); }
  }

  async function route(req, res) {
    requireThat(req.url && req.url.length <= 8192, 414, 'uri_too_long', 'Request URL is too long.');
    const url = new URL(req.url, 'http://localhost');
    const routePath = url.pathname;
    const method = req.method;
    // `features` lets clients enable newer flows only where the deployed server supports them.
    if (method === 'GET' && routePath === '/health') return json(res, 200, { ok: true, version: VERSION, features: ['resumable-rgb-upload', 'arkit-prior-training', 'arkit-keyframes', 'sfm-subject-keyframes', 'reconstruction-selection', 'keyframe-files', ...(admitGPU ? ['gpu-admission'] : []), ...(imageGeneration || imageBridge ? ['single-image-generation', 'single-image-result-recovery'] : [])] });
    if (method === 'POST' && routePath === '/v1/auth/anonymous') {
      await bodyJSON(req, 4096);
      const ip = req.socket.remoteAddress ?? 'local';
      const window = registerWindows.get(ip) ?? { count: 0, expires: 0 };
      if (Date.now() >= window.expires) { window.count = 0; window.expires = Date.now() + 600_000; }
      requireThat(window.count++ < 60, 429, 'registration_limit', 'Too many anonymous registrations. Retry later.');
      registerWindows.set(ip, window);
      const userId = randomUUID(), token = randomBytes(32).toString('base64url');
      db.prepare('INSERT INTO users (id, tokenHash, createdAt) VALUES (?, ?, ?)').run(userId, sha(token), now());
      return json(res, 201, { userId, token });
    }

    if (routePath.startsWith('/v1/admin/')) {
      authenticate(req, true);
      if (method === 'GET' && routePath === '/v1/admin/jobs') {
        const rows = db.prepare('SELECT sessionId FROM jobs ORDER BY rowid DESC').all();
        return json(res, 200, { jobs: rows.map(row => envelope(row.sessionId)) });
      }
      if (method === 'GET' && routePath === '/v1/admin/metrics') {
        const sessions = db.prepare('SELECT json FROM sessions').all().map(row => parse(row.json));
        const jobs = db.prepare('SELECT json FROM jobs').all().map(row => parse(row.json));
        const assets = db.prepare('SELECT json FROM assets').all().map(row => parse(row.json));
        const events = db.prepare('SELECT json, userId FROM events').all().map(row => ({ ...parse(row.json), userId: row.userId }));
        const group = (items, key) => items.reduce((counts, item) => { const value = item[key] ?? 'unknown'; counts[value] = (counts[value] ?? 0) + 1; return counts; }, {});
        return json(res, 200, {
          generatedAt: now(), users: db.prepare('SELECT COUNT(*) AS n FROM users').get().n,
          sessions: sessions.length, sessionsByMode: group(sessions, 'captureMode'), sessionsByEnvironment: group(sessions, 'environment'),
          jobsByStatus: group(jobs, 'status'), assetsByQuality: group(assets, 'qualityStatus'), assetsByDualUse: group(assets, 'dualUseStatus'),
          rewards: db.prepare('SELECT COUNT(*) AS n FROM rewards').get().n,
          eventsByName: group(events, 'name'), activeUsers: new Set(events.map(e => e.userId)).size,
          notes: ['Counts are operational telemetry, not proof of reconstruction quality or retention.', 'Client and server events may share a name; deduplicate by session/user for funnel analysis.', 'Deleted sessions and their media/events are excluded; minimal reward tombstones remain.'],
        });
      }
      if (method === 'GET' && routePath === '/v1/admin/events') {
        const rows = db.prepare('SELECT userId, json FROM events ORDER BY rowid').all();
        return json(res, 200, { events: rows.map(row => ({ ...parse(row.json), userId: row.userId })) });
      }
      let match = /^\/v1\/admin\/sessions\/([^/]+)\/bundle$/.exec(routePath);
      if (method === 'GET' && match) {
        const id = match[1], row = sessionRow(id), contents = envelope(id);
        const asset = db.prepare('SELECT * FROM assets WHERE sessionId = ?').get(id);
        const files = [];
        if (row.videoPath) files.push({ path: row.videoMime === 'video/quicktime' ? 'capture.mov' : 'capture.mp4', url: `/v1/admin/sessions/${id}/video`, sha256: row.videoHash, size: row.videoSize });
        if (row.previewPath) files.push({ path: 'preview.jpg', url: `/v1/admin/sessions/${id}/preview` });
        if (asset) files.push({ path: `result/scene.${contents.asset.format}`, url: `/v1/admin/assets/${asset.id}/file`, sha256: contents.asset.sha256, size: asset.byteSize });
        return json(res, 200, {
          manifest: { schemaVersion: 1, exportedAt: now(), ...contents.session,
            missingFields: contents.session.linkedCaptureId ? ['metric_scale', 'collision_geometry'] : ['camera_poses', 'camera_intrinsics', 'metric_scale', 'collision_geometry'],
            videoMetadataSource: contents.session.linkedCaptureId ? 'v2_capture_verified_metadata' : contents.session.rawDataAvailable ? 'client_reported' : 'unavailable',
            videoValidation: contents.session.linkedCaptureId ? 'container_box_structure_and_v2_metadata_integrity' : contents.session.rawDataAvailable ? 'container_box_structure_only' : 'not_applicable',
            consentScope: 'MVP capture storage and evaluation; model training requires separate applicable permission.', asset: contents.asset },
          processing: { job: contents.job, audit: db.prepare('SELECT json FROM audit WHERE sessionId = ? ORDER BY rowid').all(id).map(a => parse(a.json)) },
          events: db.prepare('SELECT json FROM events WHERE sessionId = ? ORDER BY rowid').all(id).map(e => parse(e.json)),
          quality: contents.asset ? { lineageStatus: contents.asset.lineageStatus, qualityStatus: contents.asset.qualityStatus, dualUseStatus: contents.asset.dualUseStatus, review: contents.asset.review ?? null } : null,
          files,
        });
      }
      match = /^\/v1\/admin\/sessions\/([^/]+)\/(video|preview)$/.exec(routePath);
      if (method === 'GET' && match) {
        const row = sessionRow(match[1]);
        const isVideo = match[2] === 'video';
        requireThat(isVideo ? row.videoPath : row.previewPath, 404, 'file_missing', 'No such file in this session.');
        return sendFile(req, res, isVideo ? row.videoPath : row.previewPath, isVideo ? row.videoMime : 'image/jpeg', isVideo ? row.videoHash : undefined);
      }
      match = /^\/v1\/admin\/assets\/([^/]+)\/file$/.exec(routePath);
      if (method === 'GET' && match) {
        const row = assetRow(match[1]); return sendFile(req, res, row.filePath, 'application/octet-stream', parse(row.json).sha256);
      }
      match = /^\/v1\/admin\/jobs\/([^/]+)\/(status|asset)$/.exec(routePath);
      if (method === 'PUT' && match) {
        const jobRow = db.prepare('SELECT sessionId FROM jobs WHERE id = ?').get(match[1]);
        requireThat(jobRow, 404, 'job_not_found', 'Job not found.');
        return locked(jobRow.sessionId, async () => {
          const state = envelope(jobRow.sessionId);
          if (match[2] === 'asset') return json(res, 200, await importAsset(req, jobRow.sessionId, url.searchParams.get('format'), url.searchParams.get('tool'), url.searchParams.get('version'), null, url.searchParams.get('plyProfile')));
          const body = await bodyJSON(req, 16384);
          requireThat(['queued', 'processing', 'failed', 'cancelled'].includes(body.status), 400, 'invalid_status', 'Use queued, processing, failed or cancelled. Ready requires a valid asset import.');
          if (body.expectedStatus !== undefined) requireThat(body.expectedStatus === state.job.status, 409, 'job_status_conflict', 'The job state changed; refresh before updating it.');
          if (body.workerClaimId !== undefined) requireThat(uuid(body.workerClaimId), 400, 'invalid_worker_claim', 'Worker claim ID must be a UUID.');
          if (state.session.linkedCaptureId && body.status === 'processing') requireThat(uuid(body.workerClaimId), 409, 'ff_worker_required', 'A claimed WorldMirror2 worker is required for this FF task.');
          if (state.job.workerClaimId && body.workerClaimId && state.job.workerClaimId !== body.workerClaimId && state.job.status === 'processing') requireThat(false, 409, 'worker_claim_conflict', 'Another worker owns this processing job.');
          requireThat(state.job.status !== 'ready', 409, 'result_immutable', 'A ready result is immutable. Create a linked recapture instead.');
          requireThat(state.job.status !== 'cancelled' || ['queued', 'cancelled'].includes(body.status), 409, 'job_cancelled', 'Cancelled jobs require an explicit requeue.');
          if (body.status === 'failed') requireThat(nonempty(body.errorMessage, 2000), 400, 'reason_required', 'Record the processing failure reason.');
          const job = { ...state.job, status: body.status, updatedAt: now() };
          if (body.status === 'processing') { job.startedAt = now(); if (body.workerClaimId) job.workerClaimId = body.workerClaimId; }
          if (body.status === 'queued') delete job.workerClaimId;
          if (body.status === 'failed') job.errorMessage = body.errorMessage;
          else delete job.errorMessage;
          transaction(() => { saveJob(job); logAudit(job.sessionId, 'job_status_changed', { status: job.status, errorMessage: job.errorMessage, notes: typeof body.notes === 'string' ? body.notes.slice(0, 2000) : undefined }); });
          return json(res, 200, envelope(job.sessionId));
        });
      }
      match = /^\/v1\/admin\/assets\/([^/]+)\/review$/.exec(routePath);
      if (method === 'PATCH' && match) {
        const row = assetRow(match[1]);
        return locked(row.sessionId, async () => {
          const current = assetRow(match[1]);
          const body = await bodyJSON(req, 16384), asset = parse(current.json);
          requireThat(['needs_review', 'accepted', 'rejected'].includes(body.qualityStatus), 400, 'invalid_quality', 'Specify needs_review, accepted or rejected.');
          requireThat(['declared', 'verified'].includes(body.lineageStatus), 400, 'invalid_lineage', 'Specify declared or verified.');
          requireThat(['not_evaluated', 'partial', 'rejected'].includes(body.dualUseStatus), 400, 'dual_use_unavailable', 'This MVP does not ingest validated camera poses/collision geometry; dual-use acceptance is not available. Use not_evaluated, partial or rejected.');
          requireThat(nonempty(body.notes, 4000), 400, 'notes_required', 'Record review evidence and limitations.');
          Object.assign(asset, { qualityStatus: body.qualityStatus, lineageStatus: body.lineageStatus, dualUseStatus: body.dualUseStatus, review: { reviewedAt: now(), notes: body.notes } });
          transaction(() => { db.prepare('UPDATE assets SET json = ? WHERE id = ?').run(JSON.stringify(asset), asset.id); logAudit(row.sessionId, 'asset_reviewed', { assetId: asset.id, ...asset.review, qualityStatus: asset.qualityStatus, lineageStatus: asset.lineageStatus, dualUseStatus: asset.dualUseStatus }); });
          return json(res, 200, { asset });
        });
      }
      throw new APIError(404, 'not_found', 'Admin endpoint not found.');
    }

    const userId = authenticate(req);
    if (await images.route(req,res,userId,routePath)) return;
    if (await keyframeFiles(req,res,userId,routePath)) return;
    if (routePath === '/v2/video-reconstructions' && method === 'POST') {
      const result = videoReconstructions.create(userId, await bodyJSON(req));
      return json(res, result.created ? 201 : 200, { reconstruction: result.reconstruction });
    }
    if (routePath === '/v2/video-reconstructions' && method === 'GET') {
      return json(res, 200, { reconstructions: videoReconstructions.list(userId) });
    }
    const videoRetryMatch = /^\/v2\/video-reconstructions\/([^/]+)\/retry$/.exec(routePath);
    if (videoRetryMatch && method === 'POST') return locked(`video-reconstruction:${videoRetryMatch[1]}`, async () => {
      const body = await bodyJSON(req), current = videoReconstructions.get(videoRetryMatch[1], userId);
      return locked('gpu-admission', async () => {
        const task = current.tasks.find(t => t.id === body.failedTaskId && t.status === 'failed');
        if (task) await checkGPU([task.role]);
        return json(res, 200, { reconstruction: videoReconstructions.retry(videoRetryMatch[1], userId, body) });
      });
    });
    const videoReconstructionMatch = /^\/v2\/video-reconstructions\/([^/]+)(?:\/(video)|\/results\/([^/]+)\/(file|cameras|mobile))?$/.exec(routePath);
    if (videoReconstructionMatch) {
      const [, id, videoAction, taskId, resultType] = videoReconstructionMatch;
      if (!videoAction && !taskId && method === 'GET') return json(res, 200, { reconstruction: videoReconstructions.get(id, userId) });
      if (!videoAction && !taskId && method === 'DELETE') return locked(`video-reconstruction:${id}`, async () => {
        await videoReconstructions.delete(id, userId); return json(res, 200, { ok: true });
      });
      if (videoAction && method === 'PUT') return locked(`video-reconstruction:${id}`, async () => {
        videoReconstructions.get(id, userId);
        const uploaded = await upload(req, MAX_VIDEO);
        try {
          const reconstruction = await videoReconstructions.acceptVideo(id, userId, { ...uploaded, mime: uploadMime(uploaded) });
          return json(res, 200, { reconstruction });
        } finally { await rm(uploaded.temporary, { force: true }); }
      });
      if (taskId && method === 'GET') {
        const result = videoReconstructions.resultFile(id, taskId, userId, resultType === 'cameras', resultType === 'mobile');
        return sendFile(req, res, result.relative, result.mime, result.hash);
      }
    }
    if (routePath === '/v2/reconstruction-studies' && method === 'GET') return json(res, 200, { studies: studies.list(userId) });
    const studyMatch = /^\/v2\/reconstruction-studies\/([^/]+)(?:\/variants\/([^/]+)\/(file|cameras))?$/.exec(routePath);
    if (studyMatch) {
      const [, studyId, variantId, action] = studyMatch;
      if (method === 'GET' && !variantId) return json(res, 200, { study: studies.get(studyId, userId) });
      if (method === 'GET' && variantId) {
        const file = studies.file(studyId, variantId, userId, action === 'cameras');
        return sendFile(req, res, file.relative, file.mime, file.hash);
      }
      if (method === 'DELETE' && !variantId) {
        const relative = studies.delete(studyId, userId);
        if (relative) await rm(safeFile(relative), { recursive: true, force: true });
        return json(res, 200, { ok: true });
      }
      throw new APIError(405, 'method_not_allowed', 'Method not allowed for reconstruction studies.');
    }
    if (routePath === '/v2/captures' && method === 'GET') {
      const rows = db.prepare('SELECT * FROM captures_v2 WHERE userId = ? ORDER BY rowid DESC').all(userId);
      return json(res, 200, { captures: rows.map(captureStatus) });
    }
    if (routePath === '/v2/captures' && method === 'POST') {
      const body = await bodyJSON(req, 16384);
      requireThat(uuid(body.captureId), 400, 'invalid_id', 'A client-generated capture UUID is required.');
      requireThat(body.sceneId == null || uuid(body.sceneId), 400, 'invalid_scene', 'Scene ID must be a UUID when supplied.');
      requireThat(['indoor', 'outdoor', 'unknown'].includes(body.environment), 400, 'invalid_environment', 'Choose indoor, outdoor or unknown.');
      requireThat(nonempty(body.consentVersion, 100), 400, 'consent_required', 'A capture consent version is required.');
      const creation = { sceneId: body.sceneId ?? null, environment: body.environment, consentVersion: body.consentVersion };
      return locked(body.captureId, async () => {
        const previous = db.prepare('SELECT * FROM captures_v2 WHERE id = ?').get(body.captureId);
        if (previous) {
          requireThat(previous.userId === userId && previous.createJson === JSON.stringify(creation), 409, 'capture_conflict', 'Capture ID already exists with different owner or metadata.');
          return json(res, 200, { capture: captureStatus(previous) });
        }
        requireThat(!db.prepare('SELECT id FROM capture_tombstones_v2 WHERE id = ?').get(body.captureId), 409, 'capture_deleted', 'Deleted capture IDs cannot be reused.');
        db.prepare('INSERT INTO captures_v2 (id, userId, createJson, createdAt) VALUES (?, ?, ?, ?)').run(body.captureId, userId, JSON.stringify(creation), now());
        return json(res, 201, { capture: captureStatus(ownCapture(body.captureId, userId)) });
      });
    }
    const arkitPriorMatch = /^\/v2\/captures\/([^/]+)\/reconstructions\/arkit-prior$/.exec(routePath);
    if (arkitPriorMatch) {
      const captureId=arkitPriorMatch[1];ownCapture(captureId,userId);
      if(method==='POST') {
        const body=await bodyJSON(req,4096);
        return locked(captureId,async()=>{
          return locked('gpu-admission', async () => {
            const current=videoReconstructions.getForCapture(captureId,userId);
            if (!current?.tasks.some(t => t.role === 'arkit')) await checkGPU(['arkit']);
            const result=videoReconstructions.enqueueArkitPrior(captureId,userId,body);
            return json(res,result.created?201:200,{reconstruction:result.reconstruction});
          });
        });
      }
      throw new APIError(405,'method_not_allowed','Method not allowed for ARKit pose cloud training.');
    }
    const nativeReconstructionsMatch = /^\/v2\/captures\/([^/]+)\/reconstructions$/.exec(routePath);
    if (nativeReconstructionsMatch) {
      const captureId=nativeReconstructionsMatch[1];ownCapture(captureId,userId);
      if(method==='GET')return locked(captureId,async()=>json(res,200,{reconstruction:videoReconstructions.getForCapture(captureId,userId)}));
      if(method==='POST') {
        const body=await bodyJSON(req,4096);
        return locked(captureId,async()=>{
          return locked('gpu-admission', async () => {
            const current=videoReconstructions.getForCapture(captureId,userId);
            const requested=body.roles ?? (current ? [] : ['preview','refined']);
            if (Array.isArray(requested) && requested.every(r => ['preview','refined'].includes(r)))
              await checkGPU(requested.filter(role => !current?.tasks.some(t => t.role === role)));
            const result=await videoReconstructions.enqueueNative(captureId,userId,body);
            return json(res,result.created?201:200,{reconstruction:result.reconstruction});
          });
        });
      }
      throw new APIError(405,'method_not_allowed','Method not allowed for native dual reconstruction.');
    }
    const ffMatch = /^\/v2\/captures\/([^/]+)\/ff$/.exec(routePath);
    if (ffMatch) {
      const captureId = ffMatch[1];
      ownCapture(captureId, userId);
      if (method === 'GET') return locked(captureId, async () => {
        ownCapture(captureId, userId);
        return json(res, 200, { ff: ffStatus(captureId, userId) });
      });
      if (method === 'POST') {
        await bodyJSON(req, 4096);
        return locked(captureId, async () => {
          const source = ownCapture(captureId, userId);
          if (db.prepare('SELECT sessionId FROM ff_links_v2 WHERE captureId = ?').get(captureId)) {
            return json(res, 200, { ff: ffStatus(captureId, userId) });
          }
          requireThat(source.verifiedAt && source.receiptId && source.rgbPath && source.metadataPath, 409, 'capture_incomplete', 'Complete and verify the RGB capture before requesting FF preview.');
          const validation = parse(source.validationJson);
          requireThat(validation?.frameCount >= 2 && Number.isFinite(validation.timestampSpanSeconds) && validation.timestampSpanSeconds > 0 && validation.timestampSpanSeconds <= 600, 409, 'ff_source_too_short', 'FF preview needs at least two timed source frames.');
          let metadata;
          try { metadata = JSON.parse(await readFile(safeFile(source.metadataPath), 'utf8')); }
          catch { throw new APIError(409, 'ff_metadata_missing', 'Verified capture metadata is unavailable.'); }
          requireThat(await fileHash(source.metadataPath) === source.metadataHash && metadata.manifest?.captureID === captureId && metadata.manifest.videoSHA256 === source.rgbHash, 409, 'ff_source_changed', 'Verified capture metadata changed.');
          const creation = parse(source.createJson), timestamp = now(), sessionId = randomUUID(), jobId = randomUUID();
          const session = {
            id: sessionId, userId, questId: 'first_light', sceneId: creation.sceneId ?? randomUUID(), environment: creation.environment,
            captureMode: 'in_app_rgb', provenance: 'device_capture_v2_verified', captureStatus: 'submitted',
            poseSource: 'arkit_device_reported', calibrationAvailable: true, calibrationSource: 'arkit_device_reported_unverified',
            rawDataAvailable: true, consentVersion: creation.consentVersion, createdAt: timestamp,
            capturedAt: metadata.manifest.createdAtUTC, submittedAt: timestamp,
            videoDurationSeconds: validation.timestampSpanSeconds, width: metadata.manifest.rgbWidth, height: metadata.manifest.rgbHeight,
            fps: null, fpsSource: 'unknown', audioPolicy: 'unknown', audioPolicySource: 'v2_manifest_device_reported',
            audioPolicyDeclared: metadata.manifest.audioPolicy,
            originalVideoId: captureId, videoMimeType: source.rgbMime,
            linkedCaptureId: captureId, linkedCaptureReceiptId: source.receiptId,
            linkedCaptureMetadataSHA256: source.metadataHash, reconstructionPipeline: 'ff_worldmirror2',
          };
          const job = { id: jobId, sessionId, provider: 'WorldMirror2', status: 'queued', createdAt: timestamp };
          transaction(() => {
            db.prepare('INSERT INTO sessions (id, userId, json, videoPath, videoHash, videoSize, videoMime) VALUES (?, ?, ?, ?, ?, ?, ?)').run(sessionId, userId, JSON.stringify(session), source.rgbPath, source.rgbHash, source.rgbSize, source.rgbMime);
            saveJob(job);
            db.prepare('INSERT INTO ff_links_v2 (captureId, userId, sessionId, createdAt) VALUES (?, ?, ?, ?)').run(captureId, userId, sessionId, timestamp);
            logAudit(sessionId, 'ff_queued_from_v2', { captureId, receiptId: source.receiptId, videoSHA256: source.rgbHash, metadataSHA256: source.metadataHash });
          });
          return json(res, 201, { ff: ffStatus(captureId, userId) });
        });
      }
      throw new APIError(405, 'method_not_allowed', 'Method not allowed for this FF task.');
    }
    let captureMatch = /^\/v2\/captures\/([^/]+)(?:\/(rgb|metadata|complete|rgb-upload|keyframes-upload))?$/.exec(routePath);
    if (captureMatch) {
      const id = captureMatch[1], action = captureMatch[2] ?? '';
      if (!action && method === 'DELETE' && uuid(id)) {
        const deleted = db.prepare('SELECT userId FROM capture_tombstones_v2 WHERE id = ?').get(id);
        if (deleted) {
          requireThat(deleted.userId === userId, 404, 'capture_not_found', 'Capture not found.');
          return json(res, 200, { ok: true });
        }
      }
      ownCapture(id, userId);
      if (!action && method === 'GET') return json(res, 200, { capture: captureStatus(ownCapture(id, userId)) });
      if (action === 'rgb' && method === 'GET') {
        const row = ownCapture(id, userId);
        requireThat(row.rgbPath, 404, 'file_missing', 'Original video is not uploaded.');
        return sendFile(req, res, row.rgbPath, row.rgbMime, row.rgbHash);
      }
      if (action === 'metadata' && method === 'GET') {
        const row = ownCapture(id, userId);
        requireThat(row.metadataPath, 404, 'file_missing', 'Capture metadata is not uploaded.');
        return sendFile(req, res, row.metadataPath, 'application/json', row.metadataHash);
      }
      if (action === 'rgb-upload') {
        // Resumable original-video upload: POST declares the file and returns the offset, PATCH
        // appends from Upload-Offset. Bytes that arrived before a dropped connection are kept.
        const directory = rgbUploadDirectory(id);
        const completed = row => ({ upload: { sha256: row.rgbHash, byteSize: row.rgbSize, mime: row.rgbMime,
          offset: row.rgbSize, complete: true }, capture: captureStatus(row) });
        if (method === 'GET') {
          const row = ownCapture(id, userId);
          return json(res, 200, row.rgbHash ? completed(row) : { upload: await rgbUploads.status(directory) });
        }
        if (method === 'POST') {
          const body = await bodyJSON(req, 4096);
          return locked(id, async () => {
            const row = ownCapture(id, userId);
            if (row.rgbHash) {
              requireThat(row.rgbHash === body?.sha256 && row.rgbSize === body?.byteSize && row.rgbMime === body?.mime,
                409, 'rgb_conflict', 'Capture already has different video bytes.');
              return json(res, 200, completed(row));
            }
            await requireManifestVideo(row, body?.sha256, body?.mime);
            return json(res, 200, { upload: await rgbUploads.begin(directory, body) });
          });
        }
        if (method === 'PATCH') {
          // Not under the capture lock: a long or stalled append must not block status reads.
          const progress = await rgbUploads.append(directory, req);
          if (progress.offset < progress.byteSize) return json(res, 200, { upload: progress });
          // Complete (even if this client has already gone): verify and store under the lock.
          return locked(id, async () => {
            const row = ownCapture(id, userId);
            if (row.rgbHash) { await rgbUploads.discard(directory); return json(res, 200, completed(row)); }
            const file = await rgbUploads.finalize(directory);
            let capture;
            try { capture = await acceptCaptureRgb(row, id, userId, file.mime, file); }
            catch (error) { if (error instanceof APIError) await rgbUploads.discard(directory); throw error; }
            await rgbUploads.discard(directory);
            return json(res, 200, { upload: { sha256: file.hash, byteSize: file.size, mime: file.mime, offset: file.size, complete: true }, capture });
          });
        }
        throw new APIError(405, 'method_not_allowed', 'Use GET, POST or PATCH for resumable video upload.');
      }
      if (action === 'keyframes-upload') {
        // Same resumable protocol as the video; the complete pack is verified against the
        // capture's verified frame table before it is stored (once, immutable).
        const directory = keyframeUploadDirectory(id);
        const completed = row => ({ upload: { sha256: row.keyframesHash, byteSize: row.keyframesSize, mime: KEYFRAME_PACK_MIME,
          offset: row.keyframesSize, complete: true }, capture: captureStatus(row) });
        if (method === 'GET') {
          const row = ownCapture(id, userId);
          return json(res, 200, row.keyframesHash ? completed(row) : { upload: await keyframeUploads.status(directory) });
        }
        if (method === 'POST') {
          const body = await bodyJSON(req, 4096);
          return locked(id, async () => {
            const row = ownCapture(id, userId);
            if (row.keyframesHash) {
              requireThat(row.keyframesHash === body?.sha256 && row.keyframesSize === body?.byteSize, 409, 'keyframes_conflict',
                'This capture already has a different keyframe pack.');
              return json(res, 200, completed(row));
            }
            requireThat(row.verifiedAt && row.receiptId && row.metadataPath, 409, 'capture_incomplete', 'Verify the capture before adding keyframes.');
            return json(res, 200, { upload: await keyframeUploads.begin(directory, body) });
          });
        }
        if (method === 'PATCH') {
          const progress = await keyframeUploads.append(directory, req);
          if (progress.offset < progress.byteSize) return json(res, 200, { upload: progress });
          return locked(id, async () => {
            const row = ownCapture(id, userId);
            if (row.keyframesHash) { await keyframeUploads.discard(directory); return json(res, 200, completed(row)); }
            const file = await keyframeUploads.finalize(directory);
            let capture;
            try { capture = await acceptKeyframes(row, id, userId, file); }
            finally { await keyframeUploads.discard(directory); }
            return json(res, 200, { upload: { sha256: file.hash, byteSize: file.size, mime: KEYFRAME_PACK_MIME, offset: file.size, complete: true }, capture });
          });
        }
        throw new APIError(405, 'method_not_allowed', 'Use GET, POST or PATCH for the keyframe pack upload.');
      }
      return locked(id, async () => {
        const row = ownCapture(id, userId);
        if (!action && method === 'DELETE') {
          const link = db.prepare('SELECT * FROM ff_links_v2 WHERE captureId = ?').get(id);
          const removeCapture = async () => {
            if(link)requireThat(link.userId === userId, 500, 'ff_link_invalid', 'FF task owner is inconsistent.');
            const dualDirectory=transaction(() => {
              const directory=videoReconstructions.retireForCapture(id,userId);
              if (link) {
                const assetId = db.prepare('SELECT id FROM assets WHERE sessionId = ?').get(link.sessionId)?.id;
                db.prepare('DELETE FROM events WHERE sessionId = ? OR assetId = ?').run(link.sessionId, assetId ?? '');
                db.prepare('DELETE FROM audit WHERE sessionId = ?').run(link.sessionId);
                db.prepare('DELETE FROM assets WHERE sessionId = ?').run(link.sessionId);
                db.prepare('DELETE FROM jobs WHERE sessionId = ?').run(link.sessionId);
                db.prepare('DELETE FROM rewards WHERE sessionId = ?').run(link.sessionId);
                db.prepare('DELETE FROM sessions WHERE id = ?').run(link.sessionId);
                db.prepare('DELETE FROM ff_links_v2 WHERE captureId = ?').run(id);
              }
              db.prepare('DELETE FROM captures_v2 WHERE id = ?').run(id);
              db.prepare('INSERT INTO capture_tombstones_v2 (id, userId, deletedAt) VALUES (?, ?, ?)').run(id, userId, now());
              return directory;
            });
            // Native source and both task branches are retired atomically before
            // file I/O. No worker can publish or recreate a deleted source.
            await rgbUploads.discard(rgbUploadDirectory(id)); // stops an in-flight resumable upload
            await keyframeUploads.discard(keyframeUploadDirectory(id));
            const directories=[path.join('captures-v2',id),...(link?[path.join('sessions',link.sessionId)]:[]),...(dualDirectory?[dualDirectory]:[])];
            await Promise.all(directories.map(directory=>rm(safeFile(directory),{recursive:true,force:true,maxRetries:3,retryDelay:100})));
            return json(res, 200, { ok: true });
          };
          return link ? locked(link.sessionId, removeCapture) : removeCapture();
        }
        if (action === 'rgb' && method === 'PUT') {
          const mime = (req.headers['content-type'] ?? '').split(';')[0].toLowerCase();
          requireThat(['video/mp4', 'video/quicktime'].includes(mime), 415, 'unsupported_video', 'Upload MP4 or QuickTime video.');
          const expected = req.headers['x-content-sha256'];
          requireThat(typeof expected === 'string' && /^[0-9a-f]{64}$/.test(expected), 400, 'hash_required', 'Set X-Content-SHA256 for the original video.');
          const file = await upload(req, limits.video ?? MAX_VIDEO);
          try {
            requireThat(file.hash === expected, 422, 'hash_mismatch', 'Video bytes do not match X-Content-SHA256.');
            return json(res, 200, { capture: await acceptCaptureRgb(row, id, userId, mime, file) });
          } finally { await rm(file.temporary, { force: true }); }
        }
        if (action === 'metadata' && method === 'PUT') {
          requireThat((req.headers['content-type'] ?? '').split(';')[0].toLowerCase() === 'application/json', 415, 'content_type', 'Upload application/json metadata.');
          const expected = req.headers['x-content-sha256'];
          requireThat(typeof expected === 'string' && /^[0-9a-f]{64}$/.test(expected), 400, 'hash_required', 'Set X-Content-SHA256 for metadata.');
          const file = await upload(req, limits.captureMetadata ?? MAX_CAPTURE_METADATA);
          try {
            requireThat(file.hash === expected, 422, 'hash_mismatch', 'Metadata bytes do not match X-Content-SHA256.');
            if (row.metadataHash) {
              requireThat(row.metadataHash === file.hash, 409, 'metadata_conflict', 'Capture already has different metadata bytes.');
              let intact = false;
              try { intact = await fileHash(row.metadataPath) === row.metadataHash; }
              catch (error) { if (error.code !== 'ENOENT') throw error; }
              if (!intact) {
                await mkdir(path.dirname(safeFile(row.metadataPath)), { recursive: true });
                await rm(safeFile(row.metadataPath), { force: true });
                await rename(file.temporary, safeFile(row.metadataPath));
              }
              return json(res, 200, { capture: captureStatus(row) });
            }
            let envelope;
            try { envelope = JSON.parse(await readFile(file.temporary, 'utf8')); }
            catch { throw new APIError(422, 'invalid_metadata', 'Metadata is not valid JSON.'); }
            validateCaptureMetadata(envelope, id, row.rgbHash ?? envelope?.manifest?.videoSHA256);
            const relative = path.join('captures-v2', id, 'metadata.json');
            await mkdir(path.dirname(safeFile(relative)), { recursive: true });
            await rename(file.temporary, safeFile(relative));
            db.prepare('UPDATE captures_v2 SET metadataPath = ?, metadataHash = ?, metadataSize = ? WHERE id = ?').run(relative, file.hash, file.size, id);
            return json(res, 200, { capture: captureStatus(ownCapture(id, userId)) });
          } finally { await rm(file.temporary, { force: true }); }
        }
        if (action === 'complete' && method === 'POST') {
          await bodyJSON(req, 4096);
          requireThat(row.rgbPath && row.metadataPath, 409, 'capture_incomplete', 'Upload original video and metadata before completion.');
          let storedHashesMatch = false;
          try { storedHashesMatch = await fileHash(row.rgbPath) === row.rgbHash && await fileHash(row.metadataPath) === row.metadataHash; }
          catch (error) { if (error.code !== 'ENOENT') throw error; }
          requireThat(storedHashesMatch, 409, 'stored_file_mismatch', 'Stored capture bytes are missing or no longer match upload hashes.');
          await validateVideo(safeFile(row.rgbPath));
          let envelope;
          try { envelope = JSON.parse(await readFile(safeFile(row.metadataPath), 'utf8')); }
          catch { throw new APIError(422, 'invalid_metadata', 'Stored metadata is not valid JSON.'); }
          const validation = validateCaptureMetadata(envelope, id, row.rgbHash);
          requireThat((row.rgbMime === 'video/mp4' ? 'video.mp4' : 'video.mov') === envelope.manifest.videoFile, 422, 'video_manifest_mismatch', 'Manifest video filename does not match uploaded media type.');
          if (!row.receiptId) db.prepare('UPDATE captures_v2 SET receiptId = ?, verifiedAt = ?, validationJson = ? WHERE id = ?').run(randomUUID(), now(), JSON.stringify(validation), id);
          return json(res, 200, { capture: captureStatus(ownCapture(id, userId)) });
        }
        throw new APIError(405, 'method_not_allowed', 'Method not allowed for this capture operation.');
      });
    }
    if (routePath === '/v1/sessions' && method === 'GET') {
      const rows = db.prepare('SELECT id FROM sessions WHERE userId = ? ORDER BY rowid DESC').all(userId);
      return json(res, 200, { sessions: rows.map(row => envelope(row.id)).filter(item => !item.session.linkedCaptureId) });
    }
    if (routePath === '/v1/sessions' && method === 'POST') {
      const body = await bodyJSON(req, 16384);
      requireThat(uuid(body.id), 400, 'invalid_id', 'A client-generated UUID is required.');
      requireThat(Object.hasOwn(QUESTS, body.questId), 400, 'invalid_quest', 'Unknown quest.');
      requireThat(['indoor', 'outdoor', 'unknown'].includes(body.environment), 400, 'invalid_environment', 'Choose indoor, outdoor or unknown.');
      requireThat(['in_app_rgb', 'external_app'].includes(body.captureMode), 400, 'invalid_mode', 'Choose in_app_rgb or external_app.');
      requireThat(body.consentVersion === CONSENT, 400, 'consent_required', `Capture consent ${CONSENT} is required.`);
      if (body.sceneId != null) requireThat(uuid(body.sceneId), 400, 'invalid_scene', 'Scene ID must be a UUID.');
      if (body.parentSessionId != null) ownSession(body.parentSessionId, userId);
      if (body.questId === 'repair_view') requireThat(body.parentSessionId, 400, 'parent_required', 'Recapture needs an existing owned parent session.');
      return locked(body.id, async () => {
        const existing = db.prepare('SELECT userId, json FROM sessions WHERE id = ?').get(body.id);
        if (existing) {
          requireThat(existing.userId === userId, 409, 'session_conflict', 'Session ID is unavailable.');
          const previous = parse(existing.json);
          requireThat(['questId', 'environment', 'captureMode', 'consentVersion', 'parentSessionId'].every(key => (previous[key] ?? null) === (body[key] ?? null)) && (!body.sceneId || previous.sceneId === body.sceneId), 409, 'session_conflict', 'Session ID already exists with different metadata.');
          return json(res, 200, envelope(body.id));
        }
        requireThat(!db.prepare('SELECT id FROM tombstones WHERE id = ?').get(body.id), 409, 'session_deleted', 'Deleted session IDs cannot be reused.');
        const parent = body.parentSessionId ? parse(ownSession(body.parentSessionId, userId).json) : null;
        const session = { id: body.id, userId, questId: body.questId, sceneId: parent?.sceneId ?? body.sceneId ?? randomUUID(), ...(body.parentSessionId ? { parentSessionId: body.parentSessionId } : {}), environment: body.environment, captureMode: body.captureMode, provenance: body.captureMode === 'in_app_rgb' ? 'device_capture' : 'external_asset_only', captureStatus: body.captureMode === 'in_app_rgb' ? 'draft' : 'awaiting_asset_import', poseSource: 'none', calibrationAvailable: false, rawDataAvailable: false, consentVersion: CONSENT, createdAt: now() };
        db.prepare('INSERT INTO sessions (id, userId, json) VALUES (?, ?, ?)').run(session.id, userId, JSON.stringify(session));
        return json(res, 201, envelope(session.id));
      });
    }
    let match = /^\/v1\/sessions\/([^/]+)$/.exec(routePath);
    if (match && method === 'GET') { ownSession(match[1], userId); return json(res, 200, envelope(match[1])); }
    if (match && method === 'DELETE') {
      const id = match[1];
      const deleted = db.prepare('SELECT userId FROM tombstones WHERE id = ?').get(id);
      if (deleted) { requireThat(deleted.userId === userId, 404, 'session_not_found', 'Session not found.'); return json(res, 200, { ok: true }); }
      requireThat(!parse(ownSession(id, userId).json).linkedCaptureId, 409, 'linked_capture', 'Delete this FF task through its source v2 capture.');
      return locked(id, async () => {
        requireThat(!parse(ownSession(id, userId).json).linkedCaptureId, 409, 'linked_capture', 'Delete this FF task through its source v2 capture.');
        // Delete bytes first. If a Windows file lock prevents removal, leave DB intact and report failure.
        await rm(safeFile(path.join('sessions', id)), { recursive: true, force: true });
        transaction(() => {
          const assetId = db.prepare('SELECT id FROM assets WHERE sessionId = ?').get(id)?.id;
          db.prepare('DELETE FROM events WHERE sessionId = ? OR assetId = ?').run(id, assetId ?? '');
          db.prepare('DELETE FROM audit WHERE sessionId = ?').run(id);
          db.prepare('DELETE FROM assets WHERE sessionId = ?').run(id);
          db.prepare('DELETE FROM jobs WHERE sessionId = ?').run(id);
          db.prepare('DELETE FROM sessions WHERE id = ?').run(id);
          db.prepare('INSERT INTO tombstones (id, userId, deletedAt) VALUES (?, ?, ?)').run(id, userId, now());
          for (const childRow of db.prepare('SELECT json FROM sessions WHERE userId = ?').all(userId)) {
            const child = parse(childRow.json);
            if (child.parentSessionId === id) { delete child.parentSessionId; child.parentDeleted = true; saveSession(child); }
          }
          // Preserve a decodable GameSnapshot while detaching its private source data.
          const backup = db.prepare('SELECT json FROM games WHERE userId = ?').get(userId);
          if (backup) {
            const cleaned = scrubGameBackup(parse(backup.json), new Set([id]), new Set(assetId ? [assetId] : []));
            db.prepare('UPDATE games SET json = ?, updatedAt = ? WHERE userId = ?').run(JSON.stringify(cleaned), now(), userId);
          }
        });
        return json(res, 200, { ok: true });
      });
    }
    match = /^\/v1\/sessions\/([^/]+)\/(video|preview|submit|asset|reward)$/.exec(routePath);
    if (match) {
      const id = match[1], action = match[2];
      ownSession(id, userId);
      if (method === 'GET' && action === 'preview') {
        const row = ownSession(id, userId); requireThat(row.previewPath, 404, 'file_missing', 'No preview is stored.');
        return sendFile(req, res, row.previewPath, 'image/jpeg');
      }
      return locked(id, async () => {
        const row = ownSession(id, userId), session = parse(row.json);
        requireThat(!session.linkedCaptureId, 409, 'linked_capture', 'This source is managed by its verified v2 capture.');
        if (['PUT', 'POST'].includes(method) && action === 'video') {
          requireThat(session.captureMode === 'in_app_rgb', 409, 'wrong_capture_mode', 'External assets cannot claim an original in-app video.');
          if (method === 'PUT') requireThat(['video/mp4', 'video/quicktime'].includes((req.headers['content-type'] ?? '').split(';')[0]), 415, 'unsupported_video', 'Upload MP4 or QuickTime video.');
          const file = await upload(req, limits.video ?? MAX_VIDEO);
          try {
            const mime = uploadMime(file);
            requireThat(['video/mp4', 'video/quicktime'].includes(mime), 415, 'unsupported_video', 'Upload MP4 or QuickTime video.');
            if (row.videoHash) {
              requireThat(row.videoHash === file.hash && row.videoMime === mime, 409, 'video_conflict', 'This session already contains another video. Create a new session to retake.');
              return json(res, 200, envelope(id));
            }
            await validateVideo(file.temporary);
            const relative = path.join('sessions', id, mime === 'video/quicktime' ? 'capture.mov' : 'capture.mp4');
            await mkdir(path.dirname(safeFile(relative)), { recursive: true });
            await rename(file.temporary, safeFile(relative));
            Object.assign(session, { captureStatus: 'saved', originalVideoId: randomUUID(), rawDataAvailable: true, videoMimeType: mime });
            transaction(() => {
              db.prepare('UPDATE sessions SET videoPath = ?, videoHash = ?, videoSize = ?, videoMime = ?, json = ? WHERE id = ?').run(relative, file.hash, file.size, mime, JSON.stringify(session), id);
              logAudit(id, 'video_uploaded', { sha256: file.hash, size: file.size, validation: 'container_box_structure_only' });
            });
            return json(res, 200, envelope(id));
          } finally { await rm(file.temporary, { force: true }); }
        }
        if (['PUT', 'POST'].includes(method) && action === 'preview') {
          if (method === 'PUT') requireThat((req.headers['content-type'] ?? '').split(';')[0] === 'image/jpeg', 415, 'unsupported_preview', 'Upload a JPEG preview.');
          const file = await upload(req, MAX_PREVIEW);
          try {
            requireThat(uploadMime(file) === 'image/jpeg', 415, 'unsupported_preview', 'Upload a JPEG preview.');
            await validateJPEG(file.temporary);
            const relative = path.join('sessions', id, 'preview.jpg');
            await mkdir(path.dirname(safeFile(relative)), { recursive: true });
            await rename(file.temporary, safeFile(relative));
            db.prepare('UPDATE sessions SET previewPath = ? WHERE id = ?').run(relative, id);
            return json(res, 200, { ok: true });
          } finally { await rm(file.temporary, { force: true }); }
        }
        if (method === 'POST' && action === 'submit') {
          const body = await bodyJSON(req, 16384);
          requireThat(session.captureMode === 'in_app_rgb' && row.videoPath, 409, 'video_required', 'Upload the original in-app video before submitting.');
          const fpsSource = body.fpsSource ?? 'client_reported';
          const audioPolicy = body.audioPolicy ?? 'unknown';
          const validFPS = (Number.isFinite(body.fps) && body.fps >= 1 && body.fps <= 240 && fpsSource === 'client_reported') || (body.fps === null && fpsSource === 'unknown');
          requireThat(['not_recorded', 'may_contain_audio', 'unknown'].includes(audioPolicy), 400, 'invalid_audio_policy', 'Declare not_recorded, may_contain_audio or unknown; this is client-reported, not audio verification.');
          requireThat(dateString(body.capturedAt) && Number.isFinite(body.durationSeconds) && body.durationSeconds > 0 && body.durationSeconds <= 600 && Number.isInteger(body.width) && body.width >= 1 && body.width <= 8192 && Number.isInteger(body.height) && body.height >= 1 && body.height <= 8192 && validFPS, 400, 'invalid_capture_metadata', 'Provide capture timestamp, duration (0–600 sec), dimensions and measured fps; unavailable fps must be null with fpsSource unknown.');
          if (session.submittedAt) {
            requireThat(session.capturedAt === body.capturedAt && session.videoDurationSeconds === body.durationSeconds && session.width === body.width && session.height === body.height && session.fps === body.fps && (session.fpsSource ?? 'client_reported') === fpsSource && (session.audioPolicy ?? 'unknown') === audioPolicy, 409, 'metadata_conflict', 'Submitted capture metadata is immutable.');
            return json(res, 200, envelope(id));
          }
          const timestamp = now();
          Object.assign(session, { capturedAt: body.capturedAt, submittedAt: timestamp, videoDurationSeconds: body.durationSeconds, width: body.width, height: body.height, fps: body.fps, fpsSource, audioPolicy, audioPolicySource: 'client_reported', captureStatus: 'submitted' });
          transaction(() => {
            saveSession(session);
            saveJob({ id: randomUUID(), sessionId: id, provider: 'manual', status: 'queued', createdAt: timestamp });
            serverEvent(userId, 'upload_completed', id, undefined, { environment: session.environment, captureMode: session.captureMode, provenance: session.provenance });
          });
          return json(res, 200, envelope(id));
        }
        if (['PUT', 'POST'].includes(method) && action === 'asset') return json(res, 200, await importAsset(req, id, url.searchParams.get('format'), url.searchParams.get('tool'), url.searchParams.get('version'), userId));
        if (method === 'POST' && action === 'reward') {
          await bodyJSON(req, 4096);
          const existing = db.prepare('SELECT json FROM rewards WHERE sessionId = ?').get(id);
          if (existing) return json(res, 200, { reward: parse(existing.json) });
          requireThat(['submitted', 'asset_imported'].includes(session.captureStatus), 409, 'reward_not_ready', 'Submit your video or import a readable external asset first.');
          const reward = { id: randomUUID(), sessionId: id, questId: session.questId, cardKind: QUESTS[session.questId], grantedAt: now() };
          transaction(() => {
            db.prepare('INSERT INTO rewards (sessionId, userId, json) VALUES (?, ?, ?)').run(id, userId, JSON.stringify(reward));
            serverEvent(userId, 'card_granted', id, undefined, { questId: session.questId, cardKind: reward.cardKind });
          });
          return json(res, 200, { reward });
        }
        throw new APIError(405, 'method_not_allowed', 'Method not allowed for this session operation.');
      });
    }
    match = /^\/v1\/assets\/([^/]+)\/file$/.exec(routePath);
    if (method === 'GET' && match) {
      const row = assetRow(match[1], userId); return sendFile(req, res, row.filePath, 'application/octet-stream', parse(row.json).sha256);
    }
    match = /^\/v1\/assets\/([^/]+)\/(viewer|viewer-info)$/.exec(routePath);
    if (method === 'GET' && match) {
      const row = assetRow(match[1], userId), maxPoints = Number(url.searchParams.get('maxPoints') ?? 60000);
      requireThat(VIEWER_BUDGETS.includes(maxPoints), 400, 'invalid_point_budget', 'maxPoints must be 10000, 30000, 60000 or 100000.');
      return locked(row.sessionId, async () => {
        const current = assetRow(match[1], userId);
        const derivative = await viewerDerivative(current, maxPoints);
        if (match[2] === 'viewer-info') return json(res, 200, derivative.info);
        return sendFile(req, res, derivative.relative, 'application/octet-stream', derivative.info.sha256, {
          'X-Viewer-Format': 'splat', 'X-Viewer-Version': VIEWER_VERSION,
          'X-Source-Asset-ID': current.id, 'X-Source-SHA256': derivative.info.sourceSha256,
          'X-Point-Count': String(derivative.info.pointCount), 'X-Renderer-Only': 'true',
        });
      });
    }
    if (routePath === '/v1/events' && method === 'POST') {
      const body = await bodyJSON(req, 512 * 1024);
      requireThat(Array.isArray(body.events) && body.events.length <= 100, 400, 'invalid_events', 'Send up to 100 events.');
      const prepared = body.events.map(event => {
        requireThat(event && uuid(event.id) && typeof event.name === 'string' && /^[a-z][a-z0-9_]{0,79}$/.test(event.name) && dateString(event.occurredAt), 400, 'invalid_event', 'Events need UUID id, snake_case name, and ISO timestamp.');
        if (event.sessionId != null) ownSession(event.sessionId, userId);
        if (event.assetId != null) assetRow(event.assetId, userId);
        requireThat(event.questId == null || nonempty(event.questId, 100), 400, 'invalid_event', 'Invalid quest ID.');
        requireThat(event.properties == null || (typeof event.properties === 'object' && !Array.isArray(event.properties) && JSON.stringify(event.properties).length <= 16384), 400, 'invalid_event', 'Properties must be a small JSON object.');
        return { id: event.id, name: event.name, occurredAt: event.occurredAt, ...(event.questId ? { questId: event.questId } : {}), ...(event.sessionId ? { sessionId: event.sessionId } : {}), ...(event.assetId ? { assetId: event.assetId } : {}), ...(event.properties ? { properties: event.properties } : {}) };
      });
      let accepted = 0;
      transaction(() => {
        for (const event of prepared) {
          const existing = db.prepare('SELECT userId, json FROM events WHERE id = ?').get(event.id);
          if (existing) {
            requireThat(existing.userId === userId && existing.json === JSON.stringify(event), 409, 'event_conflict', 'An event ID already has different content.');
          } else {
            db.prepare('INSERT INTO events (id, userId, sessionId, assetId, json) VALUES (?, ?, ?, ?, ?)').run(event.id, userId, event.sessionId ?? null, event.assetId ?? null, JSON.stringify(event)); accepted++;
          }
        }
      });
      return json(res, 200, { accepted });
    }
    if (routePath === '/v1/game' && method === 'GET') return json(res, 200, { state: parse(db.prepare('SELECT json FROM games WHERE userId = ?').get(userId)?.json) });
    if (routePath === '/v1/game' && method === 'PUT') {
      const body = await bodyJSON(req, 512 * 1024);
      requireThat(body.state && typeof body.state === 'object' && !Array.isArray(body.state), 400, 'invalid_game', 'State must be a JSON object.');
      // An offline device may later back up a pre-deletion snapshot. Tombstones
      // prevent its stale session/video records from returning to the backup.
      const deletedIds = new Set(db.prepare('SELECT id FROM tombstones WHERE userId = ?').all(userId).map(row => row.id));
      const cleaned = scrubGameBackup(body.state, deletedIds);
      db.prepare('INSERT INTO games (userId, json, updatedAt) VALUES (?, ?, ?) ON CONFLICT(userId) DO UPDATE SET json = excluded.json, updatedAt = excluded.updatedAt').run(userId, JSON.stringify(cleaned), now());
      return json(res, 200, { ok: true });
    }
    throw new APIError(404, 'not_found', 'Endpoint not found.');
  }

  const server = http.createServer((req, res) => {
    route(req, res).catch(error => {
      if (error.name === 'AbortError' || req.aborted) return;
      if (!(error instanceof APIError)) logger.error('PocketWorld request failed:', error.message);
      if (res.headersSent || res.destroyed) { res.destroy(); return; }
      const status = error instanceof APIError ? error.status : 500;
      json(res, status, { error: { code: error instanceof APIError ? error.code : 'internal_error', message: error instanceof APIError ? error.message : 'The server could not finish this request. Retry after checking the operator log.' } });
    });
  });
  server.requestTimeout = 10 * 60 * 1000;
  server.headersTimeout = 30_000;
  server.keepAliveTimeout = 5_000;
  const imageTimer = (imageGeneration || imageBridge) ? setInterval(() => { images.tick().catch(() => {}); }, 5000) : null;
  imageTimer?.unref();
  server.on('close', () => { if(imageTimer)clearInterval(imageTimer); });
  server.imageTick = images.tick;
  server.closeDatabase = () => { if(imageTimer)clearInterval(imageTimer);db.close(); };
  server.dataDirectory = root;
  return server;
}
