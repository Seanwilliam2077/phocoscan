import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile, stat, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID, randomBytes, createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { createServer } from '../src/server.mjs';

const runFile = promisify(execFile);
const testRoot = path.dirname(fileURLToPath(import.meta.url));
const properties = ['x', 'y', 'z', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3'];
const values = [0, 0, 1, 0.3, 0.2, 0.1, 2, -3, -3, -3, 1, 0, 0, 0];
const ply = (rows = [values], names = properties) => Buffer.from(`ply\nformat ascii 1.0\ncomment SYNTHETIC TEST FIXTURE - NOT A REAL CAPTURE\nelement vertex ${rows.length}\n${names.map(name => `property float ${name}`).join('\n')}\nend_header\n${rows.map(row => row.join(' ')).join('\n')}\n`);
const binaryPLY = () => {
  const header = Buffer.from(`ply\nformat binary_little_endian 1.0\ncomment SYNTHETIC TEST FIXTURE\nelement vertex 1\n${properties.map(name => `property float ${name}`).join('\n')}\nend_header\n`);
  const data = Buffer.alloc(values.length * 4); values.forEach((v, i) => data.writeFloatLE(v, i * 4));
  return Buffer.concat([header, data]);
};
const splat = () => {
  const data = Buffer.alloc(32, 128);
  [0, 0, 1, 0.1, 0.2, 0.1].forEach((v, i) => data.writeFloatLE(v, i * 4));
  data[27] = 255; data[28] = 255; return data;
};
const box = (name, payload) => { const header = Buffer.alloc(8); header.writeUInt32BE(payload.length + 8); header.write(name, 4); return Buffer.concat([header, payload]); };
// Intentionally only a container fixture, not playable media or real capture evidence.
const video = Buffer.concat([box('ftyp', Buffer.from('qt  \0\0\0\0')), box('moov', Buffer.from('SYNTHETIC_TEST')), box('mdat', Buffer.from('SYNTHETIC_NOT_VIDEO'))]);
const metadata = { capturedAt: '2026-10-22T01:00:00.000Z', durationSeconds: 61.5, width: 1920, height: 1080, fps: 30 };
const multipart = (files, boundary = 'PocketWorldTestBoundary') => ({
  type: `multipart/form-data; boundary=${boundary}`,
  bytes: Buffer.concat([...files.flatMap(({ name = 'file', filename = 'capture.mov', mime = 'video/quicktime', bytes = video }) => [Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"; filename="${filename}"\r\nContent-Type: ${mime}\r\n\r\n`), bytes, Buffer.from('\r\n')]), Buffer.from(`--${boundary}--\r\n`)]),
});

async function harness(t, options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), 'pocketworld-test-'));
  const adminToken = randomBytes(32).toString('base64url');
  let server;
  const result = { directory, adminToken };
  async function start() {
    server = createServer({ dataDir: path.join(directory, 'data'), adminToken, logger: { error: message => { throw new Error(message); } }, ...options });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    result.base = `http://127.0.0.1:${server.address().port}`;
  }
  async function stop() {
    if (!server) return;
    await new Promise(resolve => { server.close(resolve); server.closeIdleConnections(); });
    server.closeDatabase(); server = null;
  }
  result.restart = async () => { await stop(); await start(); };
  result.request = async (endpoint, { token, admin, method = 'GET', body, bytes, type, headers = {} } = {}) => {
    const options = { method, headers: { ...headers } };
    if (admin || token) options.headers.Authorization = `Bearer ${admin ? adminToken : token}`;
    if (body !== undefined) { options.body = JSON.stringify(body); options.headers['Content-Type'] = 'application/json'; }
    if (bytes !== undefined) { options.body = bytes; options.headers['Content-Type'] = type ?? 'application/octet-stream'; }
    const response = await fetch(result.base + endpoint, options);
    const contentType = response.headers.get('content-type') ?? '';
    return { status: response.status, headers: response.headers, data: contentType.includes('application/json') ? await response.json() : Buffer.from(await response.arrayBuffer()) };
  };
  result.register = async () => {
    const response = await result.request('/v1/auth/anonymous', { method: 'POST', body: {} });
    assert.equal(response.status, 201); return response.data;
  };
  result.session = async (token, override = {}) => {
    const input = { id: randomUUID(), questId: 'first_light', environment: 'indoor', captureMode: 'in_app_rgb', consentVersion: '2026-10-22-v1', ...override };
    const response = await result.request('/v1/sessions', { method: 'POST', token, body: input });
    assert.equal(response.status, 201, JSON.stringify(response.data));
    return { input, ...response.data };
  };
  result.submitted = async (token, overrides = {}) => {
    const item = await result.session(token, overrides);
    const uploaded = await result.request(`/v1/sessions/${item.session.id}/video`, { method: 'PUT', token, bytes: video, type: 'video/quicktime' });
    assert.equal(uploaded.status, 200, JSON.stringify(uploaded.data));
    const submitted = await result.request(`/v1/sessions/${item.session.id}/submit`, { method: 'POST', token, body: metadata });
    assert.equal(submitted.status, 200, JSON.stringify(submitted.data));
    return submitted.data;
  };
  await start();
  t.after(async () => { await stop(); await rm(directory, { recursive: true, force: true }); });
  return result;
}

test('health, authentication and user/admin separation', async t => {
  const h = await harness(t), alice = await h.register();
  assert.deepEqual((await h.request('/health')).data, { ok: true, version: '0.1.0', features: ['resumable-rgb-upload', 'arkit-prior-training', 'arkit-keyframes', 'sfm-subject-keyframes', 'reconstruction-selection', 'keyframe-files'] });
  assert.equal((await h.request('/v1/sessions')).status, 401);
  assert.equal((await h.request('/v1/admin/jobs', { token: alice.token })).status, 401);
  assert.equal((await h.request('/v1/sessions', { admin: true })).status, 401);
  assert.equal((await h.request('/v1/admin/jobs', { admin: true })).status, 200);
});

test('native video → queued job → manual real-file import → reward, retries idempotent', async t => {
  const h = await harness(t), alice = await h.register();
  const item = await h.submitted(alice.token);
  assert.equal(item.job.status, 'queued');
  assert.equal(item.session.poseSource, 'none');
  assert.equal(item.session.calibrationAvailable, false);
  assert.equal(item.session.rawDataAvailable, true);
  const earlyReward = await h.request(`/v1/sessions/${item.session.id}/reward`, { method: 'POST', token: alice.token, body: {} });
  assert.equal(earlyReward.status, 200);
  // A successfully uploaded scan must already appear as a memory and carry its
  // one real receipt while reconstruction is still queued.
  const memories = await h.request('/v1/sessions', { token: alice.token });
  assert.equal(memories.status, 200);
  assert.equal(memories.data.sessions.length, 1);
  assert.equal(memories.data.sessions[0].session.id, item.session.id);
  assert.equal(memories.data.sessions[0].session.captureStatus, 'submitted');
  assert.equal(memories.data.sessions[0].reward.id, earlyReward.data.reward.id);
  assert.equal(memories.data.sessions[0].asset, null);
  assert.equal(memories.data.sessions[0].job.status, 'queued');
  const repeatedReward = await h.request(`/v1/sessions/${item.session.id}/reward`, { method: 'POST', token: alice.token, body: {} });
  assert.equal(repeatedReward.data.reward.id, earlyReward.data.reward.id);
  const retriedSubmit = await h.request(`/v1/sessions/${item.session.id}/submit`, { method: 'POST', token: alice.token, body: metadata });
  assert.equal(retriedSubmit.data.job.id, item.job.id);
  const start = await h.request(`/v1/admin/jobs/${item.job.id}/status`, { method: 'PUT', admin: true, body: { status: 'processing' } });
  assert.equal(start.data.job.status, 'processing');
  const imported = await h.request(`/v1/admin/jobs/${item.job.id}/asset?format=ply&tool=TEST_FIXTURE&version=1`, { method: 'PUT', admin: true, bytes: binaryPLY() });
  assert.equal(imported.status, 200, JSON.stringify(imported.data));
  assert.equal(imported.data.job.status, 'ready');
  assert.equal(imported.data.asset.qualityStatus, 'needs_review');
  assert.equal(imported.data.asset.dualUseStatus, 'not_evaluated');
  assert.equal(imported.data.asset.lineageStatus, 'declared');
  assert.deepEqual(imported.data.asset.sourceSessionIds, [item.session.id]);
  assert.equal(imported.data.reward.id, earlyReward.data.reward.id);
  const retry = await h.request(`/v1/admin/jobs/${item.job.id}/asset?format=ply&tool=TEST_FIXTURE`, { method: 'PUT', admin: true, bytes: binaryPLY() });
  assert.equal(retry.data.asset.id, imported.data.asset.id);
  const downloaded = await h.request(`/v1/assets/${imported.data.asset.id}/file`, { token: alice.token });
  assert.deepEqual(downloaded.data, binaryPLY());
  assert.equal(downloaded.headers.get('x-content-sha256'), createHash('sha256').update(binaryPLY()).digest('hex'));
});

test('external asset path marks missing raw data and only rewards a parsed model', async t => {
  const h = await harness(t), alice = await h.register();
  const item = await h.session(alice.token, { captureMode: 'external_app', environment: 'outdoor', questId: 'rest_stop' });
  const endpoint = `/v1/sessions/${item.session.id}`;
  assert.equal((await h.request(endpoint + '/reward', { method: 'POST', token: alice.token, body: {} })).status, 409);
  assert.equal((await h.request(endpoint + '/video', { method: 'PUT', token: alice.token, bytes: video, type: 'video/quicktime' })).status, 409);
  const imported = await h.request(endpoint + '/asset?format=ply&tool=TEST_FIXTURE', { method: 'PUT', token: alice.token, bytes: ply() });
  assert.equal(imported.status, 200, JSON.stringify(imported.data));
  assert.equal(imported.data.session.captureStatus, 'asset_imported');
  assert.equal(imported.data.session.provenance, 'external_asset_only');
  assert.equal(imported.data.session.rawDataAvailable, false);
  assert.equal(imported.data.asset.provenance, 'external_asset_only');
  const claimed = await h.request(endpoint + '/reward', { method: 'POST', token: alice.token, body: {} });
  assert.equal(claimed.data.reward.cardKind, 'rest');
});

test('cross-user session, asset, preview, deletion, rewards and events are inaccessible', async t => {
  const h = await harness(t), alice = await h.register(), bob = await h.register();
  const item = await h.session(alice.token, { captureMode: 'external_app' });
  const imported = await h.request(`/v1/sessions/${item.session.id}/asset?format=splat&tool=TEST_FIXTURE`, { method: 'PUT', token: alice.token, bytes: splat() });
  assert.equal(imported.status, 200);
  for (const [endpoint, method, body] of [
    [`/v1/sessions/${item.session.id}`, 'GET'],
    [`/v1/sessions/${item.session.id}`, 'DELETE'],
    [`/v1/sessions/${item.session.id}/preview`, 'GET'],
    [`/v1/sessions/${item.session.id}/reward`, 'POST', {}],
    [`/v1/assets/${imported.data.asset.id}/file`, 'GET'],
  ]) assert.equal((await h.request(endpoint, { token: bob.token, method, body })).status, 404);
  const event = { id: randomUUID(), name: 'result_viewed', occurredAt: new Date().toISOString(), sessionId: item.session.id };
  assert.equal((await h.request('/v1/events', { method: 'POST', token: bob.token, body: { events: [event] } })).status, 404);
  assert.equal((await h.request('/v1/sessions', { token: bob.token })).data.sessions.length, 0);
});

test('concurrent duplicate claims, creates and imports issue exactly one record each', async t => {
  const h = await harness(t), alice = await h.register();
  const original = await h.session(alice.token, { captureMode: 'external_app' });
  const creates = await Promise.all(Array.from({ length: 5 }, () => h.request('/v1/sessions', { method: 'POST', token: alice.token, body: original.input })));
  assert.ok(creates.every(response => response.status === 200));
  const imports = await Promise.all(Array.from({ length: 4 }, () => h.request(`/v1/sessions/${original.session.id}/asset?format=ply&tool=TEST_FIXTURE`, { method: 'PUT', token: alice.token, bytes: ply() })));
  assert.ok(imports.every(response => response.status === 200));
  assert.equal(new Set(imports.map(response => response.data.asset.id)).size, 1);
  const claims = await Promise.all(Array.from({ length: 8 }, () => h.request(`/v1/sessions/${original.session.id}/reward`, { method: 'POST', token: alice.token, body: {} })));
  assert.ok(claims.every(response => response.status === 200));
  assert.equal(new Set(claims.map(response => response.data.reward.id)).size, 1);
  const metrics = (await h.request('/v1/admin/metrics', { admin: true })).data;
  assert.equal(metrics.sessions, 1); assert.equal(metrics.rewards, 1); assert.equal(metrics.jobsByStatus.ready, 1);
});

test('source metadata and file conflicts are rejected instead of overwriting provenance', async t => {
  const h = await harness(t), alice = await h.register();
  const original = await h.session(alice.token);
  assert.equal((await h.request('/v1/sessions', { method: 'POST', token: alice.token, body: { ...original.input, environment: 'outdoor' } })).status, 409);
  const uploaded = await h.request(`/v1/sessions/${original.session.id}/video`, { method: 'PUT', token: alice.token, bytes: video, type: 'video/quicktime' });
  assert.equal(uploaded.status, 200);
  const changed = Buffer.concat([video, box('free', Buffer.from('DIFFERENT'))]);
  assert.equal((await h.request(`/v1/sessions/${original.session.id}/video`, { method: 'PUT', token: alice.token, bytes: changed, type: 'video/quicktime' })).status, 409);
  assert.equal((await h.request(`/v1/sessions/${original.session.id}/video`, { method: 'PUT', token: alice.token, bytes: video, type: 'video/quicktime' })).status, 200);
  assert.equal((await h.request(`/v1/sessions/${original.session.id}/submit`, { method: 'POST', token: alice.token, body: metadata })).status, 200);
  assert.equal((await h.request(`/v1/sessions/${original.session.id}/submit`, { method: 'POST', token: alice.token, body: { ...metadata, width: 42 } })).status, 409);
});

test('generic point cloud, truncated binary, NaN, partial SH and unsupported SPZ are rejected', async t => {
  const h = await harness(t), alice = await h.register();
  const item = await h.session(alice.token, { captureMode: 'external_app' });
  const upload = (bytes, format = 'ply') => h.request(`/v1/sessions/${item.session.id}/asset?format=${format}&tool=TEST_FIXTURE`, { method: 'PUT', token: alice.token, bytes });
  assert.equal((await upload(ply([[1, 2, 3]], ['x', 'y', 'z']))).data.error.code, 'not_gaussian_ply');
  assert.equal((await upload(binaryPLY().subarray(0, binaryPLY().length - 4))).data.error.code, 'invalid_ply_length');
  assert.equal((await upload(ply([[NaN, ...values.slice(1)]]))).data.error.code, 'invalid_ply_record');
  assert.equal((await upload(ply([[...values, 1]], [...properties, 'f_rest_0']))).data.error.code, 'unsupported_sh_degree');
  assert.equal((await upload(Buffer.from('NOT SPZ'), 'spz')).status, 415);
  assert.equal((await h.request(`/v1/sessions/${item.session.id}/reward`, { method: 'POST', token: alice.token, body: {} })).status, 409);
  const latest = (await h.request(`/v1/sessions/${item.session.id}`, { token: alice.token })).data;
  assert.equal(latest.asset, null); assert.equal(latest.job, null);
});

test('bad splat length/nonfinite scales and large declared counts are rejected', async t => {
  const h = await harness(t), alice = await h.register();
  const item = await h.session(alice.token, { captureMode: 'external_app' });
  const endpoint = `/v1/sessions/${item.session.id}/asset?tool=TEST_FIXTURE&format=`;
  assert.equal((await h.request(endpoint + 'splat', { method: 'PUT', token: alice.token, bytes: splat().subarray(1) })).status, 422);
  const bad = splat(); bad.writeFloatLE(Infinity, 12);
  assert.equal((await h.request(endpoint + 'splat', { method: 'PUT', token: alice.token, bytes: bad })).status, 422);
  const oversized = Buffer.from(ply().toString().replace('element vertex 1', 'element vertex 1000001'));
  assert.equal((await h.request(endpoint + 'ply', { method: 'PUT', token: alice.token, bytes: oversized })).data.error.code, 'invalid_ply_count');
});

test('upload size limits, invalid video boxes and unsafe IDs fail without publishing files', async t => {
  const h = await harness(t, { limits: { model: 512, video: 1000 } }), alice = await h.register();
  const item = await h.session(alice.token);
  assert.equal((await h.request(`/v1/sessions/${item.session.id}/video`, { method: 'PUT', token: alice.token, bytes: Buffer.from('not a movie'), type: 'video/quicktime' })).status, 422);
  assert.equal((await h.request(`/v1/sessions/${item.session.id}/video`, { method: 'PUT', token: alice.token, bytes: Buffer.alloc(1001), type: 'video/quicktime' })).status, 413);
  const invalidSession = await h.request('/v1/sessions', { method: 'POST', token: alice.token, body: { ...item.input, id: '../escape' } });
  assert.equal(invalidSession.status, 400);
  assert.equal((await h.request(`/v1/sessions/${item.session.id}/submit`, { method: 'POST', token: alice.token, body: metadata })).status, 409);
});

test('processing failure keeps card, retry is explicit, ready cannot be set without an asset', async t => {
  const h = await harness(t), alice = await h.register(), item = await h.submitted(alice.token);
  const before = (await h.request(`/v1/sessions/${item.session.id}/reward`, { method: 'POST', token: alice.token, body: {} })).data.reward;
  const endpoint = `/v1/admin/jobs/${item.job.id}/status`;
  assert.equal((await h.request(endpoint, { method: 'PUT', admin: true, body: { status: 'ready' } })).status, 400);
  assert.equal((await h.request(endpoint, { method: 'PUT', admin: true, body: { status: 'failed' } })).status, 400);
  const failed = await h.request(endpoint, { method: 'PUT', admin: true, body: { status: 'failed', errorMessage: 'Insufficient view overlap in actual processing.' } });
  assert.equal(failed.data.job.status, 'failed'); assert.equal(failed.data.reward.id, before.id);
  const retry = await h.request(endpoint, { method: 'PUT', admin: true, body: { status: 'queued' } });
  assert.equal(retry.data.job.status, 'queued'); assert.equal(retry.data.job.errorMessage, undefined);
});

test('cancelled reconstruction rejects stale worker status and late assets until explicit requeue', async t => {
  const h = await harness(t), alice = await h.register(), item = await h.submitted(alice.token);
  const reward = (await h.request(`/v1/sessions/${item.session.id}/reward`, { method: 'POST', token: alice.token, body: {} })).data.reward;
  const endpoint = `/v1/admin/jobs/${item.job.id}`;
  assert.equal((await h.request(endpoint + '/status', { method: 'PUT', admin: true, body: { status: 'processing', expectedStatus: 'queued' } })).status, 200);
  assert.equal((await h.request(endpoint + '/status', { method: 'PUT', admin: true, body: { status: 'cancelled' } })).status, 200);
  const stale = await h.request(endpoint + '/status', { method: 'PUT', admin: true, body: { status: 'processing', expectedStatus: 'queued' } });
  assert.equal(stale.status, 409); assert.equal(stale.data.error.code, 'job_status_conflict');
  const implicitRetry = await h.request(endpoint + '/status', { method: 'PUT', admin: true, body: { status: 'processing' } });
  assert.equal(implicitRetry.status, 409); assert.equal(implicitRetry.data.error.code, 'job_cancelled');
  const assetPath = endpoint + '/asset?format=ply&tool=TEST_FIXTURE';
  const late = await h.request(assetPath, { method: 'PUT', admin: true, bytes: binaryPLY() });
  assert.equal(late.status, 409); assert.equal(late.data.error.code, 'job_cancelled');
  const current = (await h.request(`/v1/sessions/${item.session.id}`, { token: alice.token })).data;
  assert.equal(current.job.status, 'cancelled'); assert.equal(current.asset, null); assert.equal(current.reward.id, reward.id);
  assert.deepEqual((await h.request(`/v1/admin/sessions/${item.session.id}/video`, { admin: true })).data, video);
  assert.equal((await h.request(endpoint + '/status', { method: 'PUT', admin: true, body: { status: 'queued', expectedStatus: 'cancelled' } })).status, 200);
  assert.equal((await h.request(assetPath, { method: 'PUT', admin: true, bytes: binaryPLY() })).data.job.status, 'ready');
});

test('review is independent from render readiness; dual-use acceptance is blocked without evidence capability', async t => {
  const h = await harness(t), alice = await h.register();
  const item = await h.session(alice.token, { captureMode: 'external_app' });
  const asset = (await h.request(`/v1/sessions/${item.session.id}/asset?format=ply&tool=TEST_FIXTURE`, { method: 'PUT', token: alice.token, bytes: ply() })).data.asset;
  const endpoint = `/v1/admin/assets/${asset.id}/review`;
  const body = { qualityStatus: 'accepted', lineageStatus: 'verified', dualUseStatus: 'accepted', notes: 'TEST ONLY' };
  assert.equal((await h.request(endpoint, { method: 'PATCH', admin: true, body })).data.error.code, 'dual_use_unavailable');
  const reviewed = await h.request(endpoint, { method: 'PATCH', admin: true, body: { ...body, dualUseStatus: 'partial', notes: 'TEST ONLY: visual asset checked, no raw source video or camera poses.' } });
  assert.equal(reviewed.status, 200); assert.equal(reviewed.data.asset.dualUseStatus, 'partial');
  const refreshed = (await h.request(`/v1/sessions/${item.session.id}`, { token: alice.token })).data;
  assert.equal(refreshed.job.status, 'ready'); assert.equal(refreshed.asset.qualityStatus, 'accepted');
});

test('game state, tokens, sessions and rewards survive service restart', async t => {
  const h = await harness(t), alice = await h.register(), item = await h.submitted(alice.token);
  const state = { name: '测试小站', grid: [{ x: 0, y: 0, card: 'entrance' }], localOnlyExperiment: true };
  assert.equal((await h.request('/v1/game', { method: 'PUT', token: alice.token, body: { state } })).status, 200);
  const reward = (await h.request(`/v1/sessions/${item.session.id}/reward`, { method: 'POST', token: alice.token, body: {} })).data.reward;
  await h.restart();
  assert.deepEqual((await h.request('/v1/game', { token: alice.token })).data.state, state);
  assert.equal((await h.request(`/v1/sessions/${item.session.id}`, { token: alice.token })).data.reward.id, reward.id);
  assert.equal((await h.request('/v1/admin/jobs', { admin: true })).data.jobs.length, 1);
});

test('events are atomic/idempotent and event IDs cannot overwrite other data', async t => {
  const h = await harness(t), alice = await h.register(), bob = await h.register();
  const event = { id: randomUUID(), name: 'onboarding_completed', occurredAt: '2026-10-22T00:00:00.000Z', properties: { theme: 'garden' } };
  const submit = (token, events) => h.request('/v1/events', { method: 'POST', token, body: { events } });
  assert.equal((await submit(alice.token, [event])).data.accepted, 1);
  assert.equal((await submit(alice.token, [event])).data.accepted, 0);
  assert.equal((await submit(bob.token, [event])).status, 409);
  assert.equal((await submit(alice.token, [{ ...event, name: 'another_event' }])).status, 409);
  assert.equal((await submit(alice.token, [{ ...event, id: randomUUID() }, { ...event, name: 'changed_conflict' }])).status, 409);
  assert.equal((await h.request('/v1/admin/events', { admin: true })).data.events.length, 1);
});

test('recapture inherits scene, deletion removes bytes/derived refs and prevents ID reuse', async t => {
  const h = await harness(t), alice = await h.register();
  const parent = await h.submitted(alice.token);
  const child = await h.session(alice.token, { questId: 'repair_view', parentSessionId: parent.session.id });
  assert.equal(child.session.sceneId, parent.session.sceneId);
  const imported = await h.request(`/v1/admin/jobs/${parent.job.id}/asset?format=ply&tool=TEST_FIXTURE`, { method: 'PUT', admin: true, bytes: ply() });
  const assetId = imported.data.asset.id;
  await h.request(`/v1/sessions/${parent.session.id}/reward`, { method: 'POST', token: alice.token, body: {} });
  await h.request('/v1/game', { method: 'PUT', token: alice.token, body: { state: { card: { sessionId: parent.session.id, assetId, kind: 'lobby' } } } });
  assert.equal((await h.request(`/v1/sessions/${parent.session.id}`, { method: 'DELETE', token: alice.token })).status, 200);
  assert.equal((await h.request(`/v1/sessions/${parent.session.id}`, { method: 'DELETE', token: alice.token })).status, 200);
  assert.equal((await h.request(`/v1/assets/${assetId}/file`, { token: alice.token })).status, 404);
  await assert.rejects(stat(path.join(h.directory, 'data', 'sessions', parent.session.id)), { code: 'ENOENT' });
  const detached = (await h.request(`/v1/sessions/${child.session.id}`, { token: alice.token })).data.session;
  assert.equal(detached.parentSessionId, undefined); assert.equal(detached.parentDeleted, true);
  const state = (await h.request('/v1/game', { token: alice.token })).data.state;
  assert.deepEqual(state.card, { sessionId: null, assetId: null, kind: 'lobby' });
  const recreate = await h.request('/v1/sessions', { method: 'POST', token: alice.token, body: { id: parent.session.id, questId: 'first_light', environment: 'indoor', captureMode: 'in_app_rgb', consentVersion: '2026-10-22-v1' } });
  assert.equal(recreate.data.error.code, 'session_deleted');
  const bundle = await h.request(`/v1/admin/sessions/${parent.session.id}/bundle`, { admin: true });
  assert.equal(bundle.status, 404);
});

test('source bundle exposes honest metadata, authenticated byte ranges preserve original bytes', async t => {
  const h = await harness(t), alice = await h.register(), item = await h.submitted(alice.token);
  const bundle = (await h.request(`/v1/admin/sessions/${item.session.id}/bundle`, { admin: true })).data;
  assert.equal(bundle.manifest.poseSource, 'none');
  assert.equal(bundle.manifest.videoMetadataSource, 'client_reported');
  assert.ok(bundle.manifest.missingFields.includes('camera_poses'));
  assert.equal(bundle.files[0].sha256, createHash('sha256').update(video).digest('hex'));
  const partial = await h.request(bundle.files[0].url, { admin: true, headers: { Range: 'bytes=0-7' } });
  assert.equal(partial.status, 206); assert.deepEqual(partial.data, video.subarray(0, 8));
  assert.equal((await h.request(bundle.files[0].url, { admin: true, headers: { Range: 'bytes=9999-' } })).status, 416);
});

test('deletion leaves a Codable-shaped game backup and stale backups cannot revive deleted records', async t => {
  const h = await harness(t), alice = await h.register();
  const deleted = await h.submitted(alice.token);
  const kept = await h.submitted(alice.token, { questId: 'repair_view', parentSessionId: deleted.session.id });
  const imported = await h.request(`/v1/admin/jobs/${deleted.job.id}/asset?format=ply&tool=TEST_FIXTURE`, { method: 'PUT', admin: true, bytes: ply() });
  const asset = imported.data.asset;
  const reward = (await h.request(`/v1/sessions/${deleted.session.id}/reward`, { method: 'POST', token: alice.token, body: {} })).data.reward;
  const makeVideo = sessionId => ({ sessionId, fileName: `${sessionId}.mov`, previewFileName: null, capturedAt: metadata.capturedAt, durationSeconds: 61.5, width: 1920, height: 1080, fps: 30 });
  const state = {
    schemaVersion: 1, townName: '可恢复小站', theme: '花园小站', onboarded: true,
    cards: [{ id: 'virtual-kept-card', kind: 'lobby', sessionId: deleted.session.id, roadShape: 'cross', rotation: 0, createdAt: metadata.capturedAt }],
    grid: ['virtual-kept-card', null, null, null, null, null, null, null, null],
    completedQuests: ['first_light'], pureBuildCompleted: false, chapterCelebrated: false,
    sessions: [imported.data, kept], videos: [makeVideo(deleted.session.id), makeVideo(kept.session.id)],
    pendingRequest: { id: randomUUID(), questId: 'repair_view', parentSessionId: deleted.session.id, captureMode: 'in_app_rgb', environment: 'indoor', consentVersion: '2026-10-22-v1' },
    activeCaptureSessionId: deleted.session.id,
    events: [
      { id: randomUUID(), name: 'result_viewed', occurredAt: metadata.capturedAt, sessionId: deleted.session.id, assetId: asset.id },
      { id: randomUUID(), name: 'asset_downloaded', occurredAt: metadata.capturedAt, assetId: asset.id },
      { id: randomUUID(), name: 'capture_saved', occurredAt: metadata.capturedAt, sessionId: kept.session.id },
    ],
    grantedRewardIds: [reward.id], updatedAt: metadata.capturedAt,
    customGameData: { untouched: ['hello', 4, true], sourceSessionId: deleted.session.id },
  };
  await h.request('/v1/game', { method: 'PUT', token: alice.token, body: { state } });
  await h.request(`/v1/sessions/${deleted.session.id}`, { method: 'DELETE', token: alice.token });
  function checkRemaining(cleaned) {
    assert.equal(cleaned.sessions.length, 1); assert.equal(cleaned.sessions[0].session.id, kept.session.id);
    assert.equal(typeof cleaned.sessions[0].session.userId, 'string');
    assert.equal(cleaned.sessions[0].session.parentSessionId, null);
    assert.equal(cleaned.videos.length, 1); assert.equal(cleaned.videos[0].sessionId, kept.session.id);
    assert.equal(cleaned.cards[0].id, 'virtual-kept-card'); assert.equal(cleaned.cards[0].sessionId, null);
    assert.deepEqual(cleaned.grid, state.grid); assert.deepEqual(cleaned.grantedRewardIds, [reward.id]);
    assert.equal(cleaned.pendingRequest, null); assert.equal(cleaned.activeCaptureSessionId, null);
    assert.deepEqual(cleaned.customGameData, { untouched: ['hello', 4, true], sourceSessionId: null });
    assert.ok(cleaned.sessions.every(entry => typeof entry.session.id === 'string'));
    assert.ok(cleaned.videos.every(entry => typeof entry.sessionId === 'string'));
    assert.ok(cleaned.events.every(entry => typeof entry.id === 'string'));
  }
  const cleaned = (await h.request('/v1/game', { token: alice.token })).data.state;
  checkRemaining(cleaned);
  assert.equal(cleaned.events.length, 1); assert.equal(cleaned.events[0].sessionId, kept.session.id);
  // An offline client trying to restore the old snapshot must not revive its session/video.
  await h.request('/v1/game', { method: 'PUT', token: alice.token, body: { state } });
  checkRemaining((await h.request('/v1/game', { token: alice.token })).data.state);
  assert.equal((await h.request(`/v1/sessions/${deleted.session.id}/reward`, { method: 'POST', token: alice.token, body: {} })).status, 404);
  assert.equal((await h.request('/v1/admin/metrics', { admin: true })).data.rewards, 1);
});

test('operator CLI exports original files, no token in output, import and review are usable', async t => {
  const h = await harness(t), alice = await h.register(), item = await h.submitted(alice.token);
  const configPath = path.join(h.directory, 'config.json');
  await writeFile(configPath, JSON.stringify({ adminToken: h.adminToken, dataDir: path.join(h.directory, 'data'), port: 8787 }));
  const cli = path.resolve(testRoot, '../admin.mjs');
  const env = { ...process.env, POCKETWORLD_CONFIG: configPath, POCKETWORLD_URL: h.base };
  const run = args => runFile(process.execPath, [cli, ...args], { env, timeout: 15000 });
  const jobs = await run(['jobs']); assert.ok(jobs.stdout.includes(item.job.id)); assert.ok(!jobs.stdout.includes(h.adminToken));
  const destination = path.join(h.directory, 'export');
  await run(['export', item.session.id, destination]);
  assert.deepEqual(await readFile(path.join(destination, 'capture.mov')), video);
  assert.equal(JSON.parse(await readFile(path.join(destination, 'manifest.json'), 'utf8')).id, item.session.id);
  await assert.rejects(run(['export', item.session.id, destination]));
  const modelFile = path.join(h.directory, 'fixture.ply'); await writeFile(modelFile, ply());
  const result = JSON.parse((await run(['import', item.job.id, modelFile, '--tool', 'TEST_FIXTURE', '--version', 'test'])).stdout);
  assert.equal(result.status, 'ready');
  const review = JSON.parse((await run(['review', result.assetId, '--quality', 'needs_review', '--lineage', 'declared', '--dual-use', 'not_evaluated', '--notes', 'Synthetic integration fixture; not real scene evidence.'])).stdout);
  assert.equal(review.assetId, result.assetId);
  const eventsFile = path.join(h.directory, 'events.jsonl');
  await run(['events', eventsFile]); assert.ok((await readFile(eventsFile, 'utf8')).includes('result_ready'));
});

test('WeChat multipart video and preview preserve original bytes, retry identity and honest unavailable metadata', async t => {
  const h = await harness(t), alice = await h.register(), bob = await h.register();
  const item = await h.session(alice.token), endpoint = `/v1/sessions/${item.session.id}`;
  const upload = multipart([{ mime: 'application/octet-stream', filename: 'capture.mov' }]);
  assert.equal((await h.request(endpoint + '/video', { method: 'POST', token: bob.token, ...upload })).status, 404);
  const first = await h.request(endpoint + '/video', { method: 'POST', token: alice.token, ...upload });
  assert.equal(first.status, 200, JSON.stringify(first.data));
  const retry = await h.request(endpoint + '/video', { method: 'POST', token: alice.token, ...upload });
  assert.equal(retry.data.session.originalVideoId, first.data.session.originalVideoId);
  assert.deepEqual((await h.request(`/v1/admin/sessions/${item.session.id}/video`, { admin: true })).data, video);
  const jpeg = Buffer.from([255, 216, 255, 224, 1, 255, 217]);
  assert.equal((await h.request(endpoint + '/preview', { method: 'POST', token: alice.token, ...multipart([{ filename: 'preview.jpg', mime: 'image/jpeg', bytes: jpeg }]) })).status, 200);
  assert.deepEqual((await h.request(endpoint + '/preview', { token: alice.token })).data, jpeg);
  const unknown = { ...metadata, fps: null, fpsSource: 'unknown', audioPolicy: 'may_contain_audio' };
  const submitted = await h.request(endpoint + '/submit', { method: 'POST', token: alice.token, body: unknown });
  assert.equal(submitted.status, 200, JSON.stringify(submitted.data));
  assert.equal(submitted.data.session.fps, null);
  assert.equal(submitted.data.session.audioPolicy, 'may_contain_audio');
  assert.equal(submitted.data.session.audioPolicySource, 'client_reported');
  assert.equal((await h.request(endpoint + '/submit', { method: 'POST', token: alice.token, body: unknown })).status, 200);
  assert.equal((await h.request(endpoint + '/submit', { method: 'POST', token: alice.token, body: { ...unknown, audioPolicy: 'not_recorded' } })).status, 409);
  const bundle = await h.request(`/v1/admin/sessions/${item.session.id}/bundle`, { admin: true });
  assert.equal(bundle.data.manifest.audioPolicy, 'may_contain_audio');
});

test('multipart rejects extra fields/files, malformed boundaries and oversize streams without retaining temp files', { timeout: 15000 }, async t => {
  const h = await harness(t, { limits: { video: video.length } }), alice = await h.register();
  const item = await h.session(alice.token), endpoint = `/v1/sessions/${item.session.id}/video`;
  const send = upload => h.request(endpoint, { method: 'POST', token: alice.token, ...upload });
  assert.equal((await send({ bytes: video, type: 'video/quicktime' })).status, 415);
  assert.equal((await send({ bytes: video, type: 'multipart/form-data' })).status, 415);
  assert.equal((await send(multipart([{ name: 'wrong' }]))).status, 400);
  assert.equal((await send(multipart([{}, {}]))).status, 400);
  const malformed = multipart([{ bytes: Buffer.from('truncated') }]); malformed.bytes = malformed.bytes.subarray(0, malformed.bytes.length - 35);
  assert.equal((await send(malformed)).status, 400);
  assert.equal((await send(multipart([{ bytes: Buffer.concat([video, Buffer.from('x')]) }]))).status, 413);
  // Send as a chunked stream: the limit must hold without Content-Length too.
  const large = multipart([{ bytes: Buffer.alloc(video.length + 50, 1) }]);
  async function* chunks() { for (let i = 0; i < large.bytes.length; i += 7) yield large.bytes.subarray(i, i + 7); }
  const streamed = await fetch(h.base + endpoint, { method: 'POST', headers: { Authorization: `Bearer ${alice.token}`, 'Content-Type': large.type }, body: chunks(), duplex: 'half' });
  assert.equal(streamed.status, 413); await streamed.arrayBuffer();
  assert.deepEqual(await readdir(path.join(h.directory, 'data', '.tmp')), []);
  assert.equal((await h.request(`/v1/sessions/${item.session.id}`, { token: alice.token })).data.session.rawDataAvailable, false);
  // The inclusive byte limit permits a file exactly at the limit.
  assert.equal((await send(multipart([{}]))).status, 200);
});

test('multipart asset → viewer derivative is authenticated, deterministic, source-preserving and deleted with session', async t => {
  const h = await harness(t), alice = await h.register(), bob = await h.register();
  const item = await h.session(alice.token, { captureMode: 'external_app' });
  const imported = await h.request(`/v1/sessions/${item.session.id}/asset?format=ply&tool=SYNTHETIC_TEST`, { method: 'POST', token: alice.token, ...multipart([{ filename: 'test.ply', mime: 'application/octet-stream', bytes: binaryPLY() }]) });
  assert.equal(imported.status, 200, JSON.stringify(imported.data));
  const asset = imported.data.asset, endpoint = `/v1/assets/${asset.id}`;
  assert.equal((await h.request(endpoint + '/viewer-info', { token: bob.token })).status, 404);
  assert.equal((await h.request(endpoint + '/viewer', { token: bob.token })).status, 404);
  assert.equal((await h.request(endpoint + '/viewer?maxPoints=100001', { token: alice.token })).status, 400);
  const info = (await h.request(endpoint + '/viewer-info', { token: alice.token })).data;
  assert.equal(info.sourceAssetId, asset.id); assert.equal(info.sourceSha256, asset.sha256);
  assert.equal(info.pointCount, 1); assert.equal(info.originalPointCount, 1);
  assert.equal(info.maxPoints, 60000); assert.equal(info.lossy, true); assert.equal(info.rendererOnly, true);
  const model = await h.request(endpoint + '/viewer', { token: alice.token });
  assert.equal(model.status, 200); assert.equal(model.data.length, 32);
  assert.equal(createHash('sha256').update(model.data).digest('hex'), info.sha256);
  assert.equal(model.headers.get('x-content-sha256'), info.sha256);
  assert.equal(model.headers.get('x-source-sha256'), asset.sha256);
  assert.equal(model.headers.get('x-renderer-only'), 'true');
  assert.deepEqual((await h.request(endpoint + '/file', { token: alice.token })).data, binaryPLY());
  const before = await readdir(path.join(h.directory, 'data', 'sessions', item.session.id, 'viewer'));
  assert.equal(before.length, 2);
  await h.restart();
  assert.deepEqual((await h.request(endpoint + '/viewer', { token: alice.token })).data, model.data);
  assert.equal((await h.request(`/v1/sessions/${item.session.id}`, { method: 'DELETE', token: alice.token })).status, 200);
  await assert.rejects(stat(path.join(h.directory, 'data', 'sessions', item.session.id)), { code: 'ENOENT' });
  assert.equal((await h.request(endpoint + '/viewer', { token: alice.token })).status, 404);
  assert.equal((await h.request(endpoint + '/viewer-info', { token: alice.token })).status, 404);
});
