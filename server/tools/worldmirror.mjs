#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WorldMirrorClient, WorldMirrorError } from '../src/worldmirror-client.mjs';
import { checkCapabilities, uploadRun, quickRun, resumeRun, readRun, runSummary } from '../src/worldmirror-run.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const help = `WorldMirror2 operator adapter (Node 24+)

Set WORLDMIRROR_URL to the configured HTTP(S) origin.
Optional WORLDMIRROR_TOKEN stays in the environment, never in arguments/manifest.
WORLDMIRROR_SUCCESS_STATUS is unset by default (no output can be accepted).
Set it only after independently confirming this deployment's terminal-success enum.

node server/tools/worldmirror.mjs doctor
node server/tools/worldmirror.mjs upload --files <selected-images-directory> --run-dir work/<new-run> --name <name> [--group-id <explicit-existing-group>]
node server/tools/worldmirror.mjs quick --run-dir work/<run>
node server/tools/worldmirror.mjs resume --run-dir work/<run> [--max-wait <seconds,0..300>] [--poll <seconds,1..60>]
node server/tools/worldmirror.mjs inspect --run-dir work/<run>

upload creates a dedicated group unless an existing group is explicitly supplied.
quick submits once. resume only polls the saved project/step and downloads real PLY.
Ambiguous writes stop for reconciliation; commands never cancel/delete provider work.
Outputs and manifests stay under this project's ignored work/ directory.
This command does not import into PocketWorld, alter receipts or assert data quality.
`;
function parse(argv) {
  const [command, ...rest] = argv, args = {};
  for (let i = 0; i < rest.length; i += 2) {
    if (!/^--[a-z-]+$/.test(rest[i]) || !rest[i + 1] || rest[i + 1].startsWith('--') || Object.hasOwn(args, rest[i])) throw new WorldMirrorError('arguments', 'Pass each named option once with its value.');
    args[rest[i]] = rest[i + 1];
  }
  const allowed = { doctor: [], upload: ['--files', '--run-dir', '--name', '--group-id'], quick: ['--run-dir'], resume: ['--run-dir', '--max-wait', '--poll'], inspect: ['--run-dir'] };
  if (!allowed[command] || Object.keys(args).some(key => !allowed[command].includes(key))) throw new WorldMirrorError('arguments', 'Unknown command or option. Use --help for usage.');
  return { command, args };
}
function directory(value) {
  if (!value) throw new WorldMirrorError('arguments', '--run-dir is required.');
  const resolved = path.resolve(root, value), work = path.join(root, 'work'), relative = path.relative(work, resolved);
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) throw new WorldMirrorError('unsafe_directory', 'Use a dedicated run directory inside this project’s ignored work/ folder.');
  return resolved;
}
try {
  if (process.argv.length <= 2 || process.argv[2] === '--help') { process.stdout.write(help); }
  else {
    const { command, args } = parse(process.argv.slice(2));
    const runDirectory = command === 'doctor' ? undefined : directory(args['--run-dir']);
    if (command === 'inspect') process.stdout.write(JSON.stringify(runSummary(await readRun(runDirectory)), null, 2) + '\n');
    else {
      const client = new WorldMirrorClient({ origin: process.env.WORLDMIRROR_URL, token: process.env.WORLDMIRROR_TOKEN || '', successStatus: process.env.WORLDMIRROR_SUCCESS_STATUS || null });
      let result;
      if (command === 'doctor') result = checkCapabilities(await client.capabilities());
      if (command === 'upload') {
        if (!args['--files'] || !args['--name']) throw new WorldMirrorError('arguments', 'upload requires --files and --name.');
        result = runSummary(await uploadRun({ directory: runDirectory, filesDirectory: path.resolve(args['--files']), name: args['--name'], groupId: args['--group-id'], client }));
      }
      if (command === 'quick') result = runSummary(await quickRun({ directory: runDirectory, client }));
      if (command === 'resume') {
        const maxWait = Number(args['--max-wait'] ?? 0), poll = Number(args['--poll'] ?? 2);
        if (!Number.isFinite(poll) || poll < 1 || poll > 60) throw new WorldMirrorError('invalid_poll', '--poll must be 1–60 seconds.');
        result = runSummary(await resumeRun({ directory: runDirectory, client, maxWaitMs: maxWait * 1000, pollMs: poll * 1000 }));
      }
      process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    }
  }
} catch (error) {
  // Node/network error messages can contain private URLs or paths. Only our
  // explicitly sanitized messages are suitable for normal operator output.
  const safe = error instanceof WorldMirrorError;
  process.stderr.write(JSON.stringify({ error: { code: safe ? error.code : 'local_failure', message: safe ? error.message : 'Local operation failed; input and manifest were retained for inspection.', ...(error.status ? { status: error.status } : {}), ...(error.outcomeUnknown ? { outcomeUnknown: true } : {}) } }) + '\n');
  process.exitCode = 1;
}
