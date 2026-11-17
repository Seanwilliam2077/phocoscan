import { openAsBlob, createReadStream } from 'node:fs';
import { lstat, open, readFile, rename, rm } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';

export const ALGORITHM = 'gs_worldmirror2';
export class WorldMirrorError extends Error {
  constructor(code, message, { status, outcomeUnknown = false } = {}) {
    super(message); Object.assign(this, { code, status, outcomeUnknown });
  }
}
export function originOnly(value) {
  let url;
  try { url = new URL(value); } catch { throw new WorldMirrorError('invalid_origin', 'Set WORLDMIRROR_URL to the configured HTTP(S) origin.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new WorldMirrorError('invalid_origin', 'The provider URL must be an HTTP(S) origin without credentials, path or query.');
  }
  return url.origin;
}
export function providerId(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) throw new WorldMirrorError('invalid_id', 'The provider returned an unsupported identifier.');
  return value;
}
function safeName(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 100 || /[\x00-\x1f]/.test(value)) throw new WorldMirrorError('invalid_name', 'Use a nonempty name of at most 100 characters.');
  return value;
}
export async function sha256File(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
export async function imageFile(file) {
  const info = await lstat(file), extension = path.extname(file).toLowerCase();
  if (!info.isFile() || info.isSymbolicLink() || !['.jpg', '.jpeg', '.png'].includes(extension) || info.size < 1 || info.size > 20 * 1024 * 1024) {
    throw new WorldMirrorError('invalid_image', 'Each input must be a regular JPEG/PNG file between 1 byte and 20 MiB.');
  }
  return { name: path.basename(file), size: info.size, sha256: await sha256File(file) };
}

// Credentials are scoped to this configured origin. Redirects and response-provided
// download URLs are never followed. Errors deliberately exclude response bodies.
export class WorldMirrorClient {
  #token;
  constructor({ origin, token = '', successStatus = null, timeoutMs = 30000, fetchImpl = fetch, maxJSONBytes = 1024 * 1024, maxPLYBytes = 150 * 1024 * 1024 } = {}) {
    this.origin = originOnly(origin);
    if (typeof token !== 'string' || /[\r\n]/.test(token)) throw new WorldMirrorError('invalid_token', 'Invalid provider credential configuration.');
    if (!Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > 300000) throw new WorldMirrorError('invalid_timeout', 'Request timeout must be 1–300000 milliseconds.');
    if (successStatus !== null && (typeof successStatus !== 'string' || !/^[A-Z_]{1,40}$/.test(successStatus) || ['PENDING', 'QUEUED', 'RUNNING', 'FAILED', 'CANCELLED', 'CANCELED', 'ERROR'].includes(successStatus))) throw new WorldMirrorError('invalid_success_status', 'Configure only the provider’s independently confirmed terminal-success status.');
    this.#token = token;
    Object.assign(this, { successStatus, timeoutMs, fetchImpl, maxJSONBytes, maxPLYBytes });
  }
  async request(endpoint, { method = 'GET', json, body, consume, timeoutMs = this.timeoutMs } = {}) {
    if (typeof endpoint !== 'string' || !endpoint.startsWith('/api/') || endpoint.includes('\\') || new URL(endpoint, this.origin).origin !== this.origin) {
      throw new WorldMirrorError('unsafe_endpoint', 'Only fixed provider API paths may be requested.');
    }
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), timeoutMs);
    const mutates = method !== 'GET';
    try {
      const headers = this.#token ? { Authorization: `Bearer ${this.#token}` } : {};
      if (json !== undefined) { headers['Content-Type'] = 'application/json'; body = JSON.stringify(json); }
      const response = await this.fetchImpl(this.origin + endpoint, { method, headers, body, signal: controller.signal, redirect: 'error' });
      if (!response.ok) {
        await response.body?.cancel();
        throw new WorldMirrorError('provider_http', `Provider returned HTTP ${response.status}.`, { status: response.status, outcomeUnknown: mutates && response.status >= 500 });
      }
      if (consume) return await consume(response);
      const chunks = []; let length = 0;
      for await (const chunk of response.body ?? []) {
        length += chunk.length;
        if (length > this.maxJSONBytes) { controller.abort(); throw new WorldMirrorError('response_too_large', 'Provider JSON exceeds the bounded response limit.', { outcomeUnknown: mutates }); }
        chunks.push(chunk);
      }
      try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { throw new WorldMirrorError('invalid_json', 'Provider did not return valid JSON.', { outcomeUnknown: mutates }); }
    } catch (error) {
      const timedOut = controller.signal.aborted;
      controller.abort();
      if (error instanceof WorldMirrorError) throw error;
      throw new WorldMirrorError(timedOut ? 'request_timeout' : 'request_failed', timedOut ? 'Provider request timed out.' : 'Provider request failed.', { outcomeUnknown: mutates });
    } finally { clearTimeout(timer); }
  }
  capabilities() { return this.request('/api/3dgs/quick-reconstruct/capabilities'); }
  createGroup(name) { return this.request('/api/project_groups', { method: 'POST', json: { name: safeName(name) } }); }
  async uploadImages(groupId, files, name, { expectedFiles } = {}) {
    providerId(groupId); safeName(name);
    if (!Array.isArray(files) || !files.length || files.length > 64) throw new WorldMirrorError('invalid_images', 'Supply 1–64 explicitly selected input images.');
    const form = new FormData(); form.set('group_id', groupId); form.set('name', name);
    let size = 0;
    for (const [index, file] of files.entries()) {
      const blob = await openAsBlob(file, { type: /\.png$/i.test(file) ? 'image/png' : 'image/jpeg' });
      const info = await imageFile(file); size += info.size;
      if (expectedFiles && (expectedFiles.length !== files.length || ['name', 'size', 'sha256'].some(field => expectedFiles[index]?.[field] !== info[field]))) {
        throw new WorldMirrorError('input_changed', 'Selected frames changed before upload; no upload request was sent.');
      }
      if (size > 256 * 1024 * 1024) throw new WorldMirrorError('images_too_large', 'The total image input limit is 256 MiB.');
      form.append('files', blob, info.name);
    }
    return this.request('/api/3dgs/assets/images', { method: 'POST', body: form });
  }
  /** Upload per-image masks for an uploaded image asset. The Hub requires each mask's stem to
   * equal an image's name; `white_keep` declares white = the part to train on (used by both
   * COLMAP preparation and gsplat training). */
  async uploadMasks(groupId, imagesAssetId, files, name, { expectedFiles } = {}) {
    providerId(groupId); providerId(imagesAssetId); safeName(name);
    if (!Array.isArray(files) || !files.length || files.length > 64 || files.some(file => !/\.png$/i.test(file))) {
      throw new WorldMirrorError('invalid_masks', 'Supply 1–64 PNG masks.');
    }
    const form = new FormData();
    form.set('group_id', groupId); form.set('images_asset_id', imagesAssetId); form.set('polarity', 'white_keep'); form.set('name', name);
    let size = 0;
    for (const [index, file] of files.entries()) {
      const info = await imageFile(file); size += info.size;
      if (expectedFiles && (expectedFiles.length !== files.length || ['name', 'size', 'sha256'].some(field => expectedFiles[index]?.[field] !== info[field]))) {
        throw new WorldMirrorError('input_changed', 'Masks changed before upload; no upload request was sent.');
      }
      if (size > 64 * 1024 * 1024) throw new WorldMirrorError('masks_too_large', 'The total mask input limit is 64 MiB.');
      form.append('files', await openAsBlob(file, { type: 'image/png' }), info.name);
    }
    return this.request('/api/3dgs/assets/masks', { method: 'POST', body: form });
  }
  /** Attach a camera-position prior file to a prepared gs_mcmc project. The bytes are
   * re-hashed immediately before sending so a changed file is never uploaded. */
  async uploadPosePrior(projectId, file, { expectedSha256 } = {}) {
    providerId(projectId);
    const bytes = await readFile(file);
    if (!bytes.length || bytes.length > 1024 * 1024) throw new WorldMirrorError('invalid_pose_prior', 'The pose prior file must be 1 byte to 1 MiB.');
    if (expectedSha256 && createHash('sha256').update(bytes).digest('hex') !== expectedSha256) {
      throw new WorldMirrorError('input_changed', 'The pose prior changed before upload; no upload request was sent.');
    }
    const form = new FormData();
    form.set('file', new Blob([bytes], { type: 'text/csv' }), path.basename(file));
    return this.request(`/api/projects/${providerId(projectId)}/3dgs/pose-prior`, { method: 'POST', body: form });
  }
  quick({ groupId, imagesAssetId, requestId, name }) {
    providerId(groupId); providerId(imagesAssetId); providerId(requestId);
    if (requestId.length < 8) throw new WorldMirrorError('invalid_request_id', 'A persistent request ID of at least 8 characters is required.');
    // The observed OpenAPI forbids an algorithm field here. Query/download always
    // select WorldMirror2 explicitly; capability/response checks guard the route.
    return this.request('/api/3dgs/quick-reconstruct', { method: 'POST', json: { group_id: groupId, images_asset_id: imagesAssetId, request_id: requestId, name: safeName(name) } });
  }
  project(projectId) { return this.request(`/api/projects/${providerId(projectId)}`); }
  inputs(projectId) { return this.request(`/api/projects/${providerId(projectId)}/3dgs/inputs`); }
  result(projectId, stepId) {
    return this.request(`/api/projects/${providerId(projectId)}/3dgs?algorithm=${ALGORITHM}&step_id=${providerId(stepId)}`);
  }
  async downloadPLY(projectId, stepId, destination, { timeoutMs = this.timeoutMs } = {}) {
    providerId(projectId); providerId(stepId);
    const temporary = `${destination}.${randomUUID()}.part`;
    let handle;
    try {
      handle = await open(temporary, 'wx', 0o600);
      const result = await this.request(`/api/projects/${projectId}/3dgs/point_cloud.ply?algorithm=${ALGORITHM}&step_id=${stepId}`, { timeoutMs, consume: async response => {
        const declared = Number(response.headers.get('content-length'));
        if (declared > this.maxPLYBytes) throw new WorldMirrorError('ply_too_large', 'Provider PLY exceeds the existing importer limit.');
        let size = 0; const hash = createHash('sha256');
        for await (const chunk of response.body ?? []) {
          size += chunk.length;
          if (size > this.maxPLYBytes) throw new WorldMirrorError('ply_too_large', 'Provider PLY exceeds the existing importer limit.');
          hash.update(chunk); await handle.writeFile(chunk);
        }
        if (!size) throw new WorldMirrorError('empty_ply', 'Provider returned an empty PLY.');
        await handle.sync();
        return { size, sha256: hash.digest('hex') };
      } });
      await handle.close(); handle = null;
      await rename(temporary, destination);
      return result;
    } finally { await handle?.close(); await rm(temporary, { force: true }); }
  }
}
