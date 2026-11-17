import { mkdir, lstat, open, readFile, rename, rm, rmdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
function busy(code, message) { const error = new Error(message); error.code = code; return error; }
async function ownerAt(filename, busyCode) {
  const info = await lstat(filename);
  if (info.isSymbolicLink() || (!info.isDirectory() && !info.isFile())) throw busy(busyCode, 'Lock needs operator inspection.');
  const legacy = info.isFile(), ownerFile = legacy ? filename : path.join(filename, 'owner.json');
  let ownerInfo;
  try { ownerInfo = await lstat(ownerFile); }
  catch (error) { if (error.code === 'ENOENT') throw busy(busyCode, 'An initializing or incomplete lock requires operator inspection.'); throw error; }
  if (!ownerInfo.isFile() || ownerInfo.isSymbolicLink() || ownerInfo.size > 8192) throw busy(busyCode, 'Lock owner needs operator inspection.');
  let owner;
  try { owner = JSON.parse(await readFile(ownerFile, 'utf8')); }
  catch { throw busy(busyCode, 'Lock owner needs operator inspection.'); }
  if (!Number.isInteger(owner.pid) || owner.pid <= 0 || !UUID.test(owner.nonce ?? '')) throw busy(busyCode, 'Lock owner needs operator inspection.');
  return { ...owner, legacy };
}
function ownerIsDead(owner, busyCode) {
  try { process.kill(owner.pid, 0); }
  catch (error) {
    if (error.code === 'ESRCH') return true;
    throw busy(busyCode, 'Another process may own this lock.');
  }
  return false;
}
async function removeOwnedDirectory(directory) {
  // Never recursively remove a computed path. Each private lease contains only
  // this one known owner file; unexpected entries make cleanup fail closed.
  await rm(path.join(directory, 'owner.json'), { force: true });
  await rmdir(directory);
}

/** Cross-process lease for a local filesystem. No timeout steals a live PID.
 * A stale directory is moved atomically to a permanent, non-empty tombstone
 * named by its nonce. Racing recoverers target that same tombstone, so a late
 * rename cannot remove a replacement lease. Keep stale tombstones: deleting
 * them while old contenders exist would reintroduce the ABA recovery race.
 * Legacy JSON-file locks are respected but never automatically unlinked.
 */
export async function withProcessLease(filename, action, { busyCode = 'process_busy' } = {}) {
  filename = path.resolve(filename);
  await mkdir(path.dirname(filename), { recursive: true });
  const nonce = randomUUID(), candidate = `${filename}.candidate-${nonce}`;
  await mkdir(candidate, { mode: 0o700 });
  let candidateExists = true, acquired = false, reserved = false;
  try {
    const handle = await open(path.join(candidate, 'owner.json'), 'wx', 0o600);
    try { await handle.writeFile(JSON.stringify({ version: 2, pid: process.pid, nonce })); await handle.sync(); }
    finally { await handle.close(); }
    for (let attempt = 0; attempt < 4; attempt++) {
      try { await mkdir(filename, { mode: 0o700 }); reserved = true; }
      catch (error) {
        if (error.code !== 'EEXIST') throw error;
      }
      if (reserved) {
        // mkdir cannot replace either a legacy file or a live directory. If a
        // process dies before installing its owner record, the incomplete lock
        // stays fail-closed rather than guessing whether an owner is alive.
        await rename(path.join(candidate, 'owner.json'), path.join(filename, 'owner.json'));
        acquired = true;
        await rmdir(candidate); candidateExists = false;
        break;
      }
      let owner;
      try { owner = await ownerAt(filename, busyCode); }
      catch (error) { if (error.code === 'ENOENT') continue; throw error; }
      if (!ownerIsDead(owner, busyCode)) throw busy(busyCode, 'Another live process owns this lock.');
      if (owner.legacy) throw busy(busyCode, 'A dead legacy file lock requires operator inspection before removal.');
      const tombstone = `${filename}.stale-${owner.nonce}`;
      try { await rename(filename, tombstone); }
      catch (error) {
        // Another contender either moved this exact old owner or installed a
        // replacement. Never unlink the active pathname after losing this race.
        if (!['ENOENT', 'EEXIST', 'ENOTEMPTY', 'EPERM', 'EACCES'].includes(error.code)) throw error;
      }
    }
    if (!acquired) throw busy(busyCode, 'Lock changed during bounded recovery; retry later.');
    return await action();
  } finally {
    if (acquired) {
      const owner = await ownerAt(filename, busyCode);
      if (owner.legacy || owner.nonce !== nonce || owner.pid !== process.pid) throw busy(busyCode, 'Lease ownership changed; no active lock was removed.');
      const released = `${filename}.released-${nonce}`;
      await rename(filename, released);
      await removeOwnedDirectory(released);
    }
    else if (reserved) await rmdir(filename); // Only our still-empty reservation.
    if (candidateExists) await removeOwnedDirectory(candidate);
  }
}
