import { open, readFile, readdir, rename, rm, lstat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { WorldMirrorError, imageFile, providerId, sha256File } from './worldmirror-client.mjs';
import { uploadRun, quickRun, resumeRun, readRun, inspectResult, inspectInputs } from './worldmirror-run.mjs';
import { validateGaussian } from './validation.mjs';
import { withProcessLease } from './process-lease.mjs';

export const ARKIT_PRIOR_ALGORITHM = 'gs_mcmc_arkit_prior';
const ALGORITHMS = new Set(['gs_worldmirror2', 'gs_mcmc', ARKIT_PRIOR_ALGORITHM]);
// gs_mcmc_arkit_prior runs the Hub's own gs_mcmc step with an uploaded ARKit camera-position
// prior (COLMAP pose_prior_mapper: soft priors + bundle adjustment, not fixed poses).
const isSfMFamily = algorithm => algorithm === 'gs_mcmc' || algorithm === ARKIT_PRIOR_ALGORITHM;
const hubAlgorithm = algorithm => isSfMFamily(algorithm) ? 'gs_mcmc' : algorithm;
const SFM_PARAMS = Object.freeze({ matcher: 'exhaustive', camera_model: 'SIMPLE_PINHOLE',
  cap_max: 300000, steps: 7000, resize_long_side: 960, sift_peak_threshold: 0.00667 });
const FILE = 'provider-state.json';
const SHA = /^[a-f0-9]{64}$/;
const FAILURES = new Set(['FAILED', 'CANCELLED', 'CANCELED', 'ERROR']);
const exists = file => lstat(file).then(() => true, e => { if (e.code === 'ENOENT') return false; throw e; });
const check = (condition, code, message) => { if (!condition) throw new WorldMirrorError(code, message); };
const stamp = () => new Date().toISOString();
const safeError = e => ({ code: /^[a-z0-9_]{1,80}$/.test(e.code ?? '') ? e.code : 'provider_failure',
  message: e instanceof WorldMirrorError ? e.message : 'The provider operation did not complete.',
  ...(Number.isInteger(e.status) ? { httpStatus: e.status } : {}) });

// Only allowlisted classifications cross into the app; provider text remains private.
function terminalFailure(step) {
  const report = step?.report ?? {};
  if (report.cancelled === true || report.phase === 'cancelled' || ['CANCELLED', 'CANCELED'].includes(step?.status))
    return { code: 'provider_cancelled', message: 'The provider cancelled this reconstruction.' };
  const detail = typeof report.error === 'string' ? report.error : '';
  if (/GPU 显存不足,未启动 3DGS/.test(detail))
    return { code: 'gpu_memory_unavailable', message: 'No GPU currently has enough free memory to start this reconstruction.' };
  return { code: 'provider_failed', message: 'The reconstruction provider reported failure.' };
}

async function save(directory, state, file = FILE) {
  const destination = path.join(directory, file), temporary = destination + '.' + randomUUID() + '.tmp';
  let handle;
  try {
    handle = await open(temporary, 'wx', 0o600); await handle.writeFile(JSON.stringify(state, null, 2) + '\n'); await handle.sync();
    await handle.close(); handle = null; await rename(temporary, destination);
  } finally { await handle?.close(); await rm(temporary, { force: true }); }
}
async function readState(directory) {
  const file = path.join(directory, FILE), info = await lstat(file);
  check(info.isFile() && !info.isSymbolicLink() && info.size <= 2 * 1024 * 1024, 'invalid_provider_state', 'Provider state must be a bounded regular file.');
  return JSON.parse(await readFile(file, 'utf8'));
}
async function locked(directory, action) {
  return withProcessLease(path.join(directory, '.dual-provider.lock'), action, { busyCode: 'provider_busy' });
}
async function filesIn(directory, algorithm) {
  const entries = await readdir(directory, { withFileTypes: true });
  const names = entries.filter(e => e.isFile() && /\.(jpg|jpeg|png)$/i.test(e.name)).map(e => e.name).sort();
  check(names.length >= 2 && names.length <= (isSfMFamily(algorithm) ? 64 : 32), 'invalid_images', 'Expected 2–64 SfM or 2–32 FF selected images.');
  const files = await Promise.all(names.map(name => imageFile(path.join(directory, name))));
  check(files.reduce((n, f) => n + f.size, 0) <= 256 * 1024 * 1024, 'images_too_large', 'Selected frames exceed 256 MiB.');
  return files;
}
function boundResult(result, state, stepId = state.stepId) {
  check(result?.algorithm === hubAlgorithm(state.algorithm) && result.project?.id === state.projectId && result.project?.group_id === state.groupId,
    'result_binding_mismatch', 'Provider project/algorithm/group differs from this run.');
  const step = stepId === state.importStepId ? result.import_step : result.step;
  check(step?.id === stepId && step.project_id === state.projectId && step.type === (stepId === state.importStepId ? 'gs_import' : hubAlgorithm(state.algorithm)),
    'result_binding_mismatch', 'Provider result step differs from the persisted attempt.');
  check(typeof step.status === 'string' && /^[A-Z_]{1,40}$/.test(step.status), 'invalid_status', 'Provider status is invalid.');
  return step;
}
/** When the Hub reports the project's masks, they must be exactly this run's mask asset. */
function checkMasks(inputs, state) {
  const reported = inputs?.masks?.id ?? inputs?.masks_asset_id;
  if (reported !== undefined && reported !== null) check(state.masksAssetId && reported === state.masksAssetId, 'inputs_mismatch', 'Project masks differ from this run.');
  else check(!state.masksAssetId || (inputs?.masks === undefined && inputs?.masks_asset_id === undefined), 'inputs_mismatch', 'The Hub dropped this run’s masks.');
}
function summary(state) {
  return { status: state.status, phase: state.phase, algorithm: state.algorithm,
    projectId: state.projectId, stepId: state.stepId, groupId: state.groupId, imagesAssetId: state.imagesAssetId,
    inputRevision: state.inputRevision, importStepId: state.importStepId,
    ...(state.posePrior ? { posePriorSha256: state.posePrior.sha256 } : {}),
    ...(state.masksAssetId ? { masksAssetId: state.masksAssetId } : {}),
    ...(state.output ? { plyPath: path.join(state.directory, 'scene.ply'), plySha256: state.output.sha256,
      byteSize: state.output.size, pointCount: state.output.gaussianCount, resultPath: path.join(state.directory, 'provider-result.json') } : {}),
    ...(state.error ? { error: state.error } : {}) };
}
function resultBinding(state, result) {
  return { ...result, projectId: state.projectId, stepId: state.stepId,
    groupId: state.groupId, imagesAssetId: state.imagesAssetId,
    inputRevision: state.inputRevision, importStepId: state.importStepId,
    sourceVideoSha256: state.sourceVideoSha256 };
}
async function mutate(directory, state, key, beforeMutation, request, accept) {
  if (state.operations[key]?.outcome === 'confirmed') return;
  check(!state.operations[key], 'mutation_unresolved', 'A prior provider write has an unknown outcome; operator reconciliation is required.');
  await beforeMutation?.();
  state.phase = key + '_pending'; state.operations[key] = { outcome: 'pending', attemptedAt: stamp() };
  await save(directory, state); // Durable write intent before every provider mutation.
  try {
    const response = await request(); accept(response);
    state.operations[key].outcome = 'confirmed'; state.operations[key].confirmedAt = stamp();
    delete state.error; await save(directory, state);
  } catch (e) {
    state.phase = key + '_unknown'; state.operations[key].outcome = 'unresolved'; state.status = 'blocked';
    state.error = safeError(e); await save(directory, state); throw e;
  }
}
async function download(client, endpoint, directory) {
  const final = path.join(directory, 'scene.ply'), temporary = final + '.' + randomUUID() + '.partial'; let file;
  if (await exists(final)) return final;
  try {
    file = await open(temporary, 'wx', 0o600);
    await client.request(endpoint, { timeoutMs: Math.min(300000, Math.max(client.timeoutMs, 120000)), consume: async response => {
      check(Number(response.headers.get('content-length')) <= client.maxPLYBytes, 'ply_too_large', 'Provider model exceeds file limit.');
      let bytes = 0;
      for await (const chunk of response.body ?? []) {
        bytes += chunk.length; check(bytes <= client.maxPLYBytes, 'ply_too_large', 'Provider model exceeds file limit.');
        await file.writeFile(chunk);
      }
      check(bytes > 0, 'empty_ply', 'Provider returned an empty Gaussian file.'); await file.sync();
    } });
    await file.close(); file = null; await rename(temporary, final); return final;
  } finally { await file?.close(); await rm(temporary, { force: true }); }
}
async function advanceFF(directory, state, client, beforeMutation) {
  let run;
  if (await exists(path.join(directory, 'manifest.json'))) run = await readRun(directory);
  if (!run?.projectId) {
    run = await uploadRun({ directory, filesDirectory: state.input.directory, name: state.name, client, beforeMutation });
    run = await quickRun({ directory, client, beforeMutation });
  }
  Object.assign(state, { groupId: run.groupId, imagesAssetId: run.imagesAssetId, projectId: run.projectId, stepId: run.stepId });
  await save(directory, state);
  const raw = await client.result(run.projectId, run.stepId);
  const inspected = inspectResult(raw, run, { successStatus: 'SUCCESS' });
  await save(directory, raw, 'provider-result.json');
  if (inspected.terminalFailure) { state.status = 'failed'; state.phase = 'provider_failed'; state.error = terminalFailure(raw.step); return; }
  if (!inspected.ready) { state.status = 'processing'; state.phase = raw.step?.report?.phase === 'waiting_gpu' ? 'waiting_gpu' : 'ff_processing'; return; }
  check(raw.step.exit_code === 0, 'provider_exit_code', 'WorldMirror success did not report exit code zero.');
  await beforeMutation?.(); // Deletion check before downloading; no new remote mutation.
  run = await resumeRun({ directory, client, maxWaitMs: 0 });
  check(run.phase === 'downloaded', 'output_not_ready', 'WorldMirror model is not validated yet.');
  state.inputRevision = run.confirmedInputs.inputRevision;
  await save(directory, resultBinding(state, raw), 'provider-result.json');
  state.output = run.output; state.status = 'ready'; state.phase = 'provider_ready';
}
async function advanceSfM(directory, state, client, beforeMutation) {
  await mutate(directory, state, 'group', beforeMutation, () => client.createGroup(state.name), r => { state.groupId = providerId(r.id); });
  await mutate(directory, state, 'images', beforeMutation,
    () => client.uploadImages(state.groupId, state.input.files.map(f => path.join(state.input.directory, f.name)), state.name, { expectedFiles: state.input.files }), r => {
      check(r.kind === 'images' && r.group_id === state.groupId && r.image_count === state.input.files.length, 'images_mismatch', 'Uploaded image asset differs from selected frames.');
      state.imagesAssetId = providerId(r.id); state.images = { imageCount: r.image_count };
    });
  if (state.masks) {
    // Person masks (white = keep) for this exact image asset; the Hub matches them by file stem.
    await mutate(directory, state, 'masks', beforeMutation,
      () => client.uploadMasks(state.groupId, state.imagesAssetId, state.masks.files.map(f => path.join(state.masks.directory, f.name)), state.name,
        { expectedFiles: state.masks.files }), r => {
        check(r?.id && (r.kind === undefined || r.kind === 'masks') && (r.group_id === undefined || r.group_id === state.groupId),
          'masks_mismatch', 'Uploaded mask asset differs from this run.');
        state.masksAssetId = providerId(r.id);
      });
  }
  await mutate(directory, state, 'scene', beforeMutation,
    () => client.request('/api/3dgs/scenes', { method: 'POST', json: { name: state.name, group_id: state.groupId } }), r => {
      check(r.group_id === state.groupId, 'scene_mismatch', 'Created SfM scene belongs to another group.'); state.projectId = providerId(r.id);
    });
  await mutate(directory, state, 'inputs', beforeMutation,
    () => client.request(`/api/projects/${state.projectId}/3dgs/inputs`, { method: 'PATCH', json: { source_kind: 'images', images_asset_id: state.imagesAssetId,
      ...(state.masksAssetId ? { masks_asset_id: state.masksAssetId } : {}) } }), () => {});
  await mutate(directory, state, 'prepare', beforeMutation,
    () => client.request(`/api/projects/${state.projectId}/3dgs/prepare`, { method: 'POST' }), r => { state.importStepId = providerId(r.step_id); });

  if (!state.stepId) {
    const result = await client.request(`/api/projects/${state.projectId}/3dgs?algorithm=gs_mcmc`);
    const step = boundResult(result, state, state.importStepId);
    await save(directory, result, 'provider-prepare-result.json');
    if (FAILURES.has(step.status)) { state.status = 'failed'; state.phase = 'prepare_failed'; state.error = { code: 'prepare_failed', message: 'SfM input preparation failed.' }; return; }
    if (step.status !== 'SUCCESS') { state.status = 'processing'; state.phase = 'preparing'; return; }
    check(step.exit_code === 0, 'provider_exit_code', 'SfM preparation did not report exit code zero.');
    const inputs = await client.inputs(state.projectId);
    const binding = inspectInputs(inputs, state, inputs.revision);
    checkMasks(inputs, state);
    if (state.inputRevision !== undefined) check(state.inputRevision === binding.inputRevision, 'input_revision_mismatch', 'SfM inputs changed after preparation.');
    state.inputRevision = binding.inputRevision; await save(directory, state);
    if (state.algorithm === ARKIT_PRIOR_ALGORITHM) {
      const priorFile = path.join(directory, 'pose-prior.csv');
      check(state.posePrior && await sha256File(priorFile) === state.posePrior.sha256, 'input_changed', 'The persisted ARKit pose prior changed.');
      await mutate(directory, state, 'pose_prior', beforeMutation,
        () => client.uploadPosePrior(state.projectId, priorFile, { expectedSha256: state.posePrior.sha256 }), () => {});
    }
    await mutate(directory, state, 'run', beforeMutation,
      () => client.request(`/api/projects/${state.projectId}/steps/gs_mcmc/run`, { method: 'POST', json: state.params }), r => { state.stepId = providerId(r.step_id); });
  }
  const result = await client.request(`/api/projects/${state.projectId}/3dgs?algorithm=gs_mcmc&step_id=${state.stepId}`);
  const step = boundResult(result, state);
  await save(directory, result, 'provider-result.json');
  if (FAILURES.has(step.status)) { state.status = 'failed'; state.phase = 'provider_failed'; state.error = terminalFailure(step); return; }
  if (step.status !== 'SUCCESS') { state.status = 'processing'; state.phase = step.report?.phase === 'waiting_gpu' ? 'waiting_gpu' : 'sfm_gs_processing'; return; }
  check(step.exit_code === 0 && result.result_step?.id === state.stepId && result.result_step?.status === 'SUCCESS' && result.artifacts?.ply,
    'result_binding_mismatch', 'A validated Gaussian artifact for this exact successful SfM attempt is required.');
  // Image-only SfM must not have used a prior; the ARKit branch must actually have used one.
  check(step.params?.input_revision === state.inputRevision && step.params?.import_step_id === state.importStepId
    && step.report?.use_pose_prior === (state.algorithm === ARKIT_PRIOR_ALGORITHM),
    'input_revision_mismatch', 'SfM results do not match the expected prepared input and pose-prior mode.');
  inspectInputs(await client.inputs(state.projectId), state, state.inputRevision);
  await beforeMutation?.();
  const file = await download(client, `/api/projects/${state.projectId}/3dgs/point_cloud.ply?algorithm=gs_mcmc&step_id=${state.stepId}`, directory);
  let sh3 = false;
  const validation = await validateGaussian(file, 'ply', { onHeader: h => { sh3 = h.properties.some(p => p.name === 'f_rest_44'); } });
  check(sh3, 'sh_degree_mismatch', 'SfM refined output must preserve full SH3 coefficients.');
  await save(directory, resultBinding(state, result), 'provider-result.json');
  state.output = { file: 'scene.ply', sha256: await sha256File(file), size: (await lstat(file)).size, ...validation };
  state.status = 'ready'; state.phase = 'provider_ready';
}

/** Advance one durable provider task. ready means a validated ORIGINAL PLY is local;
 * callers must still retrieve matching cameras and publish a validated phone asset.
 * This adapter never creates an application ready state or a growth receipt. */
export async function advanceDualProvider({ algorithm, directory, framesDirectory, sourceVideoSha256, client, beforeMutation, posePriorCSV, masksDirectory }) {
  check(ALGORITHMS.has(algorithm) && SHA.test(sourceVideoSha256), 'invalid_provider_profile', 'A supported algorithm and original-video SHA-256 are required.');
  check(client?.successStatus === 'SUCCESS', 'unverified_success_contract', 'Use the independently verified SUCCESS contract.');
  check((algorithm === ARKIT_PRIOR_ALGORITHM) === (typeof posePriorCSV === 'string' && posePriorCSV.length > 0) && (posePriorCSV ?? '').length <= 1024 * 1024,
    'invalid_pose_prior', 'The ARKit branch, and only it, requires a bounded pose prior.');
  const priorSha256 = posePriorCSV ? createHash('sha256').update(posePriorCSV).digest('hex') : null;
  directory = path.resolve(directory); framesDirectory = path.resolve(framesDirectory);
  check(!masksDirectory || isSfMFamily(algorithm), 'invalid_masks', 'Only SfM-family keyframe branches take masks.');
  return locked(directory, async () => {
    const files = await filesIn(framesDirectory, algorithm);
    let masks = null;
    if (masksDirectory) {
      masksDirectory = path.resolve(masksDirectory);
      const names = (await readdir(masksDirectory)).filter(n => /\.png$/i.test(n)).sort();
      check(names.length === files.length && names.every((n, i) => path.parse(n).name === path.parse(files[i].name).name),
        'invalid_masks', 'Every selected image needs exactly one mask with the same name.');
      masks = { directory: masksDirectory, files: await Promise.all(names.map(n => imageFile(path.join(masksDirectory, n)))) };
    }
    let state;
    if (await exists(path.join(directory, FILE))) {
      state = await readState(directory);
      check(state.version === 1 && state.algorithm === algorithm && state.origin === client.origin && state.sourceVideoSha256 === sourceVideoSha256 && state.directory === directory,
        'provider_profile_mismatch', 'This persisted task has a different source, origin or algorithm.');
      check(state.input.directory === framesDirectory && JSON.stringify(state.input.files) === JSON.stringify(files), 'input_changed', 'Selected frame bytes changed after the task was created.');
      check(JSON.stringify(state.params) === JSON.stringify(isSfMFamily(algorithm) ? SFM_PARAMS : null), 'provider_profile_mismatch', 'Persisted algorithm configuration differs from this worker.');
      check((state.posePrior?.sha256 ?? null) === priorSha256, 'input_changed', 'The ARKit pose prior differs from the persisted task.');
      check(JSON.stringify(state.masks ?? null) === JSON.stringify(masks), 'input_changed', 'The masks differ from the persisted task.');
      if (state.status === 'ready') {
        check(await sha256File(path.join(directory, 'scene.ply')) === state.output.sha256 && await exists(path.join(directory, 'provider-result.json')), 'output_changed', 'A completed provider artifact changed or is missing.');
        return summary(state);
      }
      if (state.status === 'failed' || state.status === 'blocked') return summary(state);
      if (Object.values(state.operations).some(op => op.outcome !== 'confirmed')) {
        state.status = 'blocked'; state.phase = 'mutation_unresolved'; state.error = { code: 'mutation_unresolved', message: 'A previous provider mutation needs reconciliation; it will not be replayed.' };
        await save(directory, state); return summary(state);
      }
    } else {
      state = { version: 1, directory, algorithm, origin: client.origin, sourceVideoSha256,
        name: `PocketWorld-${{ gs_mcmc: 'SfM', [ARKIT_PRIOR_ALGORITHM]: 'ARKit' }[algorithm] ?? 'FF'}-${randomUUID().replaceAll('-', '').slice(0,20)}`,
        createdAt: stamp(), status: 'processing', phase: 'initialized', input: { directory: framesDirectory, files }, operations: {}, params: isSfMFamily(algorithm) ? SFM_PARAMS : null,
        ...(priorSha256 ? { posePrior: { sha256: priorSha256, byteSize: Buffer.byteLength(posePriorCSV) } } : {}),
        ...(masks ? { masks } : {}) };
      // The prior is written once, before any provider mutation, and re-verified on every resume.
      if (posePriorCSV) {
        const priorFile = path.join(directory, 'pose-prior.csv');
        if (await exists(priorFile)) check(await sha256File(priorFile) === priorSha256, 'input_changed', 'A stale ARKit pose prior is present.');
        else await writeFile(priorFile, posePriorCSV, { flag: 'wx', mode: 0o600 });
      }
      await save(directory, state);
    }
    try {
      await beforeMutation?.();
      if (algorithm === 'gs_worldmirror2') await advanceFF(directory, state, client, beforeMutation);
      else await advanceSfM(directory, state, client, beforeMutation);
      if (state.status !== 'failed') delete state.error;
      await save(directory, state); return summary(state);
    } catch (e) {
      const transient = ['request_timeout', 'request_failed', 'provider_busy', 'run_busy'].includes(e.code) || (e.code === 'provider_http' && e.status >= 500);
      const ffPending = algorithm === 'gs_worldmirror2' && await exists(path.join(directory, 'manifest.json'))
        ? /_(pending|unknown)$/.test((await readRun(directory)).phase) : false;
      const unknown = ffPending || Object.values(state.operations).some(op => op.outcome !== 'confirmed');
      state.status = unknown || !transient ? 'blocked' : 'processing';
      state.phase = unknown ? 'mutation_unresolved' : transient ? 'provider_read_retry' : 'provider_blocked';
      state.error = safeError(e); await save(directory, state); return summary(state);
    }
  });
}
