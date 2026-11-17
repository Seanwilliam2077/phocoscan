import { createReadStream } from 'node:fs';
import { copyFile, mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { WorldMirrorClient } from './worldmirror-client.mjs';
import { withProcessLease } from './process-lease.mjs';
import { ARKIT_PRIOR_ALGORITHM } from './dual-reconstruction-provider.mjs';

const exec = promisify(execFile);
const stamp = () => new Date().toISOString();
const isUUID = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);
const sha = value => createHash('sha256').update(value).digest('hex');
const readJSON = async file => JSON.parse(await readFile(file, 'utf8'));
const exists = file => stat(file).then(() => true, error => { if (error.code === 'ENOENT') return false; throw error; });
function nativeLineage(source) {
  if(source.sourceKind!=='native_arkit_capture')return {};
  check(isUUID(source.captureId)&&isUUID(source.captureReceiptId)&&/^[a-f0-9]{64}$/.test(source.sourceMetadataSha256??'')
    &&Number.isSafeInteger(source.sourceMetadataByteSize)&&source.sourceMetadataByteSize>0,'source_changed','Native source lineage is incomplete.');
  return {sourceKind:source.sourceKind,captureId:source.captureId,captureReceiptId:source.captureReceiptId,
    sourceMetadataSha256:source.sourceMetadataSha256,sourceMetadataByteSize:source.sourceMetadataByteSize};
}
async function verifyNativeMetadata(source) {
  if(source.sourceKind!=='native_arkit_capture')return;
  nativeLineage(source);
  check(typeof source.sourceMetadataPath==='string'&&(await stat(source.sourceMetadataPath)).size===source.sourceMetadataByteSize
    &&await digest(source.sourceMetadataPath)===source.sourceMetadataSha256,'source_changed','Native source metadata changed after verification.');
}
function check(condition, code, message) {
  if (!condition) { const error = new Error(message); error.code = code; throw error; }
}
async function digest(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
async function save(file, value) {
  const temporary = file + '.' + randomUUID() + '.tmp';
  const handle = await open(temporary, 'wx', 0o600);
  try { await handle.writeFile(JSON.stringify(value, null, 2) + '\n'); await handle.sync(); }
  finally { await handle.close(); }
  try { await rename(temporary, file); }
  finally { await rm(temporary, { force: true }); }
}

export function normalizeDualWorkerConfig(input) {
  check(input && typeof input === 'object', 'invalid_config', 'Worker configuration is required.');
  check(typeof input.dataDir === 'string' && typeof input.workDir === 'string', 'invalid_config', 'dataDir and workDir are required.');
  const dataDir = path.resolve(input.dataDir), workDir = path.resolve(input.workDir);
  check(dataDir !== workDir && workDir !== path.parse(workDir).root, 'invalid_config', 'Use a dedicated worker directory.');
  const origin = new URL(input.hubOrigin);
  check(['http:', 'https:'].includes(origin.protocol) && !origin.username && !origin.password && origin.pathname === '/' && !origin.search && !origin.hash,
    'invalid_config', 'hubOrigin must be an HTTP(S) origin without embedded credentials.');
  check(input.successStatus === 'SUCCESS' && input.plyProfile === 'worldmirror2-probability-v1', 'invalid_config', 'Configure the verified SUCCESS contract and WorldMirror probability profile explicitly.');
  const ffFrameCount = input.ffFrameCount ?? 16, sfmFrameCount = input.sfmFrameCount ?? 64;
  const maxConcurrentJobs = input.maxConcurrentJobs ?? 2;
  check(Number.isInteger(ffFrameCount) && ffFrameCount >= 2 && ffFrameCount <= 16 && Number.isInteger(sfmFrameCount) && sfmFrameCount >= 2 && sfmFrameCount <= 64,
    'invalid_config', 'This verified FF profile accepts 2–16 frames; SfM accepts 2–64 frames.');
  check(typeof (input.hubToken ?? '') === 'string' && !/[\r\n]/.test(input.hubToken ?? ''), 'invalid_config', 'Invalid provider credential configuration.');
  check(Number.isInteger(maxConcurrentJobs) && maxConcurrentJobs >= 1 && maxConcurrentJobs <= 4, 'invalid_config', 'maxConcurrentJobs must be 1–4.');
  check(!(input.artifactLocal && input.artifactSSH),'invalid_config','Choose one local or SSH artifact transport.');
  if(input.artifactLocal)check(path.isAbsolute(input.artifactLocal.pythonPath??'')&&path.isAbsolute(input.artifactLocal.helperPath??'')
    &&typeof input.artifactLocal.useSudo==='boolean','invalid_config','Local artifact transport needs absolute Python/helper paths and explicit useSudo.');
  return { ...input, dataDir, workDir, hubOrigin: origin.origin, hubToken: input.hubToken ?? '',
    ffmpegPath: input.ffmpegPath ?? 'ffmpeg', ffprobePath: input.ffprobePath ?? 'ffprobe', ffFrameCount, sfmFrameCount, maxConcurrentJobs };
}

function profile(config) {
  return { version: 1, dataDir: config.dataDir, hubOrigin: config.hubOrigin, credentialHash: sha(config.hubToken),
    successStatus: config.successStatus, plyProfile: config.plyProfile, ffFrameCount: config.ffFrameCount, sfmFrameCount: config.sfmFrameCount,
    ffmpegPath: config.ffmpegPath, ffprobePath: config.ffprobePath, artifactSSH: config.artifactSSH ?? null,
    ...(config.artifactLocal?{artifactLocal:config.artifactLocal}:{}) };
}

// A process identity and exclusive work-directory lock avoid two workers sharing
// a provider journal. Timeouts never steal a lock from a live process.
async function lockWorker(directory, action) {
  return withProcessLease(path.join(directory, '.dual-worker.lock'), action, { busyCode: 'worker_busy' });
}

export function selectTimestampedFrames(frames, wanted) {
  check(Array.isArray(frames) && frames.length >= wanted && wanted >= 2, 'insufficient_frames', 'Video does not contain enough timestamped frames.');
  check(frames.every((f, i) => Number.isFinite(f.timestampSeconds) && (i === 0 || f.timestampSeconds > frames[i - 1].timestampSeconds)),
    'invalid_timestamps', 'Source frame timestamps must be strictly increasing.');
  const begin = frames[0].timestampSeconds, end = frames.at(-1).timestampSeconds;
  const selected = []; let previous = -1;
  for (let i = 0; i < wanted; i++) {
    const target = begin + (end - begin) * (0.05 + 0.9 * i / (wanted - 1));
    const maximum = frames.length - (wanted - i); let best = previous + 1;
    for (let candidate = best + 1; candidate <= maximum; candidate++) {
      if (Math.abs(frames[candidate].timestampSeconds - target) < Math.abs(frames[best].timestampSeconds - target)) best = candidate;
      if (frames[candidate].timestampSeconds > target && candidate > best) break;
    }
    selected.push(frames[best]); previous = best;
  }
  return selected;
}

async function execute(program, args, maxBuffer = 64 * 1024 * 1024) {
  try { return await exec(program, args, { windowsHide: true, maxBuffer, timeout: 180000 }); }
  catch (error) {
    const safe = new Error(`${path.basename(program)} could not process the uploaded video.`);
    safe.code = error.code === 'ENOENT' ? 'media_tool_missing' : 'media_tool_failed'; throw safe;
  }
}

export async function extractUploadedFrames({ directory, source, frameCount, config, beforeMutation, posePriorUsed = false }) {
  const manifestPath = path.join(directory, 'frame-manifest.json');
  await mkdir(directory, { recursive: true });
  const assertSource = async () => {
    await beforeMutation?.();
    await verifyNativeMetadata(source);
    check((await stat(source.sourceVideoPath)).size === source.sourceByteSize && await digest(source.sourceVideoPath) === source.sourceVideoSha256,
      'source_changed', 'Uploaded video changed after verification.');
  };
  await assertSource();
  if (await exists(manifestPath)) {
    const prior = await readJSON(manifestPath);
    check(prior.version === 1 && prior.sourceVideoSha256 === source.sourceVideoSha256 && prior.frameCount === frameCount,
      'frames_changed', 'Stored frame selection belongs to another source or configuration.');
    for(const [key,value] of Object.entries(nativeLineage(source)))check(prior[key]===value,'frames_changed','Stored native frame lineage changed.');
    check(Array.isArray(prior.frames) && prior.frames.length === frameCount && typeof prior.directory === 'string', 'frames_changed', 'Stored frame selection is incomplete.');
    const relative = path.relative(directory, prior.directory);
    check(relative && !relative.startsWith('..') && !path.isAbsolute(relative), 'frames_changed', 'Stored frame directory is outside this job.');
    for (const frame of prior.frames) {
      check(/^image_\d{4}\.jpg$/.test(frame.file), 'frames_changed', 'Invalid stored frame name.');
      const file = path.join(prior.directory, frame.file);
      check((await stat(file)).size === frame.byteSize && await digest(file) === frame.sha256, 'frames_changed', 'Stored frame bytes changed.');
    }
    return { ...prior, manifestPath };
  }
  const probe = JSON.parse((await execute(config.ffprobePath, ['-v', 'error', '-show_entries',
    'format=duration:stream=codec_type,codec_name,width,height,avg_frame_rate:stream_tags=rotate:stream_side_data=rotation', '-of', 'json', source.sourceVideoPath])).stdout);
  const video = probe.streams?.find(s => s.codec_type === 'video');
  check(video && Number.isInteger(video.width) && Number.isInteger(video.height), 'invalid_video', 'No usable video stream.');
  const rawFrames = JSON.parse((await execute(config.ffprobePath, ['-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', source.sourceVideoPath])).stdout).frames;
  check(Array.isArray(rawFrames), 'invalid_timestamps', 'Source video did not return frame timestamps.');
  const selected = selectTimestampedFrames(rawFrames.map((f, i) => ({ sourceFrameIndex: i, timestampSeconds: Number(f.best_effort_timestamp_time) })), frameCount);
  const frameDirectory = path.join(directory, 'frames-' + randomUUID());
  await mkdir(frameDirectory);
  await beforeMutation?.();
  const filter = 'select=' + selected.map(f => `eq(n\\,${f.sourceFrameIndex})`).join('+');
  await execute(config.ffmpegPath, ['-hide_banner', '-nostdin', '-loglevel', 'error', '-i', source.sourceVideoPath,
    '-map', '0:v:0', '-vf', filter, '-fps_mode', 'passthrough', '-q:v', '2', path.join(frameDirectory, 'image_%04d.jpg')], 4 * 1024 * 1024);
  const names = (await readdir(frameDirectory)).filter(n => /^image_\d{4}\.jpg$/.test(n)).sort();
  check(names.length === frameCount, 'frame_count_mismatch', 'Extracted frame count differs from selected source frames.');
  await assertSource();
  let byteTotal = 0;
  const frames = [];
  for (let i = 0; i < names.length; i++) {
    const file = path.join(frameDirectory, names[i]), info = await stat(file);
    check(info.size > 0 && info.size <= 20 * 1024 * 1024, 'invalid_frame', 'Selected frame exceeds provider limits.');
    byteTotal += info.size;
    frames.push({ index: i, file: names[i], sourceFrameIndex: selected[i].sourceFrameIndex,
      sourceTimestampSeconds: selected[i].timestampSeconds, byteSize: info.size, sha256: await digest(file) });
  }
  check(byteTotal <= 256 * 1024 * 1024, 'frames_too_large', 'Selected frames exceed provider limits.');
  const manifest = { version: 1, sourceKind: source.sourceKind??'external_rgb_video', ...nativeLineage(source),sourceVideoSha256: source.sourceVideoSha256,
    sourceByteSize: source.sourceByteSize, frameCount, directory: frameDirectory, createdAt: stamp(),
    selection: 'time_quantiles_5_to_95_nearest_source_frame', metadata: { codec: video.codec_name, width: video.width, height: video.height,
      averageFrameRate: video.avg_frame_rate, audioPresent: probe.streams.some(s => s.codec_type === 'audio'),
      durationSeconds: Number(probe.format?.duration), rawFrameCount: rawFrames.length, arkitPoseAvailable:source.sourceKind==='native_arkit_capture',posePriorUsed,lidarAvailable:false }, frames };
  await save(manifestPath, manifest);
  return { ...manifest, manifestPath };
}

/** Training frames from the phone's keyframe pack (ARKit pose branch): sharp, exposure-locked
 * JPEGs the phone took from the same ARKit frames the verified metadata lists, plus person masks.
 * Files are copied byte for byte and re-verified; the manifest has the same shape as video frames
 * (`sourceFrameIndex`/`sourceTimestampSeconds` point at the matching video frame), so pose priors
 * and camera export work unchanged. */
export async function packageFrames({ directory, source, beforeMutation, posePriorUsed = true }) {
  const pack = source.keyframes;
  check(pack && /^[a-f0-9]{64}$/.test(pack.sha256 ?? '') && Array.isArray(pack.frames) && pack.frames.length >= 2 && pack.frames.length <= 64
    && typeof pack.directory === 'string', 'keyframes_changed', 'The bound keyframe pack is incomplete.');
  const manifestPath = path.join(directory, 'keyframe-manifest.json');
  await mkdir(directory, { recursive: true });
  await beforeMutation?.();
  await verifyNativeMetadata(source);
  const verify = async (manifest) => {
    for (const frame of manifest.frames) {
      const file = path.join(manifest.directory, frame.file);
      check((await stat(file)).size === frame.byteSize && await digest(file) === frame.sha256, 'frames_changed', 'Stored keyframe bytes changed.');
      if (frame.mask) check(await digest(path.join(manifest.maskDirectory, frame.mask)) === frame.maskSha256, 'frames_changed', 'Stored mask bytes changed.');
    }
  };
  if (await exists(manifestPath)) {
    const prior = await readJSON(manifestPath);
    check(prior.version === 1 && prior.selection === 'phone_keyframes' && prior.keyframesSha256 === pack.sha256
      && prior.sourceVideoSha256 === source.sourceVideoSha256 && prior.frameCount === pack.frames.length
      && prior.metadata?.posePriorUsed === posePriorUsed, 'frames_changed', 'Stored keyframes belong to another pack.');
    for (const key of [prior.directory, prior.maskDirectory].filter(Boolean)) {
      const relative = path.relative(directory, key);
      check(relative && !relative.startsWith('..') && !path.isAbsolute(relative), 'frames_changed', 'Stored keyframe directory is outside this job.');
    }
    await verify(prior);
    return { ...prior, manifestPath };
  }
  const frameDirectory = path.join(directory, 'frames-' + randomUUID());
  const maskDirectory = pack.masks ? path.join(directory, 'masks-' + randomUUID()) : null;
  await mkdir(frameDirectory);
  if (maskDirectory) await mkdir(maskDirectory);
  const frames = [];
  for (const [index, frame] of pack.frames.entries()) {
    check(/^image_\d{6}\.jpg$/.test(frame.file) && (!pack.masks || /^image_\d{6}\.png$/.test(frame.mask ?? '')), 'keyframes_changed', 'Invalid keyframe name.');
    const stored = path.join(pack.directory, 'images', frame.file);
    check(await digest(stored) === frame.sha256, 'source_changed', 'A stored keyframe changed after verification.');
    await copyFile(stored, path.join(frameDirectory, frame.file));
    if (maskDirectory) {
      const storedMask = path.join(pack.directory, 'masks', frame.mask);
      check(await digest(storedMask) === frame.maskSha256, 'source_changed', 'A stored mask changed after verification.');
      await copyFile(storedMask, path.join(maskDirectory, frame.mask));
    }
    frames.push({ index, file: frame.file, sourceFrameIndex: frame.sourceFrameIndex, sourceTimestampSeconds: frame.videoPTSSeconds,
      arTimestampSeconds: frame.arTimestampSeconds, byteSize: frame.byteSize, sha256: frame.sha256,
      ...(maskDirectory ? { mask: frame.mask, maskSha256: frame.maskSha256 } : {}), subjectMoving: frame.subjectMoving === true });
  }
  const manifest = { version: 1, sourceKind: source.sourceKind, ...nativeLineage(source), sourceVideoSha256: source.sourceVideoSha256,
    sourceByteSize: source.sourceByteSize, frameCount: frames.length, directory: frameDirectory, maskDirectory, createdAt: stamp(),
    selection: 'phone_keyframes', keyframesSha256: pack.sha256,
    metadata: { arkitPoseAvailable: true, posePriorUsed, lidarAvailable: false, masks: !!maskDirectory, mode: pack.mode ?? null,
      exposureLocked: 'see the pack meta.json' }, frames };
  await verify(manifest);
  await save(manifestPath, manifest);
  return { ...manifest, manifestPath };
}

/** Pairs each selected video frame with the ARKit pose the phone recorded for that exact frame.
 * Frames are matched by video frame index and must agree on presentation time (±2 ms); nothing is
 * interpolated. Every frame keeps a prior (the Hub requires full coverage); frames whose ARKit
 * tracking was not `normal` get a much looser one. */
export async function arkitPosePriors(source, frames) {
  check(source?.sourceKind === 'native_arkit_capture' && typeof source.sourceMetadataPath === 'string',
    'arkit_poses_required', 'ARKit pose training needs a native capture with its metadata.');
  await verifyNativeMetadata(source);
  const envelope = await readJSON(source.sourceMetadataPath);
  check(typeof envelope?.framesJSONL === 'string', 'arkit_poses_required', 'Native metadata has no frame table.');
  const records = new Map();
  for (const line of envelope.framesJSONL.split('\n')) {
    if (!line) continue;
    const record = JSON.parse(line);
    records.set(record.index, record);
  }
  const priors = frames.frames.map((frame, i) => {
    const record = records.get(frame.sourceFrameIndex);
    check(record && Math.abs(record.videoPTSSeconds - frame.sourceTimestampSeconds) <= 0.002,
      'arkit_pose_mismatch', 'A selected frame has no ARKit pose at the same video time.');
    const m = record.cameraToWorldARKit;
    check(Array.isArray(m) && m.length === 4 && m.every(row => Array.isArray(row) && row.length === 4 && row.every(Number.isFinite))
      && Math.abs(m[3][3] - 1) < 1e-6 && Number.isFinite(record.arTimestampSeconds), 'arkit_pose_mismatch', 'Invalid ARKit camera matrix.');
    return { name: `image_${String(i + 1).padStart(6, '0')}.jpg`, sourceFile: frame.file, sourceFrameIndex: frame.sourceFrameIndex,
      timestampNs: Math.round(record.arTimestampSeconds * 1e9), position: [m[0][3], m[1][3], m[2][3]],
      rotationWXYZ: worldFromOpenCVCamera(m), tracking: record.trackingState === 'normal' ? 'normal' : 'limited' };
  });
  check(priors.filter(p => p.tracking === 'normal').length >= 3, 'arkit_tracking_insufficient',
    'Fewer than three selected frames had normal ARKit tracking.');
  return priors;
}

/** World-from-camera rotation as a unit quaternion (w, x, y, z), with OpenCV camera axes
 * (x right, y down, z forward): ARKit's camera rotation times diag(1, -1, -1). */
function worldFromOpenCVCamera(m) {
  const r = [0, 1, 2].map(i => [m[i][0], -m[i][1], -m[i][2]]);
  const trace = r[0][0] + r[1][1] + r[2][2];
  let w, x, y, z;
  if (trace > 0) {
    const s = Math.sqrt(trace + 1) * 2;
    w = s / 4; x = (r[2][1] - r[1][2]) / s; y = (r[0][2] - r[2][0]) / s; z = (r[1][0] - r[0][1]) / s;
  } else if (r[0][0] > r[1][1] && r[0][0] > r[2][2]) {
    const s = Math.sqrt(1 + r[0][0] - r[1][1] - r[2][2]) * 2;
    w = (r[2][1] - r[1][2]) / s; x = s / 4; y = (r[0][1] + r[1][0]) / s; z = (r[0][2] + r[2][0]) / s;
  } else if (r[1][1] > r[2][2]) {
    const s = Math.sqrt(1 + r[1][1] - r[0][0] - r[2][2]) * 2;
    w = (r[0][2] - r[2][0]) / s; x = (r[0][1] + r[1][0]) / s; y = s / 4; z = (r[1][2] + r[2][1]) / s;
  } else {
    const s = Math.sqrt(1 + r[2][2] - r[0][0] - r[1][1]) * 2;
    w = (r[1][0] - r[0][1]) / s; x = (r[0][2] + r[2][0]) / s; y = (r[1][2] + r[2][1]) / s; z = s / 4;
  }
  const n = Math.hypot(w, x, y, z);
  check(Number.isFinite(n) && n > 1e-6, 'arkit_pose_mismatch', 'ARKit camera rotation is degenerate.');
  if (w < 0) { w = -w; x = -x; y = -y; z = -z; }
  return [w / n, x / n, y / n, z / n];
}

export const POSE_PRIOR_COLUMNS = ['image_name', 'camera_id', 'timestamp_ns', 'center_x', 'center_y', 'center_z',
  'qw', 'qx', 'qy', 'qz', 'position_std_m'];
/** Camera-centre prior standard deviations (metres): the Hub default for normal ARKit tracking,
 * and a weak prior where ARKit itself reported limited tracking. */
export const POSE_PRIOR_STD_M = Object.freeze({ normal: 0.1, limited: 1.0 });

/** The RealityScan Hub pose-prior CSV (`app/pose_priors.py`, verified on the A10 on 2026-11-06):
 * the exact header above, one row per project image (full coverage is required), ARKit world frame
 * in metres. The Hub's COLMAP writer uses the centres and `position_std_m`; the quaternion is the
 * world-from-camera rotation (OpenCV axes) for completeness. */
export function posePriorCSV(priors) {
  const fixed = (value, digits) => value.toFixed(digits);
  const rows = priors.map(p => {
    check(/^image_\d{6}\.jpg$/.test(p.name) && p.position.length === 3 && p.position.every(Number.isFinite)
      && p.rotationWXYZ?.length === 4 && p.rotationWXYZ.every(Number.isFinite) && Number.isSafeInteger(p.timestampNs)
      && Object.hasOwn(POSE_PRIOR_STD_M, p.tracking), 'invalid_pose_prior', 'Invalid pose prior row.');
    return [p.name, 'iphone_arkit', String(p.timestampNs), ...p.position.map(v => fixed(v, 9)),
      ...p.rotationWXYZ.map(v => fixed(v, 9)), fixed(POSE_PRIOR_STD_M[p.tracking], 6)].join(',');
  });
  return POSE_PRIOR_COLUMNS.join(',') + '\n' + rows.join('\n') + '\n';
}

function safeFailure(error) {
  const code = typeof error?.code === 'string' && /^[a-z0-9_]{1,80}$/i.test(error.code) ? error.code : 'worker_failure';
  // Provider response bodies, paths and credentials never enter public error strings.
  const message = code === 'source_changed' ? 'Uploaded source changed; processing stopped.'
    : code === 'media_tool_missing' ? 'Video decoding tools are not configured.'
    : code === 'gpu_memory_unavailable' ? 'No GPU currently has enough free memory; retry later.'
    : code === 'sfm_quality_insufficient' ? 'Camera alignment was not reliable; capture more overlap or explicitly choose the ARKit version.'
    : code === 'provider_cancelled' ? 'The provider cancelled this reconstruction.'
    : 'Processing stopped safely; the operator can inspect the private job journal.';
  return { code, message };
}

export async function runDualWorkerOnce(input, dependencies = {}) {
  const config = normalizeDualWorkerConfig(input);
  return lockWorker(config.workDir, async () => {
    const currentProfile = profile(config), identityFile = path.join(config.workDir, 'worker-identity.json');
    let identity;
    if (await exists(identityFile)) {
      identity = await readJSON(identityFile);
      check(JSON.stringify(identity.profile) === JSON.stringify(currentProfile) && isUUID(identity.id), 'worker_profile_mismatch', 'Resume with the exact saved provider, credentials and sampling configuration.');
    } else { identity = { id: randomUUID(), profile: currentProfile, createdAt: stamp() }; await save(identityFile, identity); }
    const repository = dependencies.repository ?? (await import('./video-reconstructions.mjs')).openVideoReconstructionRepository({ dataDir: config.dataDir });
    const providerStep = dependencies.providerStep ?? (await import('./dual-reconstruction-provider.mjs')).advanceDualProvider;
    const materialize = dependencies.materialize ?? (await import('./dual-reconstruction-assets.mjs')).materializeDualResult;
    const extractFrames = dependencies.extractFrames ?? extractUploadedFrames;
    const client = dependencies.client ?? new WorldMirrorClient({ origin: config.hubOrigin, token: config.hubToken,
      successStatus: config.successStatus, timeoutMs: 45000, maxJSONBytes: 8 * 1024 * 1024 });
    try {
      const jobs = repository.pendingJobs().filter(job => job.status === 'queued' || (job.status === 'processing' && job.workerId === identity.id))
        .sort((a, b) => Number(b.status === 'processing') - Number(a.status === 'processing')).slice(0, config.maxConcurrentJobs);
      const results = await Promise.all(jobs.map(async available => {
        if (!isUUID(available.id)) return { status: 'failed', error: { code: 'invalid_job', message: 'Invalid job identifier.' } };
        let job, source;
        const directory = path.join(config.workDir, available.id);
        try {
          check(isUUID(available.id), 'invalid_job', 'Invalid job identifier.');
          job = repository.claim(available.id, identity.id);
          source = repository.source(job.id, job.claimId);
          const beforeMutation = async () => {
            const live = repository.source(job.id, job.claimId);
            check(live.sourceVideoSha256 === source.sourceVideoSha256 && live.sourceByteSize === source.sourceByteSize
              && live.reconstructionId === source.reconstructionId && live.algorithm === source.algorithm
              && (live.keyframes?.sha256 ?? null) === (source.keyframes?.sha256 ?? null)
              &&JSON.stringify(nativeLineage(live))===JSON.stringify(nativeLineage(source)),
            'source_changed', 'This job now refers to another source.');
            check((await stat(live.sourceVideoPath)).size === live.sourceByteSize && await digest(live.sourceVideoPath) === live.sourceVideoSha256,
              'source_changed', 'Uploaded source bytes changed.');
            await verifyNativeMetadata(live);
          };
          await mkdir(directory, { recursive: true });
          const bindingFile = path.join(directory, 'source-binding.json');
          const binding = { jobId: job.id, reconstructionId: source.reconstructionId, sourceVideoSha256: source.sourceVideoSha256,
            sourceByteSize: source.sourceByteSize, algorithm: job.algorithm, role: job.role,...nativeLineage(source),
            ...(source.keyframes ? { keyframesSha256: source.keyframes.sha256 } : {}) };
          if (await exists(bindingFile)) check(JSON.stringify(await readJSON(bindingFile)) === JSON.stringify(binding), 'source_changed', 'Job directory belongs to another source.');
          else await save(bindingFile, binding);
          await beforeMutation();
          repository.setPhase(job.id, job.claimId, 'processing', 'selecting_frames');
          const usesPrior = job.algorithm === ARKIT_PRIOR_ALGORITHM;
          check(!source.keyframes || usesPrior || job.algorithm === 'gs_mcmc', 'keyframes_changed', 'Only SfM-family tasks train from keyframes.');
          const frames = source.keyframes
            ? await (dependencies.packageFrames ?? packageFrames)({ directory, source, beforeMutation, posePriorUsed: usesPrior })
            : await extractFrames({ directory, source, frameCount: job.algorithm === 'gs_worldmirror2' ? config.ffFrameCount : config.sfmFrameCount, config, beforeMutation, posePriorUsed: usesPrior });
          await beforeMutation();
          const priorCSV = usesPrior ? posePriorCSV(await arkitPosePriors(source, frames)) : undefined;
          const result = await providerStep({ algorithm: job.algorithm, directory: path.join(directory, 'provider'),
            framesDirectory: frames.directory, sourceVideoSha256: source.sourceVideoSha256, client, beforeMutation, posePriorCSV: priorCSV,
            ...(frames.maskDirectory ? { masksDirectory: frames.maskDirectory } : {}) });
          check(result && ['queued', 'processing', 'ready', 'failed', 'blocked'].includes(result.status), 'invalid_provider_status', 'Provider returned an invalid processing state.');
          await beforeMutation();
          if (result.status === 'ready') {
            repository.setPhase(job.id, job.claimId, 'processing', 'packaging');
            const asset = await materialize({ directory, job, source, frames, providerResult: result, config });
            await beforeMutation();
            asset.provenance = { ...(asset.provenance ?? {}), sourceVideoSha256: source.sourceVideoSha256,
              frameManifestSha256: await digest(frames.manifestPath),...nativeLineage(source) };
            const published = await repository.publish(job.id, job.claimId, asset);
            return { jobId: job.id, algorithm: job.algorithm, status: 'ready', phase: 'published', sha256: published.sha256 };
          }
          const status = ['failed', 'blocked'].includes(result.status) ? result.status : 'processing';
          repository.setPhase(job.id, job.claimId, status, result.phase, result.error ? safeFailure(result.error) : undefined);
          return { jobId: job.id, algorithm: job.algorithm, status, phase: result.phase };
        } catch (error) {
          const failure = safeFailure(error);
          const sourceGone = error.status === 404 || ['reconstruction_not_found', 'video_reconstruction_not_found', 'source_inactive', 'job_not_found'].includes(error.code);
          const blocked = error.outcomeUnknown || /unknown|unresolved|mismatch|changed|claim/.test(failure.code);
          const retryable = error.retryable === true && !blocked && !sourceGone;
          if (job && !sourceGone) {
            try { repository.setPhase(job.id, job.claimId, retryable ? 'processing' : blocked ? 'blocked' : 'failed', retryable ? 'artifact_read_retry' : blocked ? 'operator_review_required' : 'worker_failed', failure); }
            catch { /* Source deletion/claim change must win over a late worker. */ }
          }
          await mkdir(directory, { recursive: true });
          await save(path.join(directory, 'worker-error.json'), { ...failure, at: stamp(), outcomeUnknown: !!error.outcomeUnknown });
          return { jobId: available.id, algorithm: available.algorithm, status: sourceGone ? 'cancelled' : retryable ? 'processing' : blocked ? 'blocked' : 'failed', error: failure };
        }
      }));
      return { workerId: identity.id, checkedAt: stamp(), phase: jobs.length ? 'processed' : 'idle', jobs: results };
    } finally { if (!dependencies.repository) repository.close(); }
  });
}
