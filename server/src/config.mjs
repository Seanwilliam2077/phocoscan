import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import path from 'node:path';

export const serverDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/** Never print this object: it contains the operator's bearer credential. */
export async function loadConfig({ create = true } = {}) {
  const configFile = path.resolve(process.env.POCKETWORLD_CONFIG ?? path.join(serverDirectory, '.local-config.json'));
  let stored;
  try { stored = JSON.parse(await readFile(configFile, 'utf8')); }
  catch (error) {
    if (error.code !== 'ENOENT') throw new Error('Local config cannot be read; inspect it without publishing its admin token.');
    if (!create) throw new Error('Start the backend once to create the local operator configuration.');
    stored = { host: '127.0.0.1', port: 8787, dataDir: path.join(serverDirectory, 'data'), adminToken: randomBytes(32).toString('base64url') };
    await mkdir(path.dirname(configFile), { recursive: true });
    try { await writeFile(configFile, JSON.stringify(stored, null, 2) + '\n', { flag: 'wx', mode: 0o600 }); }
    catch (writeError) {
      if (writeError.code !== 'EEXIST') throw writeError;
      stored = JSON.parse(await readFile(configFile, 'utf8'));
    }
  }
  const port = Number(process.env.PORT ?? stored.port ?? 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be 1–65535.');
  const host = process.env.HOST ?? stored.host ?? '127.0.0.1';
  const adminToken = process.env.ADMIN_TOKEN ?? stored.adminToken;
  if (typeof adminToken !== 'string' || !/^[A-Za-z0-9_-]{32,200}$/.test(adminToken)) throw new Error('ADMIN_TOKEN must be a random URL-safe string with at least 32 characters.');
  const dataDir = path.resolve(serverDirectory, process.env.DATA_DIR ?? stored.dataDir ?? 'data');
  return { host, port, dataDir, adminToken, configFile, gpuAdmission: stored.gpuAdmission, imageGeneration: stored.imageGeneration };
}
