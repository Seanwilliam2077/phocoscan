import { DatabaseSync } from 'node:sqlite';
import { createReadStream, renameSync } from 'node:fs';
import { copyFile, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { requireThat, uuid, nonempty, dateString, validateGaussian, validateVideo } from './validation.mjs';

const MAX_MODEL = 150 * 1024 * 1024;
const MAX_CAMERA = 4 * 1024 * 1024;
const SHA = /^[a-f0-9]{64}$/;
const digest = async file => {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
};
const canonical = value => JSON.stringify(value, (_, item) => item && typeof item === 'object' && !Array.isArray(item)
  ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);

export function initializeReconstructionStudies(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS reconstruction_studies_v2 (id TEXT PRIMARY KEY, userId TEXT NOT NULL, json TEXT NOT NULL, fingerprint TEXT NOT NULL, directory TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS reconstruction_studies_owner ON reconstruction_studies_v2(userId);
    CREATE TABLE IF NOT EXISTS reconstruction_study_tombstones_v2 (id TEXT PRIMARY KEY, userId TEXT NOT NULL, deletedAt TEXT NOT NULL);
  `);
}

export function validateStudyCameras(value) {
  const valid = condition => requireThat(condition, 422, 'invalid_study_cameras', 'Expected bounded, ordered OpenGL camera-to-world frames with rigid row-major transforms.');
  valid(value?.version === 1 && value.coordinateSystem === 'opengl_camera_to_world' && value.matrixLayout === 'row-major' && value.scale === 'unknown');
  valid(Array.isArray(value.frames) && value.frames.length >= 1 && value.frames.length <= 2048);
  const names = new Set();
  let previous = -1;
  for (const frame of value.frames) {
    valid(nonempty(frame.sourceFrame, 160) && !names.has(frame.sourceFrame));
    names.add(frame.sourceFrame);
    valid(Number.isFinite(frame.timeSeconds) && frame.timeSeconds >= 0 && frame.timeSeconds > previous);
    previous = frame.timeSeconds;
    valid(['width', 'height'].every(key => Number.isInteger(frame[key]) && frame[key] > 0 && frame[key] <= 20000));
    valid(['fx', 'fy'].every(key => Number.isFinite(frame[key]) && frame[key] > 0 && frame[key] <= 1e7));
    valid(Number.isFinite(frame.cx) && Number.isFinite(frame.cy) && Math.abs(frame.cx) <= frame.width * 2 && Math.abs(frame.cy) <= frame.height * 2);
    const m = frame.cameraToWorld;
    valid(Array.isArray(m) && m.length === 16 && m.every(n => Number.isFinite(n) && Math.abs(n) <= 1e9));
    valid(Math.abs(m[12]) < 1e-5 && Math.abs(m[13]) < 1e-5 && Math.abs(m[14]) < 1e-5 && Math.abs(m[15] - 1) < 1e-5);
    const cols = [[m[0], m[4], m[8]], [m[1], m[5], m[9]], [m[2], m[6], m[10]]];
    const dot = (a, b) => a.reduce((sum, n, index) => sum + n * b[index], 0);
    valid(cols.every(c => Math.abs(dot(c, c) - 1) < 0.02));
    valid(Math.abs(dot(cols[0], cols[1])) < 0.02 && Math.abs(dot(cols[0], cols[2])) < 0.02 && Math.abs(dot(cols[1], cols[2])) < 0.02);
    const det = m[0] * (m[5] * m[10] - m[6] * m[9]) - m[1] * (m[4] * m[10] - m[6] * m[8]) + m[2] * (m[4] * m[9] - m[5] * m[8]);
    valid(Math.abs(det - 1) < 0.03);
  }
  return value;
}

// Trusted local operator entry point only. There is deliberately no HTTP import
// route accepting filesystem paths and no native capture/ARKit claim or reward.
export async function importReconstructionStudy({ dataDir, userId, manifestPath }) {
  requireThat(nonempty(dataDir, 4096) && uuid(userId) && nonempty(manifestPath, 4096), 400, 'invalid_study_import', 'dataDir, existing userId and manifestPath are required.');
  const root = path.resolve(dataDir), manifestFile = path.resolve(manifestPath);
  requireThat((await stat(manifestFile)).size <= 1024 * 1024, 413, 'study_manifest_too_large', 'Study manifest exceeds 1 MiB.');
  const manifest = JSON.parse(await readFile(manifestFile, 'utf8'));
  requireThat(uuid(manifest.id) && nonempty(manifest.title, 120), 422, 'invalid_study', 'Study ID/title are required.');
  requireThat(manifest.sourceKind === 'external_rgb_video' && manifest.captureId == null && SHA.test(manifest.sourceVideoSha256), 422, 'invalid_study_source', 'Only declared external RGB video studies are supported; no native capture ID may be claimed.');
  requireThat(!manifest.createdAt || dateString(manifest.createdAt), 422, 'invalid_study', 'Invalid study timestamp.');
  requireThat(nonempty(manifest.sourceVideoFile, 4096), 422, 'invalid_study_source', 'Provide the source video for hash verification.');
  const sourceVideo = path.resolve(path.dirname(manifestFile), manifest.sourceVideoFile);
  requireThat((await stat(sourceVideo)).size <= 500 * 1024 * 1024, 413, 'video_too_large', 'Source video exceeds 500 MiB.');
  await validateVideo(sourceVideo);
  requireThat(await digest(sourceVideo) === manifest.sourceVideoSha256, 422, 'source_hash_mismatch', 'Original video does not match the declared source hash.');
  requireThat(Array.isArray(manifest.variants) && manifest.variants.length === 2, 422, 'invalid_study_variants', 'Exactly one preview and one refined variant are required.');
  const roles = new Set(), ids = new Set();
  const stage = path.join(root, '.tmp', `study-${randomUUID()}`);
  let db, committed = false, finalDirectory;
  await mkdir(stage, { recursive: true });
  try {
    const variants = [];
    for (const item of manifest.variants) {
      requireThat(uuid(item.id) && !ids.has(item.id) && !roles.has(item.role), 422, 'invalid_study_variants', 'Duplicate or invalid variant ID/role.');
      ids.add(item.id); roles.add(item.role);
      requireThat((item.role === 'preview' && item.algorithm === 'gs_worldmirror2' && item.format === 'splat' && item.shDegree === 0) ||
        (item.role === 'refined' && item.algorithm === 'gs_mcmc' && item.format === 'ply' && item.shDegree === 3), 422, 'unsupported_study_variant', 'Use corrected SH0 splat preview and original SH3 gs_mcmc PLY.');
      requireThat(nonempty(item.sourceFile, 4096) && nonempty(item.sourceCameraFile, 4096), 422, 'invalid_study_variants', 'Both a model and camera file are required.');
      const modelFile = path.resolve(path.dirname(manifestFile), item.sourceFile);
      const cameraFile = path.resolve(path.dirname(manifestFile), item.sourceCameraFile);
      requireThat((await stat(modelFile)).size <= MAX_MODEL && (await stat(cameraFile)).size <= MAX_CAMERA, 413, 'study_asset_too_large', 'Model/camera exceeds the phone import limit.');
      const modelName = `${item.id}.${item.format}`, cameraName = `${item.id}.cameras.json`;
      const stagedModel = path.join(stage, modelName), stagedCamera = path.join(stage, cameraName);
      await copyFile(modelFile, stagedModel);
      await copyFile(cameraFile, stagedCamera);
      const modelStat = await stat(stagedModel), cameraStat = await stat(stagedCamera);
      requireThat(modelStat.size <= MAX_MODEL && cameraStat.size <= MAX_CAMERA, 413, 'study_asset_too_large', 'Staged file exceeds limit.');
      let actualSH = 0;
      const validation = await validateGaussian(stagedModel, item.format, { onHeader(header) {
        actualSH = header.properties?.some(p => p.name === 'f_rest_44') ? 3 : 0;
      } });
      requireThat(actualSH === item.shDegree, 422, 'study_sh_mismatch', 'File SH coefficients do not match the declared display tier.');
      validateStudyCameras(JSON.parse(await readFile(stagedCamera, 'utf8')));
      const sha256 = await digest(stagedModel), cameraSha256 = await digest(stagedCamera);
      requireThat(!item.sha256 || item.sha256 === sha256, 422, 'study_asset_hash_mismatch', 'Model hash does not match the manifest.');
      requireThat(!item.cameraSha256 || item.cameraSha256 === cameraSha256, 422, 'study_camera_hash_mismatch', 'Camera hash does not match the manifest.');
      const base = `/v2/reconstruction-studies/${manifest.id}/variants/${item.id}`;
      variants.push({ id: item.id, role: item.role, algorithm: item.algorithm, status: 'ready', format: item.format,
        shDegree: actualSH, pointCount: validation.gaussianCount, byteSize: modelStat.size, sha256,
        filePath: `${base}/file`, cameraPath: `${base}/cameras`, cameraSha256, cameraByteSize: cameraStat.size });
    }
    variants.sort((a, b) => a.role === 'preview' ? -1 : b.role === 'preview' ? 1 : 0);
    const identity = { id: manifest.id, title: manifest.title, sourceKind: manifest.sourceKind,
      sourceVideoSha256: manifest.sourceVideoSha256, captureId: null, variants };
    const provenance = manifest.variants.map(item => ({ id: item.id, provenance: item.provenance ?? null })).sort((a, b) => a.id.localeCompare(b.id));
    const fingerprint = createHash('sha256').update(canonical({ identity, provenance })).digest('hex');
    await writeFile(path.join(stage, 'operator-import.json'), JSON.stringify({ sourceVideoSha256: manifest.sourceVideoSha256,
      sourceManifestSha256: await digest(manifestFile), provenance, interpretation: 'Operator-bound results; source-video hash verified, model/camera registration still requires visual review.' }, null, 2));
    const study = { ...identity, createdAt: manifest.createdAt ?? new Date().toISOString(),
      lineageStatus: 'source_video_hash_verified_operator_results', qualityStatus: 'needs_review', rendererValidationStatus: 'not_device_validated' };
    await mkdir(path.join(root, 'reconstruction-studies'), { recursive: true });
    db = new DatabaseSync(path.join(root, 'pocketworld.sqlite'));
    db.exec('PRAGMA busy_timeout = 5000;');
    initializeReconstructionStudies(db);
    db.exec('BEGIN IMMEDIATE');
    try {
      requireThat(db.prepare('SELECT id FROM users WHERE id = ?').get(userId), 404, 'study_user_not_found', 'Register the target user before importing a private study.');
      requireThat(!db.prepare('SELECT id FROM reconstruction_study_tombstones_v2 WHERE id = ?').get(manifest.id), 409, 'study_deleted', 'This study was deleted and cannot be revived.');
      const prior = db.prepare('SELECT * FROM reconstruction_studies_v2 WHERE id = ?').get(manifest.id);
      if (prior) {
        requireThat(prior.userId === userId && prior.fingerprint === fingerprint, 409, 'study_conflict', 'This immutable study already has different content or ownership.');
        db.exec('COMMIT');
        return { study: JSON.parse(prior.json), imported: false };
      }
      // Unique storage directory + DB transaction make staged data invisible until
      // all files are verified. A concurrent delete wins via the tombstone check.
      const relative = path.join('reconstruction-studies', `${manifest.id}-${randomUUID()}`);
      finalDirectory = path.join(root, relative);
      renameSync(stage, finalDirectory);
      db.prepare('INSERT INTO reconstruction_studies_v2 (id,userId,json,fingerprint,directory) VALUES (?,?,?,?,?)')
        .run(manifest.id, userId, JSON.stringify(study), fingerprint, relative);
      db.exec('COMMIT'); committed = true;
      return { study, imported: true };
    } catch (error) { db.exec('ROLLBACK'); throw error; }
  } finally {
    db?.close();
    await rm(stage, { recursive: true, force: true });
    if (finalDirectory && !committed) await rm(finalDirectory, { recursive: true, force: true });
  }
}

export function reconstructionStudyStore(db) {
  initializeReconstructionStudies(db);
  const own = (id, userId) => {
    requireThat(uuid(id), 400, 'invalid_id', 'Invalid study ID.');
    const row = db.prepare('SELECT * FROM reconstruction_studies_v2 WHERE id = ? AND userId = ?').get(id, userId);
    requireThat(row, 404, 'study_not_found', 'Study not found.');
    return row;
  };
  return {
    list(userId) { return db.prepare('SELECT json FROM reconstruction_studies_v2 WHERE userId = ? ORDER BY rowid DESC').all(userId).map(row => JSON.parse(row.json)); },
    get(id, userId) { return JSON.parse(own(id, userId).json); },
    file(id, variantId, userId, cameras) {
      const row = own(id, userId), study = JSON.parse(row.json);
      const variant = study.variants.find(value => value.id === variantId);
      requireThat(variant, 404, 'study_variant_not_found', 'Study variant not found.');
      return { relative: path.join(row.directory, cameras ? `${variant.id}.cameras.json` : `${variant.id}.${variant.format}`),
        hash: cameras ? variant.cameraSha256 : variant.sha256, mime: cameras ? 'application/json' : 'application/octet-stream' };
    },
    delete(id, userId) {
      requireThat(uuid(id), 400, 'invalid_id', 'Invalid study ID.');
      db.exec('BEGIN IMMEDIATE');
      try {
        const gone = db.prepare('SELECT userId FROM reconstruction_study_tombstones_v2 WHERE id = ?').get(id);
        if (gone) {
          requireThat(gone.userId === userId, 404, 'study_not_found', 'Study not found.');
          db.exec('COMMIT'); return null;
        }
        const row = own(id, userId);
        db.prepare('INSERT INTO reconstruction_study_tombstones_v2 (id,userId,deletedAt) VALUES (?,?,?)').run(id, userId, new Date().toISOString());
        db.prepare('DELETE FROM reconstruction_studies_v2 WHERE id = ?').run(id);
        db.exec('COMMIT'); return row.directory;
      } catch (error) { db.exec('ROLLBACK'); throw error; }
    },
  };
}
