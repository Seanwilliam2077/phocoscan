import { open, readFile, readdir, rename, rm, lstat } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { ALGORITHM, WorldMirrorError, imageFile, providerId, sha256File } from './worldmirror-client.mjs';
import { validateGaussian } from './validation.mjs';
import { withProcessLease } from './process-lease.mjs';

const MANIFEST = 'manifest.json';
// No successful live response or authoritative status enum has been observed yet.
// Keep production fail-closed until an operator independently verifies and
// explicitly configures that terminal-success contract for this deployment.
export const VERIFIED_SUCCESS_STATUS = null;
const exists = file => lstat(file).then(() => true, error => { if (error.code === 'ENOENT') return false; throw error; });
const now = () => new Date().toISOString();
function check(condition, code, message) { if (!condition) throw new WorldMirrorError(code, message); }
function safeError(error) { return { code: error.code || 'local_failure', ...(Number.isInteger(error.status) ? { status: error.status } : {}), at: now() }; }
export async function readRun(directory) {
  const file = path.join(directory, MANIFEST), info = await lstat(file);
  check(info.isFile() && !info.isSymbolicLink() && info.size <= 1024 * 1024, 'invalid_manifest', 'Run manifest must be a regular file within the size limit.');
  const data = await readFile(file, 'utf8');
  let state;
  try { state = JSON.parse(data); } catch { throw new WorldMirrorError('invalid_manifest', 'Run manifest is not valid JSON.'); }
  check(state.version === 1 && state.algorithm === ALGORITHM && typeof state.origin === 'string', 'invalid_manifest', 'Unsupported run manifest.');
  providerId(state.requestId);
  for (const key of ['groupId', 'imagesAssetId', 'projectId', 'stepId']) if (state[key] !== undefined) providerId(state[key]);
  return state;
}
async function save(directory, state) {
  const destination = path.join(directory, MANIFEST), temporary = `${destination}.${randomUUID()}.tmp`;
  let file;
  try {
    file = await open(temporary, 'wx', 0o600); await file.writeFile(JSON.stringify(state, null, 2) + '\n'); await file.sync();
    await file.close(); file = null; await rename(temporary, destination);
  } finally { await file?.close(); await rm(temporary, { force: true }); }
}
// A crashed process leaves its last write intent in the manifest. A later process
// can reclaim its local lock, but never replay an ambiguous remote mutation.
async function locked(directory, action) {
  return withProcessLease(path.join(directory, '.run.lock'), action, { busyCode: 'run_busy' });
}
export function checkCapabilities(data) {
  check(data && data.available === true && data.type === ALGORITHM && data.engine === 'worldmirror2', 'provider_unavailable', 'The configured endpoint does not report available WorldMirror2 reconstruction.');
  const defaults = {}, limits = {};
  for (const field of ['max_frames', 'target_size', 'compress_gs_max_points']) {
    if (Number.isFinite(data.defaults?.[field])) defaults[field] = data.defaults[field];
    const range = data.limits?.[field];
    if (Array.isArray(range) && range.length === 2 && range.every(Number.isFinite)) limits[field] = range;
  }
  if (typeof data.defaults?.enable_bf16 === 'boolean') defaults.enable_bf16 = data.defaults.enable_bf16;
  if (Number.isFinite(data.limits?.target_size_multiple)) limits.target_size_multiple = data.limits.target_size_multiple;
  return { engine: data.engine, type: data.type, available: true, defaults, limits, coordinates: data.coordinates === 'algorithm' ? 'algorithm' : 'unknown', scale: data.scale === 'metric' ? 'metric' : 'unknown' };
}
function assertBound(state, client) {
  check(state.origin === client.origin && state.algorithm === ALGORITHM, 'origin_mismatch', 'This run belongs to a different configured provider origin.');
  if (state.successStatus != null) check(state.successStatus === client.successStatus, 'status_contract_mismatch', 'Use the same explicitly confirmed success status saved in this run.');
  else state.successStatus = client.successStatus ?? null;
}
function recordIds(state, key, response) {
  const ids = {};
  for (const field of ['id', 'group_id', 'project_id', 'step_id']) {
    try { if (response?.[field] !== undefined) ids[field] = providerId(response[field]); } catch { /* retain only valid opaque IDs, never arbitrary response content */ }
  }
  state.responseIds ??= {}; state.responseIds[key] = ids;
}
async function mutation(directory, state, key, request, accept, beforeMutation) {
  await beforeMutation?.(); // cancellation/source checks are local preconditions, not unknown writes
  state.phase = `${key}_pending`; state.operations ??= {}; state.operations[key] = { attemptedAt: now(), outcome: 'pending' };
  await save(directory, state); // must reach durable storage before network side effects
  try {
    const response = await request(); recordIds(state, key, response);
    accept(response); state.operations[key].outcome = 'confirmed'; delete state.error;
    await save(directory, state);
  } catch (error) {
    // Even an HTTP rejection is kept as an explicit operator decision. New groups
    // and images uploads have no documented idempotency key.
    state.phase = `${key}_unknown`; state.operations[key].outcome = 'unresolved'; state.error = safeError(error);
    await save(directory, state); throw error;
  }
}
async function selectedFiles(directory) {
  const names = (await readdir(directory, { withFileTypes: true })).filter(entry => entry.isFile() && /\.(jpe?g|png)$/i.test(entry.name)).map(entry => entry.name).sort();
  check(names.length >= 2 && names.length <= 32, 'invalid_images', 'This adapter accepts 2–32 selected JPEG/PNG frames in one directory.');
  const files = [];
  for (const name of names) files.push(await imageFile(path.join(directory, name)));
  check(files.reduce((total, item) => total + item.size, 0) <= 256 * 1024 * 1024, 'images_too_large', 'Total images exceed 256 MiB.');
  return files;
}
export async function uploadRun({ directory, filesDirectory, name, client, groupId, beforeMutation }) {
  if (groupId !== undefined) providerId(groupId);
  return locked(directory, async () => {
    let state;
    if (await exists(path.join(directory, MANIFEST))) {
      state = await readRun(directory); assertBound(state, client);
      if (state.phase === 'images_uploaded' || state.projectId) return state;
      check(['initialized', 'group_created'].includes(state.phase), 'mutation_unresolved', 'An earlier mutation may already have succeeded. Inspect the saved IDs at the provider; this command will not repeat it.');
      check(path.resolve(filesDirectory) === state.input.directory && name === state.name, 'input_mismatch', 'Resume with the original file directory and name.');
      check(groupId === undefined || groupId === state.groupId, 'input_mismatch', 'This run already belongs to a different provider group.');
      check(JSON.stringify(await selectedFiles(filesDirectory)) === JSON.stringify(state.input.files), 'input_changed', 'Input frames changed since this run was created.');
    } else {
      const capabilities = checkCapabilities(await client.capabilities()), files = await selectedFiles(filesDirectory);
      state = { version: 1, origin: client.origin, algorithm: ALGORITHM, successStatus: client.successStatus ?? null, name, requestId: `pw_${randomUUID().replaceAll('-', '')}`, createdAt: now(), phase: groupId ? 'group_created' : 'initialized', groupOwnership: groupId ? 'caller_supplied' : 'created_by_run', ...(groupId ? { groupId } : {}), input: { directory: path.resolve(filesDirectory), files }, capabilities };
      await save(directory, state);
    }
    if (state.phase === 'initialized') await mutation(directory, state, 'group', () => client.createGroup(state.name), response => {
      state.groupId = providerId(response?.id); state.phase = 'group_created';
    }, beforeMutation);
    if (state.phase === 'group_created') {
      check(JSON.stringify(await selectedFiles(state.input.directory)) === JSON.stringify(state.input.files), 'input_changed', 'Frames changed while the provider group was being created; no images were uploaded.');
      await mutation(directory, state, 'images', () => client.uploadImages(state.groupId, state.input.files.map(file => path.join(state.input.directory, file.name)), state.name, { expectedFiles: state.input.files }), response => {
      const id = providerId(response?.id);
      check(response.kind === 'images' && response.group_id === state.groupId && response.image_count === state.input.files.length, 'unexpected_images_response', 'Uploaded image response does not match this run and its frame count.');
      state.imagesAssetId = id; state.phase = 'images_uploaded';
      state.images = { imageCount: response.image_count, ...(typeof response.sha256 === 'string' && /^[a-f0-9]{64}$/i.test(response.sha256) ? { sha256: response.sha256 } : {}) };
      }, beforeMutation);
    }
    return state;
  });
}
export async function quickRun({ directory, client, beforeMutation }) {
  return locked(directory, async () => {
    const state = await readRun(directory); assertBound(state, client);
    if (state.projectId && state.stepId) return state;
    check(state.phase === 'images_uploaded', 'mutation_unresolved', 'Quick submission requires a confirmed image asset. Ambiguous submissions are not replayed automatically.');
    checkCapabilities(await client.capabilities());
    await mutation(directory, state, 'quick', () => client.quick({ groupId: state.groupId, imagesAssetId: state.imagesAssetId, requestId: state.requestId, name: state.name }), response => {
      const projectId = providerId(response?.project_id), stepId = providerId(response?.step_id);
      check(typeof response.status === 'string' && /^[A-Z_]{1,40}$/.test(response.status), 'unexpected_status', 'Provider submission status is not recognized.');
      Object.assign(state, { projectId, stepId, phase: 'submitted', lastStatus: response.status });
    }, beforeMutation);
    return state;
  });
}
export function inspectResult(response, state, { successStatus = VERIFIED_SUCCESS_STATUS } = {}) {
  check(response?.algorithm === ALGORITHM && response?.project?.id === state.projectId && response.project.group_id === state.groupId, 'result_mismatch', 'Result does not belong to this run, group and algorithm.');
  const step = response.step;
  check(step?.id === state.stepId && step.project_id === state.projectId && step.type === ALGORITHM, 'step_mismatch', 'Provider returned a different reconstruction step.');
  check(typeof step.status === 'string' && /^[A-Z_]{1,40}$/.test(step.status), 'unexpected_status', 'Provider step status is not recognized.');
  const resultStep = response.result_step;
  const hasPLY = response.artifacts?.ply !== null && response.artifacts?.ply !== undefined;
  if (hasPLY) check(resultStep?.id === state.stepId && resultStep.project_id === state.projectId && resultStep.type === ALGORITHM, 'result_step_mismatch', 'PLY is not bound to the selected reconstruction step.');
  const successConfirmed = typeof successStatus === 'string' && !['PENDING', 'QUEUED', 'RUNNING', 'FAILED', 'CANCELLED', 'CANCELED', 'ERROR'].includes(successStatus);
  return { status: step.status, ready: hasPLY && successConfirmed && step.status === successStatus && resultStep.status === successStatus, awaitingSuccessContract: hasPLY && !successConfirmed, terminalFailure: ['FAILED', 'CANCELLED', 'CANCELED', 'ERROR'].includes(step.status), inputRevision: step.params?.input_revision };
}
export function inspectInputs(response, state, inputRevision) {
  check(response?.source_kind === 'images' && response.images?.id === state.imagesAssetId && response.images.kind === 'images' && response.images.group_id === state.groupId, 'inputs_mismatch', 'Reconstruction inputs no longer match this run’s image asset.');
  check(response.images.image_count === state.images?.imageCount && response.images.image_count === state.input.files.length, 'inputs_mismatch', 'Reconstruction frame count does not match the uploaded source manifest.');
  check(Number.isInteger(inputRevision) && inputRevision > 0 && response.revision === inputRevision && response.prepared_revision === inputRevision && response.ready === true && response.needs_prepare === false && response.legacy === false, 'input_revision_mismatch', 'The selected step and prepared input revision do not match.');
  return { imagesAssetId: response.images.id, imageCount: response.images.image_count, inputRevision };
}
export async function resumeRun({ directory, client, maxWaitMs = 0, pollMs = 2000, downloadTimeoutMs = client.timeoutMs }) {
  check(Number.isFinite(maxWaitMs) && maxWaitMs >= 0 && maxWaitMs <= 300000, 'invalid_wait', 'One resume may wait at most 300 seconds.');
  check(Number.isFinite(pollMs) && pollMs >= 10 && pollMs <= 60000, 'invalid_poll', 'Poll delay must be between 10 milliseconds and 60 seconds.');
  check(Number.isFinite(downloadTimeoutMs) && downloadTimeoutMs > 0 && downloadTimeoutMs <= 300000, 'invalid_timeout', 'Download timeout must be 1–300000 milliseconds.');
  return locked(directory, async () => {
    const state = await readRun(directory); assertBound(state, client);
    check(state.projectId && state.stepId, 'mutation_unresolved', 'No confirmed project/step IDs are available. Resume never repeats group, image or quick creation.');
    const finalFile = path.join(directory, 'scene.ply'), receivedFile = path.join(directory, 'received.ply');
    if (state.phase === 'downloaded') {
      check(await exists(finalFile) && await sha256File(finalFile) === state.output?.sha256, 'output_changed', 'The validated output has changed or is missing.');
      return state;
    }
    const deadline = Date.now() + maxWaitMs;
    do {
      let result;
      try { result = inspectResult(await client.result(state.projectId, state.stepId), state, { successStatus: state.successStatus }); }
      catch (error) { state.error = safeError(error); await save(directory, state); throw error; }
      state.lastStatus = result.status; state.lastCheckedAt = now(); delete state.error;
      if (result.terminalFailure) { state.phase = 'provider_failed'; await save(directory, state); return state; }
      if (result.ready) {
        try { state.confirmedInputs = inspectInputs(await client.inputs(state.projectId), state, result.inputRevision); }
        catch (error) { state.error = safeError(error); await save(directory, state); throw error; }
        state.phase = 'download_pending'; await save(directory, state);
        try {
          // A completed file survived a crash before the manifest update: validate
          // that same original output instead of issuing another download.
          if (!await exists(receivedFile) && !await exists(finalFile)) await client.downloadPLY(state.projectId, state.stepId, receivedFile, { timeoutMs: downloadTimeoutMs });
          const file = await exists(finalFile) ? finalFile : receivedFile;
          const validation = await validateGaussian(file, 'ply');
          const output = { file: 'scene.ply', sha256: await sha256File(file), size: (await lstat(file)).size, ...validation, reconstructionTool: 'RealityScan Hub / WorldMirror2', qualityStatus: 'needs_review', dualUseStatus: 'not_evaluated' };
          if (file !== finalFile) await rename(receivedFile, finalFile);
          state.output = output; state.phase = 'downloaded'; delete state.error; await save(directory, state); return state;
        } catch (error) { state.phase = 'download_failed'; state.error = safeError(error); await save(directory, state); throw error; }
      }
      state.phase = result.awaitingSuccessContract ? 'awaiting_success_contract' : 'submitted'; await save(directory, state);
      if (Date.now() >= deadline) break;
      await new Promise(resolve => setTimeout(resolve, Math.min(pollMs, deadline - Date.now())));
    } while (Date.now() < deadline);
    return state;
  });
}

export function runSummary(state) {
  // Intentionally excludes private provider paths, input paths, responses and tokens.
  return { phase: state.phase, requestId: state.requestId, groupId: state.groupId, imagesAssetId: state.imagesAssetId, projectId: state.projectId, stepId: state.stepId, status: state.lastStatus, successStatus: state.successStatus ?? null, ...(state.confirmedInputs ? { confirmedInputs: state.confirmedInputs } : {}), ...(state.output ? { output: state.output } : {}), ...(state.error ? { error: state.error } : {}) };
}
