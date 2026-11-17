import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, mkdir, readFile, readdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { WorldMirrorClient, ALGORITHM } from '../src/worldmirror-client.mjs';
import { uploadRun, quickRun, resumeRun, readRun, runSummary, checkCapabilities } from '../src/worldmirror-run.mjs';

// Mock provider responses only. These fixtures are not capture/reconstruction evidence.
const capabilities = { engine: 'worldmirror2', type: ALGORITHM, available: true, defaults: { max_frames: 16, target_size: 518 }, limits: { max_frames: [2, 32] }, coordinates: 'algorithm', scale: 'unknown' };
const properties = ['x', 'y', 'z', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3'];
const ply = Buffer.from(`ply\nformat ascii 1.0\ncomment SYNTHETIC MOCK - NOT A REAL RECONSTRUCTION\nelement vertex 1\n${properties.map(name => `property float ${name}`).join('\n')}\nend_header\n0 0 1 0.3 0.2 0.1 2 -3 -3 -3 1 0 0 0\n`);
function result(ready = false) {
  const step = { id: 'step_owned', project_id: 'project_owned', type: ALGORITHM, status: ready ? 'SUCCESS' : 'RUNNING', params: { input_revision: 1 } };
  return { algorithm: ALGORITHM, project: { id: 'project_owned', group_id: 'group_owned' }, step, result_step: ready ? step : null, artifacts: { ply: ready ? { path: '/internal/private/provider/path', url: 'https://attacker.invalid/steal-token' } : null } };
}
function inputs() { return { source_kind: 'images', images: { id: 'images_owned', kind: 'images', group_id: 'group_owned', image_count: 2 }, revision: 1, prepared_revision: 1, ready: true, needs_prepare: false, legacy: false }; }
async function harness(t, options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), 'worldmirror-test-')), filesDirectory = path.join(directory, 'frames'), runDirectory = path.join(directory, 'run');
  await mkdir(filesDirectory);
  await writeFile(path.join(filesDirectory, '001.jpg'), Buffer.from('SYNTHETIC IMAGE TRANSPORT FIXTURE 1'));
  await writeFile(path.join(filesDirectory, '002.jpg'), Buffer.from('SYNTHETIC IMAGE TRANSPORT FIXTURE 2'));
  const calls = [], state = { ready: false };
  const server = http.createServer(async (request, response) => {
    const chunks = []; for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString('utf8'), url = new URL(request.url, 'http://test');
    calls.push({ method: request.method, url: request.url, body, authorization: request.headers.authorization });
    if (options.handle && await options.handle({ request, response, url, body, state, calls }) === true) return;
    let output;
    if (url.pathname.endsWith('/capabilities')) output = capabilities;
    else if (url.pathname === '/api/project_groups') output = { id: 'group_owned', name: JSON.parse(body).name };
    else if (url.pathname === '/api/3dgs/assets/images') output = { id: 'images_owned', group_id: 'group_owned', kind: 'images', image_count: 2 };
    else if (url.pathname === '/api/3dgs/quick-reconstruct') output = { project_id: 'project_owned', step_id: 'step_owned', status: 'PENDING' };
    else if (url.pathname.endsWith('/3dgs/inputs')) output = inputs();
    else if (url.pathname.endsWith('/3dgs/point_cloud.ply')) { response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': ply.length }); response.end(ply); return; }
    else if (url.pathname.endsWith('/3dgs')) output = result(state.ready);
    else { response.writeHead(404); response.end(); return; }
    response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(output));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  // SUCCESS is the explicit MOCK contract, not an observed live provider enum.
  const makeClient = extra => new WorldMirrorClient({ origin, token: 'SYNTHETIC_TEST_TOKEN', successStatus: 'SUCCESS', timeoutMs: 1000, ...extra });
  const input = { directory: runDirectory, filesDirectory, name: 'Synthetic interface fixture, not a real scan', client: makeClient() };
  t.after(async () => { await new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }); await rm(directory, { recursive: true, force: true }); });
  return { directory, filesDirectory, runDirectory, calls, state, makeClient, input };
}
const callsTo = (h, endpoint) => h.calls.filter(call => call.url.split('?')[0] === endpoint);

test('client rejects credential-bearing origins and unsafe IDs before any network', () => {
  for (const origin of ['file:///secret', 'https://user:password@test.invalid', 'https://test.invalid/path', 'https://test.invalid/?token=secret']) assert.throws(() => new WorldMirrorClient({ origin }), { code: 'invalid_origin' });
  const client = new WorldMirrorClient({ origin: 'http://127.0.0.1:1' });
  assert.throws(() => client.result('../secret', 'step'), { code: 'invalid_id' });
  assert.throws(() => checkCapabilities({ ...capabilities, available: false }), { code: 'provider_unavailable' });
  assert.throws(() => checkCapabilities({ ...capabilities, type: 'gs_mcmc' }), { code: 'provider_unavailable' });
});

test('confirmed images/quick are durable and idempotent; resume downloads only bound WorldMirror2 PLY', async t => {
  const h = await harness(t);
  let state = await uploadRun(h.input);
  assert.equal(state.phase, 'images_uploaded'); assert.equal(state.input.files.length, 2);
  await uploadRun(h.input);
  assert.equal(callsTo(h, '/api/project_groups').length, 1); assert.equal(callsTo(h, '/api/3dgs/assets/images').length, 1);
  const upload = callsTo(h, '/api/3dgs/assets/images')[0];
  assert.match(upload.body, /name="files"; filename="001.jpg"/); assert.match(upload.body, /name="group_id"\r\n\r\ngroup_owned/);
  state = await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  const quick = callsTo(h, '/api/3dgs/quick-reconstruct'); assert.equal(quick.length, 1);
  assert.deepEqual(JSON.parse(quick[0].body), { group_id: 'group_owned', images_asset_id: 'images_owned', request_id: state.requestId, name: h.input.name });
  state = await resumeRun({ directory: h.runDirectory, client: h.makeClient() }); assert.equal(state.phase, 'submitted');
  assert.equal(state.lastStatus, 'RUNNING'); assert.equal(callsTo(h, '/api/3dgs/quick-reconstruct').length, 1);
  h.state.ready = true;
  state = await resumeRun({ directory: h.runDirectory, client: h.makeClient() });
  assert.equal(state.phase, 'downloaded'); assert.equal(state.output.gaussianCount, 1); assert.equal(state.output.qualityStatus, 'needs_review');
  assert.deepEqual(await readFile(path.join(h.runDirectory, state.output.file)), ply);
  const reads = h.calls.filter(call => call.url.includes('/projects/') && !call.url.endsWith('/inputs'));
  for (const call of reads) { const url = new URL(call.url, 'http://test'); assert.equal(url.searchParams.get('algorithm'), ALGORITHM); assert.equal(url.searchParams.get('step_id'), 'step_owned'); }
  const before = h.calls.length; await resumeRun({ directory: h.runDirectory, client: h.makeClient() }); assert.equal(h.calls.length, before);
  const saved = await readFile(path.join(h.runDirectory, 'manifest.json'), 'utf8');
  assert.doesNotMatch(saved, /SYNTHETIC_TEST_TOKEN|attacker|internal\/private/);
  assert.doesNotMatch(JSON.stringify(runSummary(state)), /frames|SYNTHETIC_TEST_TOKEN|internal\/private/);
  assert.deepEqual(state.responseIds.quick, { project_id: 'project_owned', step_id: 'step_owned' });
});

test('existing explicitly supplied group never creates another group', async t => {
  const h = await harness(t);
  const state = await uploadRun({ ...h.input, groupId: 'group_owned' });
  assert.equal(state.groupOwnership, 'caller_supplied'); assert.equal(callsTo(h, '/api/project_groups').length, 0);
});

for (const [name, endpoint, phase] of [['group', '/api/project_groups', 'group_unknown'], ['images', '/api/3dgs/assets/images', 'images_unknown']]) {
  test(`${name} timeout leaves unresolved write intent and a repeated command sends no mutation`, async t => {
    const h = await harness(t, { handle: ({ url }) => url.pathname === endpoint });
    await assert.rejects(uploadRun({ ...h.input, client: h.makeClient({ timeoutMs: 80 }) }), { code: 'request_timeout', outcomeUnknown: true });
    assert.equal((await readRun(h.runDirectory)).phase, phase);
    await assert.rejects(uploadRun(h.input), { code: 'mutation_unresolved' });
    assert.equal(callsTo(h, endpoint).length, 1); assert.equal(callsTo(h, '/api/project_groups').length, 1);
  });
}

test('lost quick response retains request_id and does not resubmit on quick/resume', async t => {
  const h = await harness(t, { handle: ({ url }) => url.pathname === '/api/3dgs/quick-reconstruct' });
  const original = await uploadRun(h.input);
  await assert.rejects(quickRun({ directory: h.runDirectory, client: h.makeClient({ timeoutMs: 80 }) }), { code: 'request_timeout' });
  const saved = await readRun(h.runDirectory); assert.equal(saved.phase, 'quick_unknown'); assert.equal(saved.requestId, original.requestId);
  await assert.rejects(quickRun({ directory: h.runDirectory, client: h.makeClient() }), { code: 'mutation_unresolved' });
  await assert.rejects(resumeRun({ directory: h.runDirectory, client: h.makeClient() }), { code: 'mutation_unresolved' });
  assert.equal(callsTo(h, '/api/3dgs/quick-reconstruct').length, 1);
});

test('crash after saving mutation intent does not create a replacement group', async t => {
  const h = await harness(t), state = await uploadRun(h.input);
  state.phase = 'images_pending'; await writeFile(path.join(h.runDirectory, 'manifest.json'), JSON.stringify(state));
  const count = h.calls.length;
  await assert.rejects(uploadRun(h.input), { code: 'mutation_unresolved' }); assert.equal(h.calls.length, count);
});

for (const [name, change, code] of [
  ['project', body => { body.project.id = 'another_project'; }, 'result_mismatch'],
  ['step', body => { body.step.id = 'another_step'; }, 'step_mismatch'],
  ['algorithm', body => { body.algorithm = 'gs_mcmc'; }, 'result_mismatch'],
  ['result step', body => { body.result_step = { ...body.step, id: 'old_step' }; }, 'result_step_mismatch'],
]) test(`mismatched ${name} cannot download an unrelated result`, async t => {
  const h = await harness(t, { handle: ({ url, response }) => {
    if (!url.pathname.endsWith('/3dgs')) return false;
    const body = result(true); change(body); response.end(JSON.stringify(body)); return true;
  } });
  await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  await assert.rejects(resumeRun({ directory: h.runDirectory, client: h.makeClient() }), { code });
  assert.equal(callsTo(h, '/api/projects/project_owned/3dgs/point_cloud.ply').length, 0);
});

test('generic point cloud does not become a valid Gaussian output and original response bytes survive', async t => {
  const invalid = Buffer.from('ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nend_header\n0\n');
  const h = await harness(t, { handle: ({ url, response }) => { if (!url.pathname.endsWith('point_cloud.ply')) return false; response.end(invalid); return true; } });
  await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() }); h.state.ready = true;
  await assert.rejects(resumeRun({ directory: h.runDirectory, client: h.makeClient() }), { code: 'not_gaussian_ply' });
  assert.equal((await readRun(h.runDirectory)).phase, 'download_failed');
  assert.deepEqual(await readFile(path.join(h.runDirectory, 'received.ply')), invalid);
  assert.equal((await readdir(h.runDirectory)).includes('scene.ply'), false);
});

test('provider redirect is not followed with credentials and PLY size remains bounded', async t => {
  let forwarded = 0;
  const h = await harness(t, { handle: ({ url, response }) => {
    if (url.pathname.endsWith('/capabilities')) { response.writeHead(302, { Location: '/api/secret' }); response.end(); return true; }
    if (url.pathname === '/api/secret') { forwarded++; response.end('{}'); return true; }
  } });
  await assert.rejects(h.makeClient().capabilities(), { code: 'request_failed' }); assert.equal(forwarded, 0);
  await assert.rejects(h.makeClient({ maxPLYBytes: 10 }).downloadPLY('project_owned', 'step_owned', path.join(h.directory, 'too-large.ply')), { code: 'ply_too_large' });
  assert.equal((await readdir(h.directory)).some(name => name.endsWith('.part') || name === 'too-large.ply'), false);
});

test('poll timeout retains provider task and never submits, cancels or deletes it', async t => {
  const h = await harness(t); await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  const state = await resumeRun({ directory: h.runDirectory, client: h.makeClient(), maxWaitMs: 45, pollMs: 15 });
  assert.equal(state.phase, 'submitted'); assert.ok(h.calls.filter(call => call.url.includes('/3dgs?')).length >= 2);
  assert.equal(h.calls.filter(call => call.method === 'DELETE' || /cancel/.test(call.url)).length, 0);
});

test('different provider origin and edited output are rejected instead of silently replacing lineage', async t => {
  const h = await harness(t); await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  await assert.rejects(resumeRun({ directory: h.runDirectory, client: new WorldMirrorClient({ origin: 'http://127.0.0.1:1' }) }), { code: 'origin_mismatch' });
  h.state.ready = true; await resumeRun({ directory: h.runDirectory, client: h.makeClient() });
  await writeFile(path.join(h.runDirectory, 'scene.ply'), 'edited');
  await assert.rejects(resumeRun({ directory: h.runDirectory, client: h.makeClient() }), { code: 'output_changed' });
});

test('timeout while reading PLY body removes partial bytes and keeps remote task resumable', async t => {
  const h = await harness(t, { handle: ({ url, response }) => {
    if (!url.pathname.endsWith('point_cloud.ply')) return false;
    response.writeHead(200); response.write('ply\n'); return true;
  } });
  await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() }); h.state.ready = true;
  await assert.rejects(resumeRun({ directory: h.runDirectory, client: h.makeClient({ timeoutMs: 80 }) }), { code: 'request_timeout' });
  assert.equal((await readRun(h.runDirectory)).phase, 'download_failed');
  assert.equal((await readdir(h.runDirectory)).some(name => /\.part$|\.ply$/.test(name)), false);
  assert.equal(h.calls.filter(call => call.method === 'DELETE' || /cancel/.test(call.url)).length, 0);
});

test('crash after original PLY download resumes validation without redownloading', async t => {
  const h = await harness(t); await uploadRun(h.input); let state = await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  state.phase = 'download_pending'; await writeFile(path.join(h.runDirectory, 'manifest.json'), JSON.stringify(state));
  await writeFile(path.join(h.runDirectory, 'received.ply'), ply); h.state.ready = true;
  state = await resumeRun({ directory: h.runDirectory, client: h.makeClient() });
  assert.equal(state.phase, 'downloaded'); assert.equal(callsTo(h, '/api/projects/project_owned/3dgs/point_cloud.ply').length, 0);
});

test('terminal failure is reported without inventing output or cancelling provider work', async t => {
  const h = await harness(t, { handle: ({ url, response }) => {
    if (!url.pathname.endsWith('/3dgs')) return false;
    const body = result(false); body.step.status = 'FAILED'; response.end(JSON.stringify(body)); return true;
  } });
  await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  const state = await resumeRun({ directory: h.runDirectory, client: h.makeClient() });
  assert.equal(state.phase, 'provider_failed'); assert.equal(state.output, undefined);
  assert.equal(callsTo(h, '/api/projects/project_owned/3dgs/point_cloud.ply').length, 0);
});

test('an artifact during RUNNING is not a successful reconstruction', async t => {
  const h = await harness(t, { handle: ({ url, response }) => {
    if (!url.pathname.endsWith('/3dgs')) return false;
    const body = result(true); body.step.status = 'RUNNING'; body.result_step.status = 'RUNNING'; response.end(JSON.stringify(body)); return true;
  } });
  await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  const state = await resumeRun({ directory: h.runDirectory, client: h.makeClient() });
  assert.equal(state.phase, 'submitted'); assert.equal(state.output, undefined);
  assert.equal(callsTo(h, '/api/projects/project_owned/3dgs/point_cloud.ply').length, 0);
});

test('both selected step and result step must declare the configured success status', async t => {
  const h = await harness(t, { handle: ({ url, response }) => {
    if (!url.pathname.endsWith('/3dgs')) return false;
    const body = result(true); body.result_step = { ...body.step, status: 'RUNNING' }; response.end(JSON.stringify(body)); return true;
  } });
  await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() });
  const state = await resumeRun({ directory: h.runDirectory, client: h.makeClient() });
  assert.equal(state.phase, 'submitted'); assert.equal(state.output, undefined);
});

test('default unconfirmed success contract stays closed; explicit verified configuration can resume same project', async t => {
  const h = await harness(t), unconfirmed = h.makeClient({ successStatus: null });
  await uploadRun({ ...h.input, client: unconfirmed }); await quickRun({ directory: h.runDirectory, client: unconfirmed }); h.state.ready = true;
  let state = await resumeRun({ directory: h.runDirectory, client: unconfirmed });
  assert.equal(state.phase, 'awaiting_success_contract'); assert.equal(state.output, undefined);
  assert.equal(callsTo(h, '/api/projects/project_owned/3dgs/point_cloud.ply').length, 0);
  state = await resumeRun({ directory: h.runDirectory, client: h.makeClient() });
  assert.equal(state.phase, 'downloaded'); assert.equal(state.successStatus, 'SUCCESS');
  assert.equal(callsTo(h, '/api/3dgs/quick-reconstruct').length, 1);
  await assert.rejects(resumeRun({ directory: h.runDirectory, client: h.makeClient({ successStatus: 'COMPLETED' }) }), { code: 'status_contract_mismatch' });
  assert.throws(() => h.makeClient({ successStatus: 'RUNNING' }), { code: 'invalid_success_status' });
});

for (const [label, change, code] of [
  ['asset', body => { body.images.id = 'someone_elses_images'; }, 'inputs_mismatch'],
  ['frame count', body => { body.images.image_count = 5; }, 'inputs_mismatch'],
  ['revision', body => { body.revision = 2; }, 'input_revision_mismatch'],
  ['prepared revision', body => { body.prepared_revision = 2; }, 'input_revision_mismatch'],
]) test(`changed reconstruction input ${label} cannot pass source lineage checks`, async t => {
  const h = await harness(t, { handle: ({ url, response }) => {
    if (!url.pathname.endsWith('/3dgs/inputs')) return false;
    const body = inputs(); change(body); response.end(JSON.stringify(body)); return true;
  } });
  await uploadRun(h.input); await quickRun({ directory: h.runDirectory, client: h.makeClient() }); h.state.ready = true;
  await assert.rejects(resumeRun({ directory: h.runDirectory, client: h.makeClient() }), { code });
  assert.equal(callsTo(h, '/api/projects/project_owned/3dgs/point_cloud.ply').length, 0);
});

test('frames changed while creating the group are never uploaded under old hashes', async t => {
  let filesDirectory;
  const h = await harness(t, { handle: async ({ url }) => {
    if (url.pathname === '/api/project_groups') await writeFile(path.join(filesDirectory, '001.jpg'), 'CHANGED AFTER MANIFEST');
    return false;
  } }); filesDirectory = h.filesDirectory;
  await assert.rejects(uploadRun(h.input), { code: 'input_changed' });
  assert.equal((await readRun(h.runDirectory)).phase, 'group_created');
  assert.equal(callsTo(h, '/api/3dgs/assets/images').length, 0);
});

test('source cancellation between group creation and images stops the next mutation without an unknown write', async t => {
  const h = await harness(t); let checks = 0;
  await assert.rejects(uploadRun({ ...h.input, beforeMutation: async () => { if (++checks === 2) { const error = new Error('source cancelled'); error.code = 'source_cancelled'; throw error; } } }), { code: 'source_cancelled' });
  const state = await readRun(h.runDirectory); assert.equal(state.phase, 'group_created'); assert.equal(state.operations.images, undefined);
  assert.equal(callsTo(h, '/api/3dgs/assets/images').length, 0);
});

test('source cancellation before quick does not create a request intent or start GPU work', async t => {
  const h = await harness(t); await uploadRun(h.input);
  await assert.rejects(quickRun({ directory: h.runDirectory, client: h.makeClient(), beforeMutation: async () => { const error = new Error('source deleted'); error.code = 'source_deleted'; throw error; } }), { code: 'source_deleted' });
  const state = await readRun(h.runDirectory); assert.equal(state.phase, 'images_uploaded'); assert.equal(state.operations.quick, undefined);
  assert.equal(callsTo(h, '/api/3dgs/quick-reconstruct').length, 0);
});
