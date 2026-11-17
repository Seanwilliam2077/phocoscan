import { createServer } from './src/server.mjs';
import { loadConfig } from './src/config.mjs';

const config = await loadConfig();
const server = createServer(config);
server.on('error', error => { console.error(`PocketWorld could not start: ${error.code ?? error.message}`); process.exitCode = 1; server.closeDatabase(); });
server.listen(config.port, config.host, () => {
  console.log(`PocketWorld backend ${'0.1.0'} listening on http://${config.host}:${config.port}`);
  console.log(`Data directory: ${config.dataDir}`);
  console.log('API ready. Automatic reconstruction queues require the separately managed dual worker service.');
});
let stopping = false;
function stop() {
  if (stopping) return;
  stopping = true;
  server.close(() => { server.closeDatabase(); process.exit(0); });
  server.closeIdleConnections();
  setTimeout(() => { server.closeAllConnections(); }, 3000).unref();
}
process.on('SIGINT', stop);
process.on('SIGTERM', stop);

export { createServer } from './src/server.mjs';
