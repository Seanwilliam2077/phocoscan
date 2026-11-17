import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { runDualWorkerOnce } from '../src/dual-reconstruction-worker.mjs';

const args = process.argv.slice(2);
const configIndex = args.indexOf('--config');
const watch = args.includes('--watch'), once = args.includes('--once');
if (configIndex < 0 || !args[configIndex + 1] || watch === once || args.length !== 3) {
  console.error('Usage: node server/tools/dual-reconstruction-worker.mjs --config <private.json> --once|--watch');
  process.exitCode = 2;
} else {
  const file = path.resolve(args[configIndex + 1]);
  try {
    const parsed = JSON.parse(await readFile(file, 'utf8'));
    const config = { ...parsed, dataDir: path.resolve(path.dirname(file), parsed.dataDir), workDir: path.resolve(path.dirname(file), parsed.workDir) };
    let stopping = false;
    process.on('SIGINT', () => { stopping = true; });
    process.on('SIGTERM', () => { stopping = true; });
    do {
      console.log(JSON.stringify(await runDualWorkerOnce(config)));
      if (!watch || stopping) break;
      await new Promise(resolve => setTimeout(resolve, 5000));
    } while (!stopping);
  } catch (error) {
    console.error(JSON.stringify({ code: error.code ?? 'worker_failed', message: 'Dual reconstruction worker stopped; inspect configuration and private job journals.' }));
    process.exitCode = 1;
  }
}
