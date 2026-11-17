import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { importReconstructionStudy } from '../src/reconstruction-studies.mjs';

const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--config') {
  console.error('Usage: node server/tools/import-reconstruction-study.mjs --config <private-config.json>');
  process.exitCode = 2;
} else {
  try {
    const configFile = path.resolve(args[1]);
    const config = JSON.parse(await readFile(configFile, 'utf8'));
    const result = await importReconstructionStudy({ ...config,
      dataDir: path.resolve(path.dirname(configFile), config.dataDir),
      manifestPath: path.resolve(path.dirname(configFile), config.manifestPath) });
    console.log(JSON.stringify({ id: result.study.id, imported: result.imported, sourceKind: result.study.sourceKind,
      variants: result.study.variants.map(({ role, format, shDegree, pointCount, byteSize, sha256 }) => ({ role, format, shDegree, pointCount, byteSize, sha256 })) }, null, 2));
  } catch (error) {
    console.error(JSON.stringify({ code: error.code ?? 'study_import_failed', message: error.message }));
    process.exitCode = 1;
  }
}
