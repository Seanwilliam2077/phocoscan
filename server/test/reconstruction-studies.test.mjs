import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomUUID, randomBytes } from 'node:crypto';
import { createServer } from '../src/server.mjs';
import { importReconstructionStudy, validateStudyCameras } from '../src/reconstruction-studies.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const names = ['x', 'y', 'z', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3'];
const values = [0, 0, 1, 0.3, 0.2, 0.1, 2, -3, -3, -3, 1, 0, 0, 0];
const sh3 = Buffer.from(`ply\nformat ascii 1.0\ncomment SYNTHETIC TEST ONLY\nelement vertex 1\n${[...names, ...Array.from({ length: 45 }, (_, i) => `f_rest_${i}`)].map(n => `property float ${n}`).join('\n')}\nend_header\n${[...values, ...Array.from({ length: 45 }, (_, i) => i / 100)].join(' ')}\n`);
const splat = Buffer.alloc(32, 128);
[0, 0, 1, .1, .2, .1].forEach((v, i) => splat.writeFloatLE(v, i * 4)); splat[28] = 255;
const box = (type, body) => { const head = Buffer.alloc(8); head.writeUInt32BE(body.length + 8); head.write(type, 4); return Buffer.concat([head, body]); };
const video = Buffer.concat(['moov', 'mdat'].map(name => box(name, Buffer.from('SYNTHETIC NOT A REAL VIDEO'))));
const cameras = { version: 1, coordinateSystem: 'opengl_camera_to_world', matrixLayout: 'row-major', scale: 'unknown', frames: [
  { sourceFrame: 'SYNTHETIC-frame.jpg', timeSeconds: .6, width: 540, height: 960, fx: 500, fy: 500, cx: 270, cy: 480,
    cameraToWorld: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1] },
] };

async function fixture(t) {
  const directory = await mkdtemp(path.join(tmpdir(), 'pw-study-test-'));
  const dataDir = path.join(directory, 'data'), adminToken = randomBytes(32).toString('base64url');
  let server;
  const x = { directory, dataDir, manifestPath: path.join(directory, 'manifest.json') };
  async function start() {
    server = createServer({ dataDir, adminToken, logger: { error: () => {} } });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    x.origin = `http://127.0.0.1:${server.address().port}`;
  }
  async function stop() { if (!server) return; await new Promise(resolve => { server.close(resolve); server.closeIdleConnections(); }); server.closeDatabase(); server = null; }
  t.after(async () => { await stop(); await rm(directory, { recursive: true, force: true }); });
  await start();
  x.request = (route, token, options = {}) => fetch(x.origin + route, { ...options, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...options.headers } });
  x.register = async () => (await x.request('/v1/auth/anonymous', null, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).json();
  x.user = await x.register();
  x.other = await x.register();
  await Promise.all([writeFile(path.join(directory, 'source.mp4'), video), writeFile(path.join(directory, 'preview.splat'), splat), writeFile(path.join(directory, 'refined.ply'), sh3), writeFile(path.join(directory, 'cameras.json'), JSON.stringify(cameras))]);
  x.manifest = { id: randomUUID(), title: 'SYNTHETIC_TEST_ONLY', sourceKind: 'external_rgb_video', sourceVideoSha256: hash(video), sourceVideoFile: 'source.mp4', variants: [
    { id: randomUUID(), role: 'preview', algorithm: 'gs_worldmirror2', format: 'splat', shDegree: 0, sourceFile: 'preview.splat', sourceCameraFile: 'cameras.json', sha256: hash(splat) },
    { id: randomUUID(), role: 'refined', algorithm: 'gs_mcmc', format: 'ply', shDegree: 3, sourceFile: 'refined.ply', sourceCameraFile: 'cameras.json', sha256: hash(sh3) },
  ] };
  x.import = async (override = {}) => { await writeFile(x.manifestPath, JSON.stringify(x.manifest)); return importReconstructionStudy({ dataDir, userId: x.user.userId, manifestPath: x.manifestPath, ...override }); };
  x.restart = async () => { await stop(); await start(); };
  return x;
}

test('private dual results persist, preserve SH3 bytes, validate downloads and never grant rewards', async t => {
  const x = await fixture(t);
  const { study, imported } = await x.import(); assert.equal(imported, true);
  assert.equal(study.sourceKind, 'external_rgb_video'); assert.equal(study.captureId, null);
  assert.equal(study.variants[1].shDegree, 3);
  const base = `/v2/reconstruction-studies/${study.id}`;
  assert.equal((await x.request(base)).status, 401);
  assert.equal((await x.request(base, x.other.token)).status, 404);
  assert.equal((await x.request(study.variants[1].filePath, x.other.token)).status, 404);
  const response = await x.request(study.variants[1].filePath, x.user.token);
  assert.equal(response.headers.get('x-content-sha256'), hash(sh3));
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), sh3);
  const range = await x.request(study.variants[1].filePath, x.user.token, { headers: { Range: 'bytes=0-15' } });
  assert.equal(range.status, 206); assert.deepEqual(Buffer.from(await range.arrayBuffer()), sh3.subarray(0, 16));
  const cam = await x.request(study.variants[1].cameraPath, x.user.token);
  const camBytes = Buffer.from(await cam.arrayBuffer()); assert.equal(hash(camBytes), study.variants[1].cameraSha256);
  assert.equal(camBytes.length, study.variants[1].cameraByteSize);
  assert.deepEqual(JSON.parse(camBytes), cameras);
  assert.deepEqual((await (await x.request('/v1/sessions', x.user.token)).json()).sessions, []);
  await x.restart();
  const listed = await (await x.request('/v2/reconstruction-studies', x.user.token)).json();
  assert.equal(listed.studies.length, 1); assert.equal(listed.studies[0].id, study.id);
  const publicJSON = JSON.stringify(listed); assert.ok(!publicJSON.includes(x.directory)); assert.ok(!publicJSON.includes('sourceFile'));
});

test('import is immutable/idempotent; owner deletion is durable and prevents stale reimport', async t => {
  const x = await fixture(t);
  const first = await x.import(), second = await x.import();
  assert.equal(second.imported, false); assert.deepEqual(first.study, second.study);
  await assert.rejects(x.import({ userId: x.other.userId }), { code: 'study_conflict' });
  x.manifest.title = 'Changed'; await assert.rejects(x.import(), { code: 'study_conflict' }); x.manifest.title = 'SYNTHETIC_TEST_ONLY';
  const base = `/v2/reconstruction-studies/${first.study.id}`;
  assert.equal((await x.request(base, x.other.token, { method: 'DELETE' })).status, 404);
  assert.equal((await x.request(base, x.user.token, { method: 'DELETE' })).status, 200);
  assert.equal((await x.request(base, x.user.token, { method: 'DELETE' })).status, 200);
  assert.deepEqual(await readdir(path.join(x.dataDir, 'reconstruction-studies')), []);
  await x.restart();
  await assert.rejects(x.import(), { code: 'study_deleted' });
  assert.equal((await x.request(first.study.variants[1].filePath, x.user.token)).status, 404);
});

test('bad source, model, SH declaration or cameras never publish a partial study', async t => {
  const x = await fixture(t);
  const original = structuredClone(x.manifest);
  x.manifest.sourceVideoSha256 = '0'.repeat(64); await assert.rejects(x.import(), { code: 'source_hash_mismatch' });
  x.manifest = structuredClone(original); x.manifest.variants[1].sha256 = '0'.repeat(64);
  await assert.rejects(x.import(), { code: 'study_asset_hash_mismatch' });
  x.manifest = structuredClone(original); x.manifest.variants[1].shDegree = 0;
  await assert.rejects(x.import(), { code: 'unsupported_study_variant' });
  x.manifest = structuredClone(original);
  await writeFile(path.join(x.directory, 'cameras.json'), JSON.stringify({ ...cameras, coordinateSystem: 'opencv_world_to_camera' }));
  await assert.rejects(x.import(), { code: 'invalid_study_cameras' });
  await writeFile(path.join(x.directory, 'cameras.json'), JSON.stringify(cameras));
  await writeFile(path.join(x.directory, 'refined.ply'), Buffer.from('ply\nnot a Gaussian'));
  await assert.rejects(x.import(), { code: 'invalid_ply' });
  assert.deepEqual((await (await x.request('/v2/reconstruction-studies', x.user.token)).json()).studies, []);
  assert.deepEqual(await readdir(path.join(x.dataDir, '.tmp')), []);
});

test('camera validation rejects reflected transforms, unordered times and nonfinite intrinsics', () => {
  const reflected = structuredClone(cameras); reflected.frames[0].cameraToWorld[0] = -1;
  assert.throws(() => validateStudyCameras(reflected), { code: 'invalid_study_cameras' });
  const duplicate = structuredClone(cameras); duplicate.frames.push({ ...duplicate.frames[0], sourceFrame: 'second.jpg' });
  assert.throws(() => validateStudyCameras(duplicate), { code: 'invalid_study_cameras' });
  const badIntrinsic = structuredClone(cameras); badIntrinsic.frames[0].fx = Infinity;
  assert.throws(() => validateStudyCameras(badIntrinsic), { code: 'invalid_study_cameras' });
});

test('concurrent staged reimport and owner delete cannot revive a removed study', async t => {
  const x = await fixture(t);
  const { study } = await x.import();
  const reimport = x.import().then(value => ({ value }), error => ({ error }));
  const deletion = await x.request(`/v2/reconstruction-studies/${study.id}`, x.user.token, { method: 'DELETE' });
  assert.equal(deletion.status, 200);
  const outcome = await reimport;
  if (outcome.error) assert.equal(outcome.error.code, 'study_deleted');
  else assert.equal(outcome.value.imported, false);
  assert.equal((await x.request(`/v2/reconstruction-studies/${study.id}`, x.user.token)).status, 404);
  await assert.rejects(x.import(), { code: 'study_deleted' });
  assert.deepEqual(await readdir(path.join(x.dataDir, 'reconstruction-studies')), []);
});
