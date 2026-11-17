// Startup ordering: Type=simple means the API process may not have opened its
// database yet. Wait for its actual health response before the worker opens it.
import { readFile } from 'node:fs/promises';
const { host, port } = JSON.parse(await readFile('/etc/pocketworld/api.json', 'utf8'));
const url = `http://${host === '0.0.0.0' ? '127.0.0.1' : host}:${port}/health`;
let healthy = false;
for (let attempt = 0; attempt < 30; attempt++) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(2000), redirect: 'error' });
    if (response.ok && (await response.json()).ok === true) { healthy = true; break; }
  } catch {}
  await new Promise(resolve => setTimeout(resolve, 500));
}
if (!healthy) { console.error('PocketWorld API is not ready; worker startup deferred.'); process.exitCode = 1; }
