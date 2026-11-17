#!/usr/bin/env node
import { readFile, mkdir, writeFile, stat, rename, rm } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { Readable, Transform } from 'node:stream';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { loadConfig } from './src/config.mjs';

const help = `PocketWorld manual operator CLI (run against the local backend)

  node server/admin.mjs jobs
  node server/admin.mjs export <sessionId> <new-folder>
  node server/admin.mjs start <jobId>
  node server/admin.mjs fail <jobId> <reason>
  node server/admin.mjs retry <jobId>
  node server/admin.mjs cancel <jobId>
  node server/admin.mjs import <jobId> <model.ply|model.splat> --tool <actual-tool> [--version <version>]
  node server/admin.mjs review <assetId> --quality accepted|rejected|needs_review --lineage declared|verified --dual-use not_evaluated|partial|rejected --notes <evidence>
  node server/admin.mjs events <new-jsonl-file>
  node server/admin.mjs metrics

Optional POCKETWORLD_URL changes the backend URL. Local credentials are read from
server/.local-config.json (or POCKETWORLD_CONFIG); no token is printed.
Export requires a NEW directory, preserves original bytes, verifies file hashes.
Use exports only within the research team. No camera poses are synthesized.
`;

const [command, ...args] = process.argv.slice(2);
if (!command || ['help', '--help', '-h'].includes(command)) { console.log(help); process.exit(0); }

try {
  const config = await loadConfig({ create: false });
  const base = new URL(process.env.POCKETWORLD_URL ?? `http://${['0.0.0.0', '::'].includes(config.host) ? '127.0.0.1' : config.host}:${config.port}`);
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password) throw new Error('POCKETWORLD_URL must be a plain HTTP(S) backend origin.');
  const flags = {};
  const positional = [];
  for (let index = 0; index < args.length; index++) {
    if (args[index].startsWith('--')) {
      if (!args[index + 1] || args[index + 1].startsWith('--')) throw new Error(`Missing value for ${args[index]}.`);
      flags[args[index].slice(2)] = args[++index];
    } else positional.push(args[index]);
  }
  async function request(endpoint, { method = 'GET', body, file } = {}) {
    const url = new URL(endpoint, base);
    if (url.origin !== base.origin) throw new Error('Refusing to send credentials to another origin.');
    const headers = { Authorization: `Bearer ${config.adminToken}` };
    const options = { method, headers, redirect: 'error' };
    if (file) {
      headers['Content-Type'] = 'application/octet-stream';
      headers['Content-Length'] = String((await stat(file)).size);
      options.body = createReadStream(file); options.duplex = 'half';
    } else if (body) {
      headers['Content-Type'] = 'application/json'; options.body = JSON.stringify(body);
    }
    const response = await fetch(url, options);
    if (!response.ok) {
      const problem = await response.json().catch(() => ({}));
      throw new Error(`${response.status}: ${problem.error?.message ?? 'Request failed.'}`);
    }
    return response;
  }
  const getJSON = async (endpoint, options) => (await request(endpoint, options)).json();
  const encoded = value => encodeURIComponent(value ?? '');

  if (command === 'jobs') {
    const result = await getJSON('/v1/admin/jobs');
    if (!result.jobs.length) console.log('No submitted jobs yet. Capture/submit or import an external asset from the app.');
    for (const item of result.jobs) console.log(JSON.stringify({ jobId: item.job.id, sessionId: item.session.id, environment: item.session.environment, quest: item.session.questId, mode: item.session.captureMode, status: item.job.status, assetId: item.asset?.id ?? null, quality: item.asset?.qualityStatus ?? null }));
  } else if (['start', 'fail', 'retry', 'cancel'].includes(command)) {
    if (!positional[0]) throw new Error('Job ID is required.');
    const status = { start: 'processing', fail: 'failed', retry: 'queued', cancel: 'cancelled' }[command];
    const result = await getJSON(`/v1/admin/jobs/${encoded(positional[0])}/status`, { method: 'PUT', body: { status, ...(command === 'fail' ? { errorMessage: positional.slice(1).join(' ') } : {}) } });
    console.log(JSON.stringify({ jobId: result.job.id, status: result.job.status }));
  } else if (command === 'import') {
    const [jobId, modelFile] = positional;
    if (!jobId || !modelFile || !flags.tool) throw new Error('Provide job ID, model file, and --tool with the actual software name.');
    const format = path.extname(modelFile).slice(1).toLowerCase();
    if (!['ply', 'splat'].includes(format)) throw new Error('Only Gaussian .ply or .splat are supported. Export PLY from Scaniverse; SPZ is not supported in this MVP.');
    const query = new URLSearchParams({ format, tool: flags.tool });
    if (flags.version) query.set('version', flags.version);
    const result = await getJSON(`/v1/admin/jobs/${encoded(jobId)}/asset?${query}`, { method: 'PUT', file: path.resolve(modelFile) });
    console.log(JSON.stringify({ status: result.job.status, assetId: result.asset.id, sha256: result.asset.sha256, lineage: result.asset.lineageStatus, quality: result.asset.qualityStatus }));
  } else if (command === 'review') {
    if (!positional[0]) throw new Error('Asset ID is required.');
    const result = await getJSON(`/v1/admin/assets/${encoded(positional[0])}/review`, { method: 'PATCH', body: { qualityStatus: flags.quality, lineageStatus: flags.lineage, dualUseStatus: flags['dual-use'], notes: flags.notes } });
    console.log(JSON.stringify({ assetId: result.asset.id, quality: result.asset.qualityStatus, lineage: result.asset.lineageStatus, dualUse: result.asset.dualUseStatus }));
  } else if (command === 'export') {
    const [sessionId, destination] = positional;
    if (!sessionId || !destination) throw new Error('Provide session ID and a new output folder.');
    const bundle = await getJSON(`/v1/admin/sessions/${encoded(sessionId)}/bundle`);
    const directory = path.resolve(destination);
    await mkdir(directory, { recursive: false });
    await writeFile(path.join(directory, 'manifest.json'), JSON.stringify(bundle.manifest, null, 2) + '\n', { flag: 'wx' });
    await writeFile(path.join(directory, 'processing.json'), JSON.stringify(bundle.processing, null, 2) + '\n', { flag: 'wx' });
    await writeFile(path.join(directory, 'events.jsonl'), bundle.events.map(item => JSON.stringify(item)).join('\n') + (bundle.events.length ? '\n' : ''), { flag: 'wx' });
    if (bundle.quality) {
      await mkdir(path.join(directory, 'result'), { recursive: true });
      await writeFile(path.join(directory, 'result', 'quality.json'), JSON.stringify(bundle.quality, null, 2) + '\n', { flag: 'wx' });
    }
    for (const file of bundle.files) {
      const target = path.resolve(directory, file.path);
      if (!target.startsWith(directory + path.sep)) throw new Error('Invalid file path in the bundle.');
      const temporary = `${target}.${randomUUID()}.part`;
      await mkdir(path.dirname(target), { recursive: true });
      const response = await request(file.url);
      const hash = createHash('sha256');
      const hashing = new Transform({ transform(chunk, encoding, callback) { hash.update(chunk); callback(null, chunk); } });
      try {
        await pipeline(Readable.fromWeb(response.body), hashing, createWriteStream(temporary, { flags: 'wx' }));
        if (file.sha256 && hash.digest('hex') !== file.sha256) throw new Error(`Hash mismatch for ${file.path}.`);
        await rename(temporary, target);
      } finally { await rm(temporary, { force: true }); }
    }
    console.log(`Exported ${bundle.files.length} original file(s) and manifests to ${directory}`);
  } else if (command === 'events') {
    if (!positional[0]) throw new Error('Provide a new .jsonl output file.');
    const result = await getJSON('/v1/admin/events');
    const target = path.resolve(positional[0]);
    await writeFile(target, result.events.map(event => JSON.stringify(event)).join('\n') + (result.events.length ? '\n' : ''), { flag: 'wx' });
    console.log(`Exported ${result.events.length} events to ${target}`);
  } else if (command === 'metrics') console.log(JSON.stringify(await getJSON('/v1/admin/metrics'), null, 2));
  else throw new Error(`Unknown command ${command}. Run with --help.`);
} catch (error) {
  console.error(`Operator command failed: ${error.message}`);
  process.exitCode = 1;
}
