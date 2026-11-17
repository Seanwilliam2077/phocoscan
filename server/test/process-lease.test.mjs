import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, readdir, rm, lstat, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fork } from 'node:child_process';
import { once } from 'node:events';
import { withProcessLease } from '../src/process-lease.mjs';

const moduleURL = new URL('../src/process-lease.mjs', import.meta.url).href;
async function fixture(t) {
  const directory = await mkdtemp(path.join(tmpdir(), 'pw-process-lease-'));
  const filename = path.join(directory, '.fixture.lock'), children = [];
  // Real child processes exercise OS PID checks and concurrent filesystem
  // recovery. No provider, media or reconstruction calls exist in this fixture.
  const script = path.join(directory, 'child.mjs');
  await writeFile(script, `import fs from 'node:fs';
import {syncBuiltinESMExports} from 'node:module';
const filename=process.argv[2], pauseRecovery=process.argv[3]==='pause';
const wait=type=>new Promise(resolve=>{const handler=m=>{if(m===type){process.off('message',handler);resolve();}};process.on('message',handler);});
if(pauseRecovery){const original=fs.promises.rename;fs.promises.rename=async(a,b)=>{if(a===filename&&b.includes('.stale-')){process.send({type:'recovery-observed'});await wait('recover');}return original(a,b);};syncBuiltinESMExports();}
const {withProcessLease}=await import(${JSON.stringify(moduleURL)});
process.send({type:'started'});await wait('start');
try{await withProcessLease(filename,async()=>{process.send({type:'entered',pid:process.pid});await wait('release');},{busyCode:'fixture_busy'});process.send({type:'done'});}
catch(e){process.send({type:'busy',code:e.code});}
process.disconnect();
`);
  function child(pause = false) {
    const proc = fork(script, [filename, pause ? 'pause' : 'normal'], { stdio: ['ignore', 'ignore', 'pipe', 'ipc'], windowsHide: true });
    children.push(proc); const messages = [];
    proc.on('message', message => messages.push(message));
    const exit = once(proc, 'exit');
    return { proc, exit, send: value => proc.send(value), wait(type) {
      const previous = messages.find(message => message.type === type);
      if (previous) return Promise.resolve(previous);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { proc.off('message', listener); reject(Error('Child did not reach ' + type)); }, 8000);
        const listener = message => { if (message.type === type) { clearTimeout(timer); proc.off('message', listener); resolve(message); } };
        proc.on('message', listener);
      });
    } };
  }
  t.after(async () => {
    await Promise.all(children.map(async proc => {
      if (proc.exitCode === null && proc.signalCode === null) { const exited = once(proc, 'exit'); proc.kill(); await exited; }
    }));
    await rm(directory, { recursive: true, force: true });
  });
  return { directory, filename, child };
}

test('live lease and legacy live lock cannot be stolen; ordinary release leaves no tombstones', async t => {
  const f = await fixture(t), owner = f.child();
  await owner.wait('started'); owner.send('start'); await owner.wait('entered');
  await assert.rejects(withProcessLease(f.filename, () => assert.fail('live owner stolen'), { busyCode: 'fixture_busy' }), { code: 'fixture_busy' });
  owner.send('release'); await owner.wait('done'); await owner.exit;
  assert.equal((await readdir(f.directory)).filter(n => n.includes('.lock')).length, 0);
  const legacy = JSON.stringify({ pid: process.pid, nonce: randomUUID() });
  await writeFile(f.filename, legacy);
  await assert.rejects(withProcessLease(f.filename, () => assert.fail('legacy owner stolen')), { code: 'process_busy' });
  assert.equal(await readFile(f.filename, 'utf8'), legacy);
});

test('two restarters observing the same crashed owner cannot steal the winning replacement lease', async t => {
  const f = await fixture(t), crashed = f.child();
  await crashed.wait('started'); crashed.send('start'); await crashed.wait('entered');
  const staleOwner = JSON.parse(await readFile(path.join(f.filename, 'owner.json'), 'utf8'));
  crashed.proc.kill(); await crashed.exit;
  const winner = f.child(true), delayed = f.child(true);
  await Promise.all([winner.wait('started'), delayed.wait('started')]); winner.send('start'); delayed.send('start');
  // Both have read the same stale nonce before either atomic recovery rename.
  await Promise.all([winner.wait('recovery-observed'), delayed.wait('recovery-observed')]);
  winner.send('recover'); await winner.wait('entered');
  delayed.send('recover'); assert.equal((await delayed.wait('busy')).code, 'fixture_busy'); await delayed.exit;
  const active = JSON.parse(await readFile(path.join(f.filename, 'owner.json'), 'utf8'));
  assert.equal(active.pid, winner.proc.pid); assert.notEqual(active.nonce, staleOwner.nonce);
  const preserved = JSON.parse(await readFile(path.join(`${f.filename}.stale-${staleOwner.nonce}`, 'owner.json'), 'utf8'));
  assert.equal(preserved.nonce, staleOwner.nonce);
  winner.send('release'); await winner.wait('done'); await winner.exit;
  await withProcessLease(f.filename, async () => assert.ok((await lstat(f.filename)).isDirectory()));
});

test('exceptions release owned leases and malformed or dead legacy locks fail closed without waiting', async t => {
  const f = await fixture(t), original = Error('fixture action failed');
  await assert.rejects(withProcessLease(f.filename, () => { throw original; }), error => error === original);
  await assert.rejects(lstat(f.filename), { code: 'ENOENT' });
  const dead = f.child(); await dead.wait('started'); dead.proc.kill(); await dead.exit;
  await writeFile(f.filename, JSON.stringify({ pid: dead.proc.pid, nonce: randomUUID() }));
  await assert.rejects(withProcessLease(f.filename, () => assert.fail('legacy stale file auto-unlinked')), { code: 'process_busy' });
  await rm(f.filename); await mkdir(f.filename);
  await assert.rejects(withProcessLease(f.filename, () => assert.fail('malformed empty lease stolen')), { code: 'process_busy' });
});
