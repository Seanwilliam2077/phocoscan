import { spawn } from 'node:child_process';
import { open, mkdir, readFile, writeFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createConnection } from 'node:net';

// A bounded startup check, not a background heartbeat or an idle-timeout bypass.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const serverFile = path.join(root, 'server', 'index.mjs');
const port = Number(process.env.TEST_PORT ?? process.env.PORT ?? 8787);
const dataDir = path.resolve(process.env.DATA_DIR ?? path.join(root, 'server', 'data'));
const configFile = path.resolve(process.env.POCKETWORLD_CONFIG ?? path.join(root, 'server', '.local-config.json'));
const runtimeDir = path.resolve(process.env.POCKETWORLD_RUNTIME_DIR ?? path.join(root, 'runtime'));
const healthURL = `http://127.0.0.1:${port}/health`;
const recordFile = path.join(runtimeDir, `codespace-backend-${port}.json`);
const lockFile = path.join(runtimeDir, `codespace-backend-${port}.lock`);
const stdoutFile = path.join(runtimeDir, `codespace-backend-${port}.stdout.log`);
const stderrFile = path.join(runtimeDir, `codespace-backend-${port}.stderr.log`);
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch { return false; }
}
async function readJSON(filename) {
  try { return JSON.parse(await readFile(filename, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw new Error(`Cannot read runtime record: ${path.basename(filename)}.`); }
}
async function occupied() {
  return new Promise(resolve => {
    const socket = createConnection({ host: '127.0.0.1', port });
    let finished = false;
    function finish(result) { if (finished) return; finished = true; socket.destroy(); resolve(result); }
    socket.setTimeout(1200);
    socket.once('connect', () => finish(true));
    socket.once('error', error => finish(error.code !== 'ECONNREFUSED'));
    socket.once('timeout', () => finish(true));
  });
}
async function healthy() {
  try {
    const response = await fetch(healthURL, { signal: AbortSignal.timeout(1500), redirect: 'error' });
    if (!response.ok) return false;
    const body = await response.json();
    return body?.ok === true && body.version === '0.1.0';
  } catch { return false; }
}
async function managed(record) {
  if (!record || record.root !== root || record.serverFile !== serverFile || record.port !== port || record.dataDir !== dataDir || record.configFile !== configFile || !alive(record.pid)) return false;
  if (process.platform === 'linux') {
    // Codespaces is Linux: confirm PID reuse cannot accidentally claim another service.
    try {
      const args = (await readFile(`/proc/${record.pid}/cmdline`, 'utf8')).split('\0');
      if (!args.includes(serverFile)) return false;
    } catch { return false; }
  }
  // Outside Linux this is a local smoke-test fallback: managed PID record + health.
  return true;
}
function printAddress() {
  console.log(`Local health check passed: ${healthURL}`);
  const name = process.env.CODESPACE_NAME;
  const domain = process.env.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN;
  if (name && domain && /^[a-z0-9][a-z0-9-]*$/i.test(name) && /^(?:[a-z0-9-]+\.)+[a-z0-9-]+$/i.test(domain)) {
    console.log(`Forwarded HTTPS candidate: https://${name}-${port}.${domain}`);
    console.log(`Verify the address in Codespaces Ports > ${port}. Port visibility has NOT been changed.`);
  } else {
    console.log('No Codespaces forwarding environment detected; no public address was created or verified.');
  }
  console.log(`Logs: ${stdoutFile} and ${stderrFile}`);
}
async function lock() {
  for (let attempt = 0; attempt < 50; attempt++) {
    try {
      const handle = await open(lockFile, 'wx', 0o600);
      await handle.writeFile(JSON.stringify({ pid: process.pid }));
      await handle.close();
      return;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const owner = await readJSON(lockFile);
      if (owner && !alive(owner.pid)) {
        try { await unlink(lockFile); } catch (removeError) { if (removeError.code !== 'ENOENT') throw removeError; }
      } else await delay(200);
    }
  }
  throw new Error('Another startup is still in progress; retry after it finishes.');
}

async function start() {
  if (Number(process.versions.node.split('.')[0]) < 24) throw new Error('Node.js 24 or newer is required. Rebuild the Codespaces dev container.');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT / TEST_PORT must be an integer from 1 to 65535.');
  await mkdir(runtimeDir, { recursive: true });
  await lock();
  try {
    if (await occupied()) {
      const record = await readJSON(recordFile);
      if (!(await managed(record)) || !(await healthy())) throw new Error(`Port ${port} is occupied by an unverified or unhealthy process. Nothing was stopped or replaced.`);
      console.log('This workspace backend is already running.');
      printAddress();
      return;
    }
    // Require the repository's locked dependency install before launching.
    await readFile(path.join(root, 'server', 'node_modules', 'busboy', 'package.json'), 'utf8');
    const stdout = await open(stdoutFile, 'a', 0o600);
    const stderr = await open(stderrFile, 'a', 0o600);
    let child;
    try {
      child = spawn(process.execPath, [serverFile], {
        cwd: root, detached: true, windowsHide: true,
        stdio: ['ignore', stdout.fd, stderr.fd],
        env: { ...process.env, HOST: '0.0.0.0', PORT: String(port), DATA_DIR: dataDir, POCKETWORLD_CONFIG: configFile }
      });
      await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
    } finally { await Promise.all([stdout.close(), stderr.close()]); }
    const record = { pid: child.pid, root, serverFile, port, dataDir, configFile, startedAt: new Date().toISOString() };
    try {
      await writeFile(recordFile, JSON.stringify(record, null, 2) + '\n', { mode: 0o600 });
      let ready = false;
      for (let attempt = 0; attempt < 40; attempt++) {
        if (child.exitCode !== null || !alive(child.pid)) break;
        if (await healthy()) { ready = true; break; }
        await delay(150);
      }
      if (!ready) throw new Error(`Backend did not pass its health check. Inspect ${stderrFile}.`);
      child.unref();
      console.log('Shijing development backend started.');
      printAddress();
    } catch (error) {
      // Only the process spawned by this invocation can be terminated here.
      try { child.kill('SIGTERM'); } catch {}
      throw error;
    }
  } finally { try { await unlink(lockFile); } catch (error) { if (error.code !== 'ENOENT') throw error; } }
}

start().catch(error => {
  // Error objects/configuration/environment may contain credentials. Emit only known messages.
  const safe = error?.code === 'ENOENT'
    ? 'Required server files or dependencies are missing. Run npm ci --prefix server, then retry.'
    : typeof error?.message === 'string' ? error.message : 'Codespaces startup failed.';
  console.error(safe);
  process.exitCode = 1;
});
