import { readFile } from 'node:fs/promises';
import { APIError } from './validation.mjs';

export function gpuAdmission({ snapshotPath, minFreeMiB = 20000, maxAgeMs = 15000, roleGPUUUIDs = {}, roleMinFreeMiB = {} } = {}, dependencies = {}) {
  const read = dependencies.read ?? (file => readFile(file, 'utf8'));
  const clock = dependencies.now ?? Date.now;
  if (!snapshotPath || !Number.isFinite(minFreeMiB) || minFreeMiB < 1) throw new Error('Invalid GPU admission configuration');
  return async (requested, queued = []) => {
    if (!requested.length) return;
    let data;
    try { data = JSON.parse(await read(snapshotPath)); } catch { throw busy(); }
    if (!Number.isFinite(data.at) || clock() - data.at > maxAgeMs || data.at > clock() + 1000 || !Array.isArray(data.gpus)) throw busy();
    const ids = new Set();
    const free = data.gpus.filter(gpu => {
      if (typeof gpu.uuid !== 'string' || ids.has(gpu.uuid)) return false;
      ids.add(gpu.uuid);
      return Number.isFinite(gpu.freeMiB) && gpu.freeMiB >= 0;
    });
    // Account for queued work not visible in nvidia-smi and for any temporary executor affinity.
    const choices = [...queued, ...requested].map(role => free.filter(gpu =>
      gpu.freeMiB >= (roleMinFreeMiB[role] ?? minFreeMiB) && (!roleGPUUUIDs[role] || roleGPUUUIDs[role].includes(gpu.uuid))).map(gpu => gpu.uuid))
      .sort((a,b) => a.length-b.length);
    const assigned = new Map();
    const fit = (job, seen) => choices[job].some(uuid => {
      if (seen.has(uuid)) return false;
      seen.add(uuid);
      if (!assigned.has(uuid) || fit(assigned.get(uuid), seen)) { assigned.set(uuid, job); return true; }
      return false;
    });
    if (!choices.every((_, job) => fit(job, new Set()))) throw busy();
  };
}
function busy() { return new APIError(503, 'server_busy', '服务器繁忙中，请稍后重试。'); }
