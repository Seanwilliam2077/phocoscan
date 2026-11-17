import test from 'node:test';
import http from 'node:http';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, readFile, writeFile, readdir } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { createServer } from '../src/server.mjs';
import { runBridgeOnce } from '../src/worldmirror-bridge.mjs';
import { openVideoReconstructionRepository, NATIVE_DUAL_CONSENT, NATIVE_ARKIT_PRIOR_CONSENT } from '../src/video-reconstructions.mjs';
import { buildPack } from './keyframe-fixtures.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const box = (name, payload) => {
  const header = Buffer.alloc(8);
  header.writeUInt32BE(payload.length + 8);
  header.write(name, 4);
  return Buffer.concat([header, payload]);
};
// Container-only fixture: these bytes do not prove an iPhone video can decode.
const video = Buffer.concat([box('ftyp', Buffer.from('qt  \0\0\0\0')),
  box('moov', Buffer.from('SYNTHETIC_TEST')), box('mdat', Buffer.from('SYNTHETIC_TEST'))]);
const identity = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]];
const intrinsic = [[1000, 0, 960], [0, 1000, 540], [0, 0, 1]];

function fixture(id, { depth = false, badTime = false, missingConfidence = false, count = 2 } = {}) {
  const frames = [...Array(count).keys()].map(index => ({
    index, arTimestampSeconds: 100 + (badTime ? 0 : index / 30),
    videoPTSSeconds: index / 30, rgbWidth: 1920, rgbHeight: 1080,
    cameraImageWidth: 1920, cameraImageHeight: 1080,
    cameraToWorldARKit: identity, intrinsicsPixels: intrinsic, trackingState: 'normal',
    depth: depth ? { file: `depth/frame-${String(index).padStart(6, '0')}.f32`, width: 256, height: 192, pixelFormat: 'float32_le_meters', sha256: sha(Buffer.from(`depth${index}`)) } : null,
    confidence: depth && !(missingConfidence && index === 1) ? { file: `confidence/frame-${String(index).padStart(6, '0')}.u8`, width: 256, height: 192, pixelFormat: 'uint8_arkit_confidence', sha256: sha(Buffer.from(`confidence${index}`)) } : null,
  }));
  const framesJSONL = frames.map(frame => JSON.stringify(frame)).join('\n') + '\n';
  const manifest = { schemaVersion: 1, captureID: id,
    createdAtUTC: '2026-11-02T00:00:00.000Z', completedAtUTC: '2026-11-02T00:00:01.000Z',
    stopReason: 'user', videoFile: 'video.mov', framesFile: 'frames.jsonl',
    videoSHA256: sha(video), framesSHA256: sha(Buffer.from(framesJSONL)),
    frameCount: frames.length, skippedFrameCount: 0, depthFrameCount: depth ? 2 : 0,
    rgbWidth: 1920, rgbHeight: 1080, depthSupported: depth,
    coordinateConvention: 'ARKit camera-to-world, nominal meters',
    videoOrientation: 'sensor orientation', audioPolicy: 'no audio track' };
  return Buffer.from(JSON.stringify({ manifest, framesJSONL }));
}

async function harness(t, options = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), 'pocketworld-v2-'));
  const adminToken = randomBytes(32).toString('base64url');
  let server;
  const h = { directory, adminToken };
  const start = async () => {
    server = createServer({ dataDir: path.join(directory, 'data'), adminToken, ...options });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    h.base = `http://127.0.0.1:${server.address().port}`;
  };
  const stop = async () => {
    if (!server) return;
    await new Promise(resolve => { server.close(resolve); server.closeIdleConnections(); });
    server.closeDatabase(); server = null;
  };
  h.restart = async () => { await stop(); await start(); };
  h.request = async (route, { token, method = 'GET', body, bytes, type, headers = {} } = {}) => {
    const options = { method, headers: { ...headers } };
    if (token) options.headers.Authorization = `Bearer ${token}`;
    if (body !== undefined) { options.body = JSON.stringify(body); options.headers['Content-Type'] = 'application/json'; }
    if (bytes !== undefined) { options.body = bytes; options.headers['Content-Type'] = type ?? 'application/octet-stream'; }
    const response = await fetch(h.base + route, options);
    const contentType = response.headers.get('content-type') ?? '';
    return { status: response.status, headers: response.headers,
      data: contentType.includes('application/json') ? await response.json() : Buffer.from(await response.arrayBuffer()) };
  };
  h.register = async () => {
    const response = await h.request('/v1/auth/anonymous', { method: 'POST', body: {} });
    assert.equal(response.status, 201);
    return response.data.token;
  };
  h.create = async (token, id = randomUUID()) => {
    const body = { captureId: id, environment: 'indoor', consentVersion: 'research-preview-v1' };
    const response = await h.request('/v2/captures', { token, method: 'POST', body });
    assert.equal(response.status, 201, JSON.stringify(response.data));
    return { id, body };
  };
  h.upload = async (token, id, action, bytes, type) => h.request(`/v2/captures/${id}/${action}`, {
    token, method: 'PUT', bytes, type, headers: { 'X-Content-SHA256': sha(bytes) },
  });
  await start();
  t.after(async () => { await stop(); await rm(directory, { recursive: true, force: true }); });
  return h;
}

test('v2 immutable RGB/pose capture receives one scoped receipt and survives restart', async t => {
  const h = await harness(t), token = await h.register();
  const { id, body } = await h.create(token);
  assert.equal((await h.request(`/v2/captures/${id}/complete`, { token, method: 'POST', body: {} })).status, 409);
  assert.equal((await h.upload(token, id, 'rgb', video, 'video/quicktime')).status, 200);
  const metadata = fixture(id);
  assert.equal((await h.upload(token, id, 'metadata', metadata, 'application/json')).status, 200);
  const first = await h.request(`/v2/captures/${id}/complete`, { token, method: 'POST', body: {} });
  assert.equal(first.status, 200, JSON.stringify(first.data));
  assert.equal(first.data.capture.status, 'rgb_metadata_verified');
  assert.equal(first.data.capture.receipt.scope, 'rgb_metadata_verified');
  assert.equal(first.data.capture.receipt.depthStatus, 'not_captured');
  assert.equal(first.data.capture.receipt.frameCount, 2);
  assert.equal(first.data.capture.receipt.decodeVerified, false);
  assert.ok(first.data.capture.receipt.captureReceiptId);
  const retry = await h.request(`/v2/captures/${id}/complete`, { token, method: 'POST', body: {} });
  assert.equal(retry.data.capture.receipt.captureReceiptId, first.data.capture.receipt.captureReceiptId);
  assert.equal((await h.request('/v2/captures', { token })).data.captures.length, 1);
  assert.equal((await h.request('/v2/captures', { token, method: 'POST', body })).status, 200);
  const downloaded = await h.request(`/v2/captures/${id}/rgb`, { token });
  assert.equal(downloaded.status, 200);
  assert.deepEqual(downloaded.data, video);
  assert.equal(downloaded.headers.get('x-content-sha256'), sha(video));
  assert.deepEqual((await h.request(`/v2/captures/${id}/metadata`, { token })).data, JSON.parse(metadata));
  await h.restart();
  const after = await h.request(`/v2/captures/${id}`, { token });
  assert.equal(after.data.capture.receipt.captureReceiptId, first.data.capture.receipt.captureReceiptId);
  assert.deepEqual(await readFile(path.join(h.directory, 'data', 'captures-v2', id, 'video.mov')), video);
  await rm(path.join(h.directory, 'data', 'captures-v2', id, 'video.mov'));
  assert.equal((await h.request(`/v2/captures/${id}/complete`, { token, method: 'POST', body: {} })).data.error.code, 'stored_file_mismatch');
  assert.equal((await h.upload(token, id, 'rgb', video, 'video/quicktime')).status, 200);
  assert.equal((await h.request(`/v2/captures/${id}/complete`, { token, method: 'POST', body: {} })).data.capture.receipt.captureReceiptId, first.data.capture.receipt.captureReceiptId);
});

test('v2 upload integrity, immutable bytes and metadata timeline are enforced', async t => {
  const h = await harness(t), token = await h.register();
  const { id } = await h.create(token);
  const wrongHash = await h.request(`/v2/captures/${id}/rgb`, { token, method: 'PUT', bytes: video,
    type: 'video/quicktime', headers: { 'X-Content-SHA256': '0'.repeat(64) } });
  assert.equal(wrongHash.status, 422);
  assert.equal(wrongHash.data.error.code, 'hash_mismatch');
  assert.equal((await h.upload(token, id, 'rgb', video, 'video/quicktime')).status, 200);
  assert.equal((await h.upload(token, id, 'rgb', video, 'video/quicktime')).status, 200);
  const differentVideo = Buffer.concat([video, box('free', Buffer.from('different'))]);
  assert.equal((await h.upload(token, id, 'rgb', differentVideo, 'video/quicktime')).data.error.code, 'rgb_conflict');
  const malformed = fixture(id, { badTime: true });
  const rejected = await h.upload(token, id, 'metadata', malformed, 'application/json');
  assert.equal(rejected.status, 422);
  assert.equal(rejected.data.error.code, 'invalid_frame_time');
  assert.equal((await h.request(`/v2/captures/${id}`, { token })).data.capture.metadata, null);
  const valid = fixture(id);
  assert.equal((await h.upload(token, id, 'metadata', valid, 'application/json')).status, 200);
  const other = Buffer.from(valid.toString().replace('sensor orientation', 'different orientation'));
  assert.equal((await h.upload(token, id, 'metadata', other, 'application/json')).data.error.code, 'metadata_conflict');
  const second = await h.create(token);
  assert.equal((await h.upload(token, second.id, 'metadata', fixture(second.id), 'application/json')).status, 200);
  assert.equal((await h.upload(token, second.id, 'rgb', differentVideo, 'video/quicktime')).data.error.code, 'video_manifest_mismatch');
  assert.equal((await h.request(`/v2/captures/${second.id}`, { token })).data.capture.rgb, null);
  assert.equal((await h.upload(token, second.id, 'rgb', video, 'video/quicktime')).status, 200);
});

test('v2 LiDAR references remain explicitly pending while RGB/pose receipt is real', async t => {
  const h = await harness(t), token = await h.register();
  const { id } = await h.create(token);
  assert.equal((await h.upload(token, id, 'metadata', fixture(id, { depth: true, missingConfidence: true }), 'application/json')).status, 200);
  assert.equal((await h.upload(token, id, 'rgb', video, 'video/quicktime')).status, 200);
  const complete = await h.request(`/v2/captures/${id}/complete`, { token, method: 'POST', body: {} });
  assert.equal(complete.status, 200);
  assert.equal(complete.data.capture.receipt.depthFrameCount, 2);
  assert.equal(complete.data.capture.receipt.depthStatus, 'pending_upload');
  assert.equal(complete.data.capture.receipt.scope, 'rgb_metadata_verified');
});

test('v2 capture ownership, deletion and tombstone do not affect v1', async t => {
  const h = await harness(t), alice = await h.register(), bob = await h.register();
  const { id, body } = await h.create(alice);
  for (const [route, method, options] of [
    [`/v2/captures/${id}`, 'GET', {}],
    [`/v2/captures/${id}/rgb`, 'GET', {}],
    [`/v2/captures/${id}/metadata`, 'GET', {}],
    [`/v2/captures/${id}/rgb`, 'PUT', { bytes: video, type: 'video/quicktime', headers: { 'X-Content-SHA256': sha(video) } }],
    [`/v2/captures/${id}/complete`, 'POST', { body: {} }],
    [`/v2/captures/${id}`, 'DELETE', {}],
  ]) assert.equal((await h.request(route, { token: bob, method, ...options })).status, 404);
  assert.equal((await h.request('/v2/captures', { token: bob })).data.captures.length, 0);
  assert.equal((await h.request(`/v2/captures/${id}`, { token: alice, method: 'DELETE' })).status, 200);
  assert.equal((await h.request(`/v2/captures/${id}`, { token: alice, method: 'DELETE' })).status, 200);
  assert.equal((await h.request(`/v2/captures/${id}`, { token: alice })).status, 404);
  assert.equal((await h.request('/v2/captures', { token: alice, method: 'POST', body })).data.error.code, 'capture_deleted');
  assert.equal((await h.request('/health')).data.ok, true);
  assert.equal((await h.request('/v1/sessions', { token: alice })).status, 200);
});

test('verified v2 capture queues one owned FF job, exposes only real ready result, and deletion clears the linked viewer', async t => {
  const h = await harness(t), alice = await h.register(), bob = await h.register();
  const { id } = await h.create(alice), ffPath = `/v2/captures/${id}/ff`;
  assert.deepEqual((await h.request(ffPath, { token: alice })).data, { ff: null });
  assert.equal((await h.request(ffPath, { token: alice, method: 'POST', body: {} })).data.error.code, 'capture_incomplete');
  assert.equal((await h.request(ffPath, { token: bob })).status, 404);
  assert.equal((await h.request(ffPath, { token: bob, method: 'POST', body: {} })).status, 404);
  await h.upload(alice, id, 'rgb', video, 'video/quicktime');
  const metadata = fixture(id);
  await h.upload(alice, id, 'metadata', metadata, 'application/json');
  await h.request(`/v2/captures/${id}/complete`, { token: alice, method: 'POST', body: {} });
  const queued = await h.request(ffPath, { token: alice, method: 'POST', body: {} });
  assert.equal(queued.status, 201);
  assert.equal(queued.data.ff.status, 'queued');
  assert.equal(queued.data.ff.captureId, id);
  assert.equal(queued.data.ff.assetId, undefined);
  const jobId = queued.data.ff.jobId;
  assert.equal((await h.request(ffPath, { token: alice, method: 'POST', body: {} })).status, 200);
  assert.equal((await h.request(ffPath, { token: alice })).data.ff.jobId, jobId);
  await h.restart();
  assert.equal((await h.request(ffPath, { token: alice })).data.ff.jobId, jobId);
  assert.deepEqual((await h.request('/v1/sessions', { token: alice })).data.sessions, []);
  const jobs = (await h.request('/v1/admin/jobs', { token: h.adminToken })).data.jobs;
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].job.id, jobId);
  assert.equal(jobs[0].session.linkedCaptureId, id);
  assert.equal(jobs[0].session.provenance, 'device_capture_v2_verified');
  assert.equal(jobs[0].session.videoDurationSeconds, 1 / 30);
  assert.equal(jobs[0].session.poseSource, 'arkit_device_reported');
  const linkedSessionId = jobs[0].session.id;
  assert.equal((await h.request(`/v1/sessions/${linkedSessionId}`, { token: bob })).status, 404);
  assert.equal((await h.request(`/v1/sessions/${linkedSessionId}`, { token: alice, method: 'DELETE' })).status, 409);
  assert.equal((await h.request(`/v1/sessions/${linkedSessionId}/reward`, { token: alice, method: 'POST', body: {} })).status, 409);
  const bundle = (await h.request(`/v1/admin/sessions/${linkedSessionId}/bundle`, { token: h.adminToken })).data;
  assert.equal(bundle.manifest.linkedCaptureMetadataSHA256, sha(metadata));
  assert.equal(bundle.files[0].sha256, sha(video));
  assert.deepEqual((await h.request(`/v1/admin/sessions/${linkedSessionId}/video`, { token: h.adminToken })).data, video);
  assert.equal((await h.request(`/v1/admin/jobs/${jobId}/status`, { token: h.adminToken, method: 'PUT', body: { status: 'processing', expectedStatus: 'queued' } })).status, 409);
  await h.request(`/v1/admin/jobs/${jobId}/status`, { token: h.adminToken, method: 'PUT', body: { status: 'processing', expectedStatus: 'queued', workerClaimId: randomUUID() } });
  assert.equal((await h.request(ffPath, { token: alice })).data.ff.status, 'processing');
  const properties = ['x', 'y', 'z', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3'];
  const ply = Buffer.from('ply\nformat ascii 1.0\nelement vertex 1\n' + properties.map(p => `property float ${p}`).join('\n') + '\nend_header\n0 0 1 0.3 0.2 0.1 2 -3 -3 -3 1 0 0 0\n');
  const imported = await h.request(`/v1/admin/jobs/${jobId}/asset?format=ply&tool=WorldMirror2`, { token: h.adminToken, method: 'PUT', bytes: ply });
  assert.equal(imported.status, 200, JSON.stringify(imported.data));
  const ready = (await h.request(ffPath, { token: alice })).data.ff;
  assert.equal(ready.status, 'ready');
  assert.ok(ready.viewerInfoPath.startsWith('/v1/assets/'));
  assert.ok(ready.viewerPath.startsWith('/v1/assets/'));
  assert.equal((await h.request(ready.viewerPath, { token: bob })).status, 404);
  const info = await h.request(ready.viewerInfoPath, { token: alice });
  const scene = await h.request(ready.viewerPath, { token: alice });
  assert.equal(info.status, 200);
  assert.equal(scene.status, 200);
  assert.equal(info.data.sha256, sha(scene.data));
  assert.equal(info.data.byteSize, scene.data.length);
  assert.equal(info.data.pointCount, 1);
  assert.equal((await h.request(`/v2/captures/${id}`, { token: alice, method: 'DELETE' })).status, 200);
  assert.equal((await h.request(ffPath, { token: alice })).status, 404);
  assert.equal((await h.request(ready.viewerPath, { token: alice })).status, 404);
  assert.deepEqual((await h.request('/v1/admin/jobs', { token: h.adminToken })).data.jobs, []);
  assert.equal((await h.request(`/v2/captures/${id}`, { token: alice, method: 'DELETE' })).status, 200);
});

test('existing WorldMirror worker selects linked v2 FF job and stops after source deletion', async t => {
  const h = await harness(t), token = await h.register();
  const { id } = await h.create(token);
  await h.upload(token, id, 'rgb', video, 'video/quicktime');
  await h.upload(token, id, 'metadata', fixture(id), 'application/json');
  await h.request(`/v2/captures/${id}/complete`, { token, method: 'POST', body: {} });
  const queued = await h.request(`/v2/captures/${id}/ff`, { token, method: 'POST', body: {} });
  const options = { backendOrigin: h.base, providerOrigin: 'http://synthetic-provider.invalid', adminToken: h.adminToken,
    workDir: path.join(h.directory, 'worker'), frameCount: 8, ffmpegPath: path.join(h.directory, 'unused-ffmpeg.exe') };
  const jpeg = Buffer.from([255, 216, 255, 224, 1, 2, 3, 255, 217]);
  const extractFrames = async ({ outputDirectory, frameCount }) => {
    await mkdir(outputDirectory);
    const files = [];
    for (let index = 1; index <= frameCount; index++) {
      const name = `frame-${String(index).padStart(3, '0')}.jpg`;
      await writeFile(path.join(outputDirectory, name), jpeg);
      files.push({ name, size: jpeg.length, sha256: sha(jpeg) });
    }
    return { files, method: 'synthetic_test_fixture' };
  };
  const providerWorkflow = {
    uploadRun: async () => ({ phase: 'images_uploaded', groupId: 'synthetic-group', imagesAssetId: 'synthetic-images' }),
    quickRun: async () => ({ phase: 'submitted', groupId: 'synthetic-group', imagesAssetId: 'synthetic-images', projectId: 'synthetic-project', stepId: 'synthetic-step' }),
    resumeRun: async () => ({ phase: 'submitted' }),
    runSummary: state => state,
  };
  const deps = { providerClient: { origin: options.providerOrigin }, providerWorkflow, extractFrames };
  const first = await runBridgeOnce(options, deps);
  assert.equal(first.phase, 'provider_processing');
  assert.equal(first.jobId, queued.data.ff.jobId);
  assert.equal((await h.request(`/v2/captures/${id}/ff`, { token })).data.ff.status, 'processing');
  await h.request(`/v2/captures/${id}`, { token, method: 'DELETE' });
  const after = await runBridgeOnce(options, { ...deps, jobId: queued.data.ff.jobId });
  assert.equal(after.phase, 'cancelled');
});

async function nativeDualFixture(t,{depth=false,options={}}={}) {
  const h=await harness(t,options),token=await h.register(),other=await h.register(),created=await h.create(token),id=created.id;
  const metadata=fixture(id,{depth}),base=`/v2/captures/${id}`,dual=base+'/reconstructions';
  await h.upload(token,id,'rgb',video,'video/quicktime');await h.upload(token,id,'metadata',metadata,'application/json');
  const completed=await h.request(base+'/complete',{token,method:'POST',body:{}});
  assert.equal(completed.status,200);
  return {h,token,other,id,base,dual,metadata,creation:created.body,receipt:completed.data.capture.receipt,
    dataDir:path.join(h.directory,'data'),enqueue:()=>h.request(dual,{token,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT}})};
}
async function nativeTestResult(directory) {
  // Synthetic Gaussian and camera fixtures; never actual phone/render evidence.
  const splat=Buffer.alloc(32,128);[0,0,1,.1,.1,.1].forEach((v,i)=>splat.writeFloatLE(v,i*4));splat[28]=255;
  const cameras={version:1,coordinateSystem:'opengl_camera_to_world',matrixLayout:'row-major',scale:'unknown',frames:[
    {sourceFrame:'SYNTHETIC_TEST.jpg',timeSeconds:0,width:100,height:100,fx:80,fy:80,cx:50,cy:50,cameraToWorld:identity.flat()}]};
  const modelFile=path.join(directory,'TEST_ONLY.splat'),cameraFile=path.join(directory,'TEST_ONLY.cameras.json');
  await writeFile(modelFile,splat);await writeFile(cameraFile,JSON.stringify(cameras));
  return {modelFile,cameraFile,provenance:{sourceVideoSha256:sha(video),projectId:'TEST_PROJECT',stepId:'TEST_STEP',testFixture:true}};
}

test('native dual requires verified metadata and new consent; concurrent creation preserves one receipt and two durable jobs',async t=>{
  const h=await harness(t),token=await h.register(),other=await h.register(),{id}=await h.create(token),base=`/v2/captures/${id}`,route=base+'/reconstructions';
  assert.deepEqual((await h.request(route,{token})).data,{reconstruction:null});
  assert.equal((await h.request(route,{token,method:'POST',body:{}})).data.error.code,'native_dual_consent_required');
  assert.equal((await h.request(route,{token,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT}})).data.error.code,'capture_incomplete');
  for(const method of ['GET','POST']) {
    assert.equal((await h.request(route,{method,...(method==='POST'?{body:{consentVersion:NATIVE_DUAL_CONSENT}}:{})})).status,401);
    assert.equal((await h.request(route,{token:other,method,...(method==='POST'?{body:{consentVersion:NATIVE_DUAL_CONSENT}}:{})})).status,404);
  }
  const metadata=fixture(id,{depth:true});
  await h.upload(token,id,'rgb',video,'video/quicktime');await h.upload(token,id,'metadata',metadata,'application/json');
  const complete=await h.request(base+'/complete',{token,method:'POST',body:{}});
  const responses=await Promise.all([0,1].map(()=>h.request(route,{token,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT}})));
  assert.deepEqual(responses.map(r=>r.status).sort(),[200,201]);
  const r=responses[0].data.reconstruction;
  assert.deepEqual(responses[1].data.reconstruction,r);assert.equal(r.tasks.length,2);assert.equal(r.sourceKind,'native_arkit_capture');
  assert.equal(r.captureId,id);assert.equal(r.captureReceiptId,complete.data.capture.receipt.captureReceiptId);
  assert.equal(r.sourceVideoSha256,sha(video));assert.equal(r.sourceMetadataSha256,sha(metadata));assert.equal(r.sourceMetadataByteSize,metadata.length);
  let repository=openVideoReconstructionRepository({dataDir:path.join(h.directory,'data')});
  try {
    assert.equal(repository.pendingJobs().length,2);
    const task=repository.claim(r.tasks[0].id,'SYNTHETIC_TEST_WORKER'),source=repository.source(task.id,task.claimId);
    assert.equal(source.sourceKind,'native_arkit_capture');assert.equal(source.captureId,id);assert.equal(source.captureReceiptId,r.captureReceiptId);
    assert.equal(source.sourceVideoPath,path.join(h.directory,'data','captures-v2',id,'video.mov'));
    assert.deepEqual(await readFile(source.sourceMetadataPath),metadata);assert.equal(source.nativeCaptureValidation.depthStatus,'pending_upload');
    assert.equal(source.nativeCaptureValidation.decodeVerified,false);
    assert.deepEqual(await readdir(path.join(h.directory,'data','video-reconstructions',r.id)),[]);
  }finally{repository.close();}
  await h.upload(token,id,'rgb',video,'video/quicktime');await h.upload(token,id,'metadata',metadata,'application/json');
  assert.equal((await h.request(base+'/complete',{token,method:'POST',body:{}})).data.capture.receipt.captureReceiptId,r.captureReceiptId);
  await h.restart();
  const resumed=(await h.request(route,{token,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT}})).data.reconstruction;
  assert.deepEqual(resumed.tasks.map(j=>j.id),r.tasks.map(j=>j.id));assert.equal(resumed.captureReceiptId,r.captureReceiptId);
  assert.equal((await h.request('/v2/captures',{token})).data.captures.length,1);
  assert.deepEqual((await h.request('/v1/sessions',{token})).data.sessions,[]);
  assert.deepEqual((await h.request('/v1/admin/jobs',{token:h.adminToken})).data.jobs,[]);
});

test('native dual publishes independent private results with immutable metadata lineage and retries only failed branch',async t=>{
  const x=await nativeDualFixture(t),r=(await x.enqueue()).data.reconstruction,repo=openVideoReconstructionRepository({dataDir:x.dataDir});
  try {
    const ff=repo.claim(r.tasks.find(j=>j.role==='preview').id,'test'),sfm=repo.claim(r.tasks.find(j=>j.role==='refined').id,'test'),asset=await nativeTestResult(x.h.directory);
    await assert.rejects(repo.publish(ff.id,ff.claimId,{...asset,provenance:{...asset.provenance,sourceKind:'external_rgb_video'}}),{code:'result_provenance_mismatch'});
    await assert.rejects(repo.publish(ff.id,ff.claimId,{...asset,provenance:{...asset.provenance,sourceMetadataSha256:'f'.repeat(64)}}),{code:'result_provenance_mismatch'});
    const result=await repo.publish(ff.id,ff.claimId,asset);
    assert.equal((await x.h.request(x.dual,{token:x.token})).data.reconstruction.status,'partial');
    assert.equal((await x.h.request(result.filePath,{token:x.other})).status,404);
    assert.equal((await x.h.request(result.cameraPath,{token:x.other})).status,404);
    assert.equal((await x.h.request(result.filePath,{token:x.token})).headers.get('x-content-sha256'),result.sha256);
    const published=(await readdir(path.join(x.dataDir,'video-reconstructions',r.id))).find(n=>n.startsWith('result-'));
    const provenance=JSON.parse(await readFile(path.join(x.dataDir,'video-reconstructions',r.id,published,'provenance.json'),'utf8'));
    assert.equal(provenance.sourceKind,'native_arkit_capture');assert.equal(provenance.captureId,x.id);
    assert.equal(provenance.sourceMetadataSha256,sha(x.metadata));assert.equal(provenance.captureReceiptId,x.receipt.captureReceiptId);
    assert.equal(provenance.nativeCaptureValidation.poseSource,'arkit_device_reported');assert.equal(provenance.nativeCaptureValidation.decodeVerified,false);
    repo.setPhase(sfm.id,sfm.claimId,'failed','provider_failed',{code:'test_failure',message:'SYNTHETIC_TEST_ONLY'});
    const retryId=randomUUID(),retry=await x.h.request(`/v2/video-reconstructions/${r.id}/retry`,{token:x.token,method:'POST',body:{failedTaskId:sfm.id,id:retryId}});
    assert.equal(retry.status,200);assert.equal(retry.data.reconstruction.tasks.find(j=>j.role==='preview').result.sha256,result.sha256);
    const source=repo.source(retryId);assert.equal(source.captureId,x.id);assert.equal(source.sourceMetadataSha256,sha(x.metadata));
    assert.equal((await x.h.request(x.base+'/complete',{token:x.token,method:'POST',body:{}})).data.capture.receipt.captureReceiptId,x.receipt.captureReceiptId);
    assert.equal((await x.h.request(`/v2/video-reconstructions/${r.id}/video`,{token:x.token,method:'PUT',bytes:video,type:'video/quicktime'})).data.error.code,'native_source_immutable');
    assert.equal((await x.h.request(`/v2/video-reconstructions/${r.id}`,{token:x.token,method:'DELETE'})).data.error.code,'native_capture_delete_required');
  }finally{repo.close();}
});

test('native dual rejects changed original metadata before enqueue and before publication',async t=>{
  const x=await nativeDualFixture(t),metadataFile=path.join(x.dataDir,'captures-v2',x.id,'metadata.json');
  await writeFile(metadataFile,Buffer.from(x.metadata.toString().replace('sensor orientation','TAMPERED')));
  assert.equal((await x.enqueue()).data.error.code,'native_source_changed');
  assert.equal((await x.h.request(x.dual,{token:x.token})).data.reconstruction,null);
  await x.h.upload(x.token,x.id,'metadata',x.metadata,'application/json');
  const r=(await x.enqueue()).data.reconstruction,repo=openVideoReconstructionRepository({dataDir:x.dataDir});
  try {
    const ff=repo.claim(r.tasks.find(j=>j.role==='preview').id,'test'),asset=await nativeTestResult(x.h.directory);
    await writeFile(metadataFile,'changed after enqueue');
    await assert.rejects(repo.publish(ff.id,ff.claimId,asset),{code:'native_source_changed'});
    assert.equal((await x.h.request(x.dual,{token:x.token})).data.reconstruction.tasks.find(j=>j.role==='preview').result,undefined);
    await x.h.upload(x.token,x.id,'metadata',x.metadata,'application/json');
    const db=new DatabaseSync(path.join(x.dataDir,'pocketworld.sqlite'));
    try {db.prepare('UPDATE captures_v2 SET metadataHash = ? WHERE id = ?').run('f'.repeat(64),x.id);
      assert.throws(()=>repo.source(ff.id,ff.claimId),{code:'native_source_changed'});
      db.prepare('UPDATE captures_v2 SET metadataHash = ? WHERE id = ?').run(sha(x.metadata),x.id);
    }finally{db.close();}
    assert.equal(repo.pendingJobs().length,2);
  }finally{repo.close();}
});

test('native deletion cascades both dual and legacy FF jobs and prevents late publication or receipt replay',async t=>{
  const x=await nativeDualFixture(t),r=(await x.enqueue()).data.reconstruction,repo=openVideoReconstructionRepository({dataDir:x.dataDir});
  try {
    assert.equal((await x.h.request(x.base+'/ff',{token:x.token,method:'POST',body:{}})).status,201);
    const ff=repo.claim(r.tasks.find(j=>j.role==='preview').id,'test'),asset=await nativeTestResult(x.h.directory);
    const ready=await repo.publish(ff.id,ff.claimId,asset),sfm=repo.claim(r.tasks.find(j=>j.role==='refined').id,'test');
    assert.equal((await x.h.request(x.base,{token:x.token,method:'DELETE'})).status,200);
    assert.equal(repo.pendingJobs().length,0);assert.throws(()=>repo.source(sfm.id,sfm.claimId),{code:'video_reconstruction_task_not_found'});
    await assert.rejects(repo.publish(ff.id,ff.claimId,asset),{code:'video_reconstruction_task_not_found'});
    assert.equal((await x.h.request(ready.filePath,{token:x.token})).status,404);
    assert.equal((await x.h.request(x.dual,{token:x.token})).status,404);assert.equal((await x.enqueue()).status,404);
    assert.deepEqual((await x.h.request('/v1/admin/jobs',{token:x.h.adminToken})).data.jobs,[]);
    assert.deepEqual(await readdir(path.join(x.dataDir,'captures-v2')),[]);assert.deepEqual(await readdir(path.join(x.dataDir,'video-reconstructions')),[]);
    assert.equal((await x.h.request('/v2/captures',{token:x.token,method:'POST',body:x.creation})).data.error.code,'capture_deleted');
    assert.equal((await x.h.request(x.base,{token:x.token,method:'DELETE'})).status,200);
  }finally{repo.close();}
});

test('ARKit pose cloud training is an optional, owned, idempotent third task that retries alone and publishes SH3',async t=>{
  const x=await nativeDualFixture(t),route=x.base+'/reconstructions/arkit-prior',taskId=randomUUID();
  const body={consentVersion:NATIVE_ARKIT_PRIOR_CONSENT,id:taskId};
  assert.equal((await x.h.request(route,{token:x.token,method:'POST',body})).data.error.code,'native_reconstruction_required');
  const dual=(await x.enqueue()).data.reconstruction;
  assert.equal((await x.h.request(route,{token:x.token,method:'POST',body:{id:taskId}})).data.error.code,'arkit_prior_consent_required');
  assert.equal((await x.h.request(route,{method:'POST',body})).status,401);
  assert.equal((await x.h.request(route,{token:x.other,method:'POST',body})).status,404);
  assert.equal((await x.h.request(route,{token:x.token})).status,405);

  const first=await x.h.request(route,{token:x.token,method:'POST',body});
  assert.equal(first.status,201);
  const arkit=first.data.reconstruction.tasks.find(j=>j.role==='arkit');
  assert.equal(arkit.id,taskId);assert.equal(arkit.algorithm,'gs_mcmc_arkit_prior');assert.equal(arkit.status,'queued');
  // Idempotent per reconstruction; the FF and SfM tasks are untouched.
  const again=await x.h.request(route,{token:x.token,method:'POST',body:{...body,id:randomUUID()}});
  assert.equal(again.status,200);assert.equal(again.data.reconstruction.tasks.length,3);
  assert.deepEqual(again.data.reconstruction.tasks.filter(j=>j.role!=='arkit').map(j=>j.id).sort(),dual.tasks.map(j=>j.id).sort());

  const repo=openVideoReconstructionRepository({dataDir:x.dataDir});
  try {
    let task=repo.claim(taskId,'SYNTHETIC_TEST_WORKER');
    const source=repo.source(task.id,task.claimId);
    assert.equal(source.algorithm,'gs_mcmc_arkit_prior');assert.equal(source.nativeCaptureValidation.poseSource,'arkit_device_reported');
    repo.setPhase(task.id,task.claimId,'failed','provider_failed',{code:'test_failure',message:'SYNTHETIC_TEST_ONLY'});
    const retryId=randomUUID();
    const retried=await x.h.request(`/v2/video-reconstructions/${dual.id}/retry`,{token:x.token,method:'POST',body:{failedTaskId:taskId,id:retryId}});
    assert.equal(retried.status,200);
    const replacement=retried.data.reconstruction.tasks.find(j=>j.role==='arkit');
    assert.equal(replacement.id,retryId);assert.equal(replacement.algorithm,'gs_mcmc_arkit_prior');
    assert.equal(retried.data.reconstruction.previousAttempts.length,1);

    // Publication keeps the full SH3 PLY (synthetic one-splat fixture).
    task=repo.claim(retryId,'SYNTHETIC_TEST_WORKER');
    const props=['x','y','z','f_dc_0','f_dc_1','f_dc_2',...Array.from({length:45},(_,i)=>`f_rest_${i}`),'opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3'];
    const values=props.map(n=>n==='z'||n==='rot_0'?1:n.startsWith('scale_')?-3:0);
    const plyFile=path.join(x.h.directory,'TEST_ONLY_SH3.ply');
    await writeFile(plyFile,`ply\nformat ascii 1.0\ncomment SYNTHETIC TEST ONLY\nelement vertex 1\n${props.map(n=>`property float ${n}`).join('\n')}\nend_header\n${values.join(' ')}\n`);
    const asset=await nativeTestResult(x.h.directory);
    const result=await repo.publish(task.id,task.claimId,{...asset,modelFile:plyFile});
    assert.equal(result.role,'arkit');assert.equal(result.format,'ply');assert.equal(result.shDegree,3);
    assert.equal((await x.h.request(result.filePath,{token:x.other})).status,404);
  } finally { repo.close(); }
});

test('version selection starts only the chosen versions, adds the rest later, and lets the ARKit branch run alone',async t=>{
  const x=await nativeDualFixture(t),post=roles=>x.h.request(x.dual,{token:x.token,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT,roles}});
  for(const roles of ['preview',['arkit'],['preview','preview'],['preview','refined','preview'],[1]])
    assert.equal((await post(roles)).data.error.code,'invalid_reconstruction_roles');
  assert.deepEqual((await x.h.request(x.dual,{token:x.token})).data,{reconstruction:null});

  // One version only: one durable job, nothing for the other algorithm.
  const first=await post(['refined']);
  assert.equal(first.status,201);
  const r=first.data.reconstruction;
  assert.deepEqual(r.tasks.map(j=>[j.role,j.algorithm,j.status]),[['refined','gs_mcmc','queued']]);assert.equal(r.status,'queued');
  let repo=openVideoReconstructionRepository({dataDir:x.dataDir});
  try { assert.deepEqual(repo.pendingJobs().map(j=>j.role),['refined']); } finally { repo.close(); }
  // Repeating the choice, an empty list or the original request without roles adds nothing.
  for(const roles of [['refined'],[],undefined]) {
    const again=await post(roles);
    assert.equal(again.status,200);assert.deepEqual(again.data.reconstruction.tasks.map(j=>j.id),[r.tasks[0].id]);
  }
  // The other version is added later; the first task is untouched.
  const second=await post(['preview','refined']);
  assert.equal(second.status,201);
  assert.deepEqual(second.data.reconstruction.tasks.map(j=>j.role),['preview','refined']);
  assert.equal(second.data.reconstruction.tasks.find(j=>j.role==='refined').id,r.tasks[0].id);
  assert.equal((await x.h.request(x.dual,{token:x.other,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT,roles:['preview']}})).status,404);

  // No version at all: the reconstruction exists idle, so the ARKit branch can run by itself.
  const y=await nativeDualFixture(t),open=await y.h.request(y.dual,{token:y.token,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT,roles:[]}});
  assert.equal(open.status,201);assert.deepEqual(open.data.reconstruction.tasks,[]);assert.equal(open.data.reconstruction.status,'idle');
  repo=openVideoReconstructionRepository({dataDir:y.dataDir});
  try { assert.deepEqual(repo.pendingJobs(),[]); } finally { repo.close(); }
  const arkit=await y.h.request(y.base+'/reconstructions/arkit-prior',{token:y.token,method:'POST',body:{consentVersion:NATIVE_ARKIT_PRIOR_CONSENT,id:randomUUID()}});
  assert.equal(arkit.status,201);assert.deepEqual(arkit.data.reconstruction.tasks.map(j=>j.role),['arkit']);
  // A failed single version retries alone, and asking for it again does not create a second task.
  repo=openVideoReconstructionRepository({dataDir:x.dataDir});
  try {
    const task=repo.claim(r.tasks[0].id,'SYNTHETIC_TEST_WORKER');
    repo.setPhase(task.id,task.claimId,'failed','provider_failed',{code:'test_failure',message:'SYNTHETIC_TEST_ONLY'});
  } finally { repo.close(); }
  const failed=await post(['refined']);
  assert.equal(failed.status,200);assert.equal(failed.data.reconstruction.tasks.find(j=>j.role==='refined').status,'failed');
});

// ---- Resumable original-video upload (synthetic container bytes; not a camera video) ----
const OFFSET_TYPE='application/offset+octet-stream';
/** Opens a PATCH that promises `total` bytes but sends only `bytes`; the caller ends or drops it. */
function partialPatch(h,id,token,offset,bytes,total){
  const request=http.request(new URL(`${h.base}/v2/captures/${id}/rgb-upload`),{method:'PATCH',headers:{
    Authorization:`Bearer ${token}`,'Content-Type':OFFSET_TYPE,'Upload-Offset':String(offset),'Content-Length':String(total)}});
  request.on('error',()=>{});request.write(bytes);return request;
}
async function waitForOffset(h,id,token,wanted){
  for(let i=0;i<200;i++){
    const r=await h.request(`/v2/captures/${id}/rgb-upload`,{token});
    if((r.data.upload?.offset??0)>=wanted)return r.data.upload.offset;
    await new Promise(resolve=>setTimeout(resolve,10));
  }
  throw new Error('offset did not advance');
}
const patch=(h,id,token,offset,bytes,headers={})=>h.request(`/v2/captures/${id}/rgb-upload`,{token,method:'PATCH',bytes,type:OFFSET_TYPE,headers:{'Upload-Offset':String(offset),...headers}});
const declare=(h,id,token,bytes=video,extra={})=>h.request(`/v2/captures/${id}/rgb-upload`,{token,method:'POST',body:{sha256:sha(bytes),byteSize:bytes.length,mime:'video/quicktime',...extra}});

test('resumable video upload keeps bytes across a dropped connection and then behaves exactly like a single PUT',async t=>{
  const h=await harness(t),token=await h.register(),{id}=await h.create(token),route=`/v2/captures/${id}/rgb-upload`;
  assert.deepEqual((await h.request(route,{token})).data,{upload:null});
  let r=await declare(h,id,token);assert.equal(r.status,200);assert.equal(r.data.upload.offset,0);assert.equal(r.data.upload.complete,false);

  // The phone loses its connection after 10 bytes: the server keeps them.
  const dropped=partialPatch(h,id,token,0,video.subarray(0,10),video.length);
  assert.equal(await waitForOffset(h,id,token,10),10);dropped.destroy();
  assert.equal((await declare(h,id,token)).data.upload.offset,10,'declaring again resumes, it does not restart');
  assert.equal((await patch(h,id,token,0,video.subarray(10))).data.error.code,'offset_mismatch');

  // A stalled request still holding the upload is pre-empted by the next one.
  const stalled=partialPatch(h,id,token,10,video.subarray(10,15),video.length-10);
  assert.equal(await waitForOffset(h,id,token,15),15);
  r=await patch(h,id,token,15,video.subarray(15));stalled.destroy();
  assert.equal(r.status,200,JSON.stringify(r.data));assert.equal(r.data.upload.complete,true);
  assert.equal(r.data.capture.rgb.sha256,sha(video));assert.equal(r.data.capture.rgb.byteSize,video.length);

  // Idempotent afterwards, and the rest of the capture flow is unchanged.
  r=await declare(h,id,token);assert.equal(r.data.upload.complete,true);assert.equal(r.data.capture.rgb.sha256,sha(video));
  assert.deepEqual((await h.request(`/v2/captures/${id}/rgb`,{token})).data,video);
  await h.upload(token,id,'metadata',fixture(id),'application/json');
  const done=await h.request(`/v2/captures/${id}/complete`,{token,method:'POST',body:{}});
  assert.equal(done.status,200);assert.ok(done.data.capture.receipt.captureReceiptId);
  assert.deepEqual(await readdir(path.join(h.directory,'data','captures-v2',id)).then(n=>n.filter(x=>x==='rgb-upload')),[]);
});

test('resumable upload refuses foreign users, wrong types, oversized bytes and a wrong final hash',async t=>{
  const h=await harness(t),token=await h.register(),other=await h.register(),{id}=await h.create(token),route=`/v2/captures/${id}/rgb-upload`;
  assert.equal((await declare(h,id,other)).status,404);
  assert.equal((await h.request(route,{method:'POST',body:{}})).status,401);
  assert.equal((await declare(h,id,token,video,{mime:'image/jpeg'})).data.error.code,'invalid_upload');
  assert.equal((await patch(h,id,token,0,video)).data.error.code,'upload_not_found');
  await declare(h,id,token);
  assert.equal((await h.request(route,{token,method:'PATCH',bytes:video,type:'application/octet-stream',headers:{'Upload-Offset':'0'}})).data.error.code,'content_type');
  assert.equal((await patch(h,id,token,0,Buffer.concat([video,Buffer.from('extra')]))).data.error.code,'file_too_large');
  // Declared hash differs from the bytes: the finished upload is discarded, nothing is stored.
  const wrong=Buffer.from(video);wrong[wrong.length-1]^=0xff;
  await h.request(route,{token,method:'POST',body:{sha256:sha(video),byteSize:video.length,mime:'video/quicktime'}});
  const r=await patch(h,id,token,0,wrong);
  assert.equal(r.status,422);assert.equal(r.data.error.code,'hash_mismatch');
  assert.deepEqual((await h.request(route,{token})).data,{upload:null});
  assert.equal((await h.request(`/v2/captures/${id}`,{token})).data.capture.rgb,null);
});

test('deleting a capture stops and removes an in-flight resumable upload',async t=>{
  const h=await harness(t),token=await h.register(),{id}=await h.create(token);
  await declare(h,id,token);
  const open=partialPatch(h,id,token,0,video.subarray(0,8),video.length);
  await waitForOffset(h,id,token,8);
  assert.equal((await h.request(`/v2/captures/${id}`,{token,method:'DELETE'})).status,200);
  open.destroy();
  assert.equal((await declare(h,id,token)).status,404);
  await assert.rejects(readdir(path.join(h.directory,'data','captures-v2',id)),{code:'ENOENT'});
});

// ---- Keyframe pack for the ARKit pose branch (synthetic pack bytes; not camera images) ----
test('a keyframe pack uploads resumably, is checked against the capture, binds ARKit training and is deleted with the capture',async t=>{
  const h=await harness(t),token=await h.register(),other=await h.register(),{id}=await h.create(token),base=`/v2/captures/${id}`,route=base+'/keyframes-upload';
  const metadata=fixture(id,{count:12});
  const records=JSON.parse(metadata).framesJSONL.trim().split('\n').map(line=>JSON.parse(line));
  const pack=buildPack(id,records.slice(0,10));
  const declared={sha256:sha(pack),byteSize:pack.length,mime:'application/x-pocketworld-keyframes'};
  assert.equal((await h.request(route,{token,method:'POST',body:declared})).data.error.code,'capture_incomplete');
  await h.upload(token,id,'rgb',video,'video/quicktime');await h.upload(token,id,'metadata',metadata,'application/json');
  assert.equal((await h.request(base+'/complete',{token,method:'POST',body:{}})).status,200);
  assert.equal((await h.request(route,{token:other,method:'POST',body:declared})).status,404);
  assert.equal((await h.request(route,{token,method:'POST',body:{...declared,mime:'video/quicktime'}})).status,422);
  let r=await h.request(route,{token,method:'POST',body:declared});assert.equal(r.data.upload.offset,0);
  const half=Math.floor(pack.length/2);
  r=await h.request(route,{token,method:'PATCH',bytes:pack.subarray(0,half),type:OFFSET_TYPE,headers:{'Upload-Offset':'0'}});
  assert.equal(r.data.upload.offset,half);
  r=await h.request(route,{token,method:'PATCH',bytes:pack.subarray(half),type:OFFSET_TYPE,headers:{'Upload-Offset':String(half)}});
  assert.equal(r.status,200,JSON.stringify(r.data));assert.equal(r.data.upload.complete,true);
  const summary={sha256:sha(pack),byteSize:pack.length,frameCount:10,masks:false,mode:'object'};
  assert.deepEqual(r.data.capture.keyframes,summary);
  assert.equal((await h.request(route,{token,method:'POST',body:declared})).data.upload.complete,true,'idempotent');
  const different=buildPack(id,records.slice(1,11));
  assert.equal((await h.request(route,{token,method:'POST',body:{...declared,sha256:sha(different),byteSize:different.length}})).data.error.code,'keyframes_conflict');
  assert.deepEqual((await h.request(base,{token})).data.capture.keyframes,summary);

  const dual=(await h.request(base+'/reconstructions',{token,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT}})).data.reconstruction;
  const arkitRoute=base+'/reconstructions/arkit-prior',taskId=randomUUID();
  assert.equal((await h.request(arkitRoute,{token,method:'POST',body:{consentVersion:NATIVE_ARKIT_PRIOR_CONSENT,id:taskId,keyframesSha256:'b'.repeat(64)}})).data.error.code,'keyframes_required');
  r=await h.request(arkitRoute,{token,method:'POST',body:{consentVersion:NATIVE_ARKIT_PRIOR_CONSENT,id:taskId,keyframesSha256:sha(pack)}});
  assert.equal(r.status,201,JSON.stringify(r.data));
  assert.deepEqual(r.data.reconstruction.tasks.find(j=>j.role==='arkit').input,{keyframes:summary});
  assert.equal(r.data.reconstruction.tasks.filter(j=>j.input).length,1,'FF and SfM keep the video frames');
  const repo=openVideoReconstructionRepository({dataDir:path.join(h.directory,'data')});
  try {
    const claimed=repo.claim(taskId,'SYNTHETIC_TEST_WORKER'),source=repo.source(claimed.id,claimed.claimId);
    assert.equal(source.keyframes.sha256,sha(pack));assert.equal(source.keyframes.frames.length,10);
    assert.equal((await readdir(path.join(source.keyframes.directory,'images'))).length,10);
    repo.setPhase(claimed.id,claimed.claimId,'failed','provider_failed',{code:'test_failure',message:'SYNTHETIC_TEST_ONLY'});
    const retryId=randomUUID();
    const retried=await h.request(`/v2/video-reconstructions/${dual.id}/retry`,{token,method:'POST',body:{failedTaskId:taskId,id:retryId}});
    assert.deepEqual(retried.data.reconstruction.tasks.find(j=>j.role==='arkit').input,{keyframes:summary},'a retry keeps the same pack');
  } finally { repo.close(); }
  await h.restart();
  assert.deepEqual((await h.request(base,{token})).data.capture.keyframes,summary);
  assert.equal((await h.request(base,{token,method:'DELETE'})).status,200);
  assert.deepEqual(await readdir(path.join(h.directory,'data','captures-v2')),[]);
});

test('a pack whose keyframes are not frames of the capture is rejected and nothing is stored',async t=>{
  const h=await harness(t),token=await h.register(),{id}=await h.create(token),base=`/v2/captures/${id}`,route=base+'/keyframes-upload';
  const metadata=fixture(id,{count:12});
  await h.upload(token,id,'rgb',video,'video/quicktime');await h.upload(token,id,'metadata',metadata,'application/json');
  await h.request(base+'/complete',{token,method:'POST',body:{}});
  const records=JSON.parse(metadata).framesJSONL.trim().split('\n').map(line=>JSON.parse(line));
  const pack=buildPack(id,records.slice(0,10),{edit:t=>{t.frames[5].transform_matrix[1][3]+=0.5;return t;}});
  await h.request(route,{token,method:'POST',body:{sha256:sha(pack),byteSize:pack.length,mime:'application/x-pocketworld-keyframes'}});
  const r=await h.request(route,{token,method:'PATCH',bytes:pack,type:OFFSET_TYPE,headers:{'Upload-Offset':'0'}});
  assert.equal(r.data.error.code,'keyframe_not_in_capture');
  assert.equal((await h.request(base,{token})).data.capture.keyframes,undefined);
  assert.deepEqual((await readdir(path.join(h.directory,'data','captures-v2',id))).filter(n=>n.startsWith('keyframes')),[]);
});


test('busy admission creates no GPU task, preserves idempotency and rejects retry without archiving',async t=>{
  let busy=true,calls=0;
  const {APIError}=await import('../src/validation.mjs');
  const f=await nativeDualFixture(t,{options:{gpuAdmission:async()=>{calls++;if(busy)throw new APIError(503,'server_busy','服务器繁忙中');}}});
  const {h,token,id,dual}=f;
  const body={consentVersion:NATIVE_DUAL_CONSENT,roles:['preview']};
  let response=await h.request(dual,{token,method:'POST',body});
  assert.equal(response.status,503);assert.equal(response.data.error.code,'server_busy');
  assert.equal((await h.request(dual,{token})).data.reconstruction,null);
  busy=false;response=await h.request(dual,{token,method:'POST',body});
  assert.equal(response.status,201);const rec=response.data.reconstruction;
  busy=true;const before=calls;
  assert.equal((await h.request(dual,{token,method:'POST',body})).status,200);assert.equal(calls,before);
  const prior=await h.request(dual+'/arkit-prior',{token,method:'POST',body:{consentVersion:NATIVE_ARKIT_PRIOR_CONSENT,id:randomUUID()}});
  assert.equal(prior.status,503);
  assert.equal((await h.request(dual,{token})).data.reconstruction.tasks.length,1);
  const db=new DatabaseSync(path.join(h.directory,'data','pocketworld.sqlite'));
  db.prepare("UPDATE video_reconstruction_tasks_v2 SET status='failed' WHERE id=?").run(rec.tasks[0].id);db.close();
  const retry=await h.request('/v2/video-reconstructions/'+rec.id+'/retry',{token,method:'POST',body:{failedTaskId:rec.tasks[0].id,id:randomUUID()}});
  assert.equal(retry.status,503);
  const after=(await h.request(dual,{token})).data.reconstruction;
  assert.equal(after.tasks[0].id,rec.tasks[0].id);assert.equal(after.previousAttempts.length,0);
});

test('individual keyframe files resume independently and commit the exact verified immutable pack',async t=>{
 const h=await harness(t),token=await h.register(),other=await h.register(),{id}=await h.create(token),base=`/v2/captures/${id}`;
 const metadata=fixture(id,{count:12}),records=JSON.parse(metadata).framesJSONL.trim().split('\n').map(JSON.parse),pack=buildPack(id,records.slice(0,10));
 await h.upload(token,id,'rgb',video,'video/quicktime');await h.upload(token,id,'metadata',metadata,'application/json');await h.request(base+'/complete',{token,method:'POST',body:{}});
 const raw=pack.subarray(12,12+pack.readUInt32LE(8)),index=JSON.parse(raw),route=base+'/keyframe-files';
 const declaration={sha256:sha(pack),byteSize:pack.length,indexBase64:raw.toString('base64')};
 assert.equal((await h.request(route,{token:other,method:'POST',body:declaration})).status,404);
 assert.equal((await h.request(route,{token,method:'POST',body:declaration})).status,200);
 assert.equal((await h.request(route+'/commit',{token,method:'POST',body:{}})).data.error.code,'file_missing');
 let offset=12+raw.length;
 for(const file of index.files){
  const url=route+'/files/'+file.sha256,bytes=pack.subarray(offset,offset+file.byteSize);offset+=file.byteSize;
  const body={sha256:file.sha256,byteSize:file.byteSize,mime:'application/octet-stream'};
  assert.equal((await h.request(url,{token,method:'POST',body})).data.upload.offset,0);
  const cut=Math.floor(bytes.length/2);await h.request(url,{token,method:'PATCH',bytes:bytes.subarray(0,cut),type:OFFSET_TYPE,headers:{'Upload-Offset':'0'}});
  assert.equal((await h.request(url,{token,method:'POST',body})).data.upload.offset,cut);
  assert.equal((await h.request(url,{token,method:'PATCH',bytes:bytes.subarray(cut),type:OFFSET_TYPE,headers:{'Upload-Offset':String(cut)}})).data.upload.complete,true);
  assert.equal((await h.request(url,{token,method:'POST',body})).data.upload.complete,true);
 }
 const committed=await h.request(route+'/commit',{token,method:'POST',body:{}});assert.equal(committed.status,200,JSON.stringify(committed.data));assert.equal(committed.data.capture.keyframes.sha256,sha(pack));
 assert.equal((await h.request(route+'/commit',{token,method:'POST',body:{}})).status,200);
 assert.equal((await h.request(route,{token,method:'POST',body:{...declaration,sha256:'f'.repeat(64)}})).status,409);
 await h.request(base,{token,method:'DELETE'});assert.equal((await h.request(route,{token,method:'POST',body:declaration})).status,404);
});

test('subject keyframes bind only high quality; explicit retry preserves quick and prior input history',async t=>{
  for(const masks of [false,true]) await t.test(`masks=${masks}`,async t=>{
    const h=await harness(t),token=await h.register(),{id}=await h.create(token),base=`/v2/captures/${id}`;
    const metadata=fixture(id,{count:12}),records=JSON.parse(metadata).framesJSONL.trim().split('\n').map(JSON.parse);
    await h.upload(token,id,'rgb',video,'video/quicktime');await h.upload(token,id,'metadata',metadata,'application/json');
    assert.equal((await h.request(base+'/complete',{token,method:'POST',body:{}})).status,200);
    const pack=buildPack(id,records.slice(0,10),{masks,mode:'object'}),hash=sha(pack),route=base+'/keyframes-upload';
    await h.request(route,{token,method:'POST',body:{sha256:hash,byteSize:pack.length,mime:'application/x-pocketworld-keyframes'}});
    assert.equal((await h.request(route,{token,method:'PATCH',bytes:pack,type:OFFSET_TYPE,headers:{'Upload-Offset':'0'}})).status,200);
    const post=body=>h.request(base+'/reconstructions',{token,method:'POST',body:{consentVersion:NATIVE_DUAL_CONSENT,...body}});
    assert.equal((await post({roles:['preview'],keyframesSha256:hash})).data.error.code,'invalid_keyframe_role');
    if(!masks){assert.equal((await post({roles:['refined'],keyframesSha256:hash})).data.error.code,'subject_masks_required');return;}
    let created=await post({roles:['preview','refined']});const initial=created.data.reconstruction;
    const quick=initial.tasks.find(t=>t.role==='preview'),high=initial.tasks.find(t=>t.role==='refined');
    assert.equal((await post({roles:['refined'],keyframesSha256:hash})).data.error.code,'task_input_conflict');
    const repo=openVideoReconstructionRepository({dataDir:path.join(h.directory,'data')});
    try {
      const claim=repo.claim(high.id,'SYNTHETIC_TEST_WORKER');repo.setPhase(claim.id,claim.claimId,'failed','provider_failed',{code:'fixture_failure',message:'SYNTHETIC'});
      const body={failedTaskId:high.id,id:randomUUID(),keyframesSha256:hash},retry=`/v2/video-reconstructions/${initial.id}/retry`;
      const next=await h.request(retry,{token,method:'POST',body});assert.equal(next.status,200,JSON.stringify(next.data));
      const result=next.data.reconstruction,newHigh=result.tasks.find(t=>t.role==='refined');
      assert.deepEqual(result.tasks.find(t=>t.role==='preview'),quick);
      assert.equal(newHigh.algorithm,'gs_mcmc');assert.equal(newHigh.input.keyframes.sha256,hash);assert.equal(newHigh.input.keyframes.masks,true);
      assert.equal(result.previousAttempts.find(t=>t.id===high.id).input,undefined);
      assert.deepEqual((await h.request(retry,{token,method:'POST',body})).data.reconstruction,result);
      assert.equal((await h.request(retry,{token,method:'POST',body:{...body,keyframesSha256:'a'.repeat(64)}})).data.error.code,'retry_conflict');
      const job=repo.claim(newHigh.id,'SYNTHETIC_TEST_WORKER');assert.equal(repo.source(job.id,job.claimId).keyframes.sha256,hash);
    } finally { repo.close(); }
  });
});
