import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, readdir } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { createServer } from '../src/server.mjs';
import { openVideoReconstructionRepository, VIDEO_DUAL_CONSENT } from '../src/video-reconstructions.mjs';

const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const box=(type,body)=>{const h=Buffer.alloc(8);h.writeUInt32BE(body.length+8);h.write(type,4);return Buffer.concat([h,body]);};
const video=Buffer.concat(['moov','mdat'].map(type=>box(type,Buffer.from('SYNTHETIC_TEST_VIDEO_CONTAINER'))));
const splat=Buffer.alloc(32,128);[0,0,1,.1,.1,.1].forEach((v,i)=>splat.writeFloatLE(v,i*4));splat[28]=255;
const names=['x','y','z','f_dc_0','f_dc_1','f_dc_2','opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3',...Array.from({length:45},(_,i)=>`f_rest_${i}`)];
const values=[0,0,1,.1,.2,.3,2,-3,-3,-3,1,0,0,0,...Array.from({length:45},(_,i)=>i/100)];
const plyHeader=Buffer.from(`ply\nformat binary_little_endian 1.0\ncomment SYNTHETIC TEST ONLY\nelement vertex 1\n${names.map(n=>`property float ${n}`).join('\n')}\nend_header\n`);
const plyBody=Buffer.alloc(values.length*4);values.forEach((v,i)=>plyBody.writeFloatLE(v,i*4));const ply=Buffer.concat([plyHeader,plyBody]);
const camera={version:1,coordinateSystem:'opengl_camera_to_world',matrixLayout:'row-major',scale:'unknown',frames:[{sourceFrame:'TEST_FRAME.jpg',timeSeconds:.6,width:540,height:960,fx:500,fy:500,cx:270,cy:480,cameraToWorld:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}]};

async function fixture(t) {
  const directory=await mkdtemp(path.join(tmpdir(),'pw-auto-dual-test-')),dataDir=path.join(directory,'data'),adminToken=randomBytes(32).toString('base64url');
  const x={directory,dataDir};let service;
  const start=async()=>{service=createServer({dataDir,adminToken,logger:{error:()=>{}}});await new Promise(r=>service.listen(0,'127.0.0.1',r));x.origin=`http://127.0.0.1:${service.address().port}`;};
  const stop=async()=>{if(!service)return;await new Promise(r=>{service.close(r);service.closeIdleConnections();});service.closeDatabase();service=null;};
  await start();
  x.repo=openVideoReconstructionRepository({dataDir});
  t.after(async()=>{x.repo.close();await stop();await rm(directory,{recursive:true,force:true});});
  x.request=(route,token,options={})=>fetch(x.origin+route,{...options,headers:{...(token?{Authorization:`Bearer ${token}`}:{ }),...options.headers}});
  x.register=async()=>{const r=await x.request('/v1/auth/anonymous',null,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});assert.equal(r.status,201);return r.json();};
  x.owner=await x.register();x.other=await x.register();
  x.creation={id:randomUUID(),title:'SYNTHETIC_TEST_ONLY',consentVersion:VIDEO_DUAL_CONSENT,expectedSha256:hash(video),expectedByteSize:video.length};
  x.base=`/v2/video-reconstructions/${x.creation.id}`;
  x.create=()=>x.request('/v2/video-reconstructions',x.owner.token,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(x.creation)});
  x.upload=(bytes=video,token=x.owner.token)=>x.request(x.base+'/video',token,{method:'PUT',headers:{'Content-Type':'video/mp4'},body:bytes});
  x.get=async()=>{const r=await x.request(x.base,x.owner.token);assert.equal(r.status,200);return (await r.json()).reconstruction;};
  x.restart=async()=>{x.repo.close();await stop();await start();x.repo=openVideoReconstructionRepository({dataDir});};
  await Promise.all([writeFile(path.join(directory,'preview.splat'),splat),writeFile(path.join(directory,'refined.ply'),ply),writeFile(path.join(directory,'cameras.json'),JSON.stringify(camera))]);
  x.publish=(task,extra={})=>x.repo.publish(task.id,task.claimId,{modelFile:path.join(directory,task.role==='preview'?'preview.splat':'refined.ply'),cameraFile:path.join(directory,'cameras.json'),provenance:{sourceVideoSha256:hash(video),projectId:'test-project',stepId:`step-${task.role}`,testFixture:true},...extra});
  return x;
}

test('upload verifies immutable source and atomically enqueues exactly two durable tasks',async t=>{
  const x=await fixture(t);
  assert.equal((await x.create()).status,201);assert.equal((await x.create()).status,200);
  assert.equal((await x.get()).status,'awaiting_upload');assert.equal(x.repo.pendingJobs().length,0);
  const bad=Buffer.from(video);bad[bad.length-1]^=1;assert.equal((await x.upload(bad)).status,422);assert.equal(x.repo.pendingJobs().length,0);
  assert.equal((await x.upload()).status,200);const first=await x.get();assert.equal(first.status,'queued');assert.equal(first.tasks.length,2);
  assert.deepEqual(new Set(first.tasks.map(t=>t.algorithm)),new Set(['gs_worldmirror2','gs_mcmc']));
  assert.equal((await x.upload()).status,200);assert.deepEqual((await x.get()).tasks.map(t=>t.id),first.tasks.map(t=>t.id));
  await x.restart();assert.deepEqual((await x.get()).tasks.map(t=>t.id),first.tasks.map(t=>t.id));assert.equal(x.repo.pendingJobs().length,2);
  const claimed=x.repo.claim(first.tasks[0].id,'worker-test');const source=x.repo.source(claimed.id,claimed.claimId);
  assert.equal(hash(await readFile(source.sourceVideoPath)),hash(video));assert.equal(source.sourceByteSize,video.length);
  assert.deepEqual((await (await x.request('/v2/captures',x.owner.token)).json()).captures,[]);
  assert.deepEqual((await (await x.request('/v1/sessions',x.owner.token)).json()).sessions,[]);
});

test('one result is available while the other processes; both full assets preserve source hashes and SH3',async t=>{
  const x=await fixture(t);await x.create();await x.upload();
  const tasks=x.repo.pendingJobs();const ff=x.repo.claim(tasks.find(t=>t.role==='preview').id,'worker-test');
  const ffResult=await x.publish(ff);assert.equal((await x.get()).status,'partial');
  assert.equal((await x.get()).tasks.find(t=>t.role==='refined').status,'queued');
  assert.equal((await x.publish(ff)).sha256,ffResult.sha256);
  const sfm=x.repo.claim(tasks.find(t=>t.role==='refined').id,'worker-test');
  x.repo.setPhase(sfm.id,sfm.claimId,'processing','training');const sfmResult=await x.publish(sfm);
  assert.equal((await x.get()).status,'ready');assert.equal(x.repo.pendingJobs().length,0);assert.equal(sfmResult.shDegree,3);
  const bytes=Buffer.from(await (await x.request(sfmResult.filePath,x.owner.token)).arrayBuffer());assert.deepEqual(bytes,ply);assert.equal(hash(bytes),sfmResult.sha256);
  const cam=await x.request(sfmResult.cameraPath,x.owner.token);assert.equal(cam.status,200);assert.equal(hash(Buffer.from(await cam.arrayBuffer())),sfmResult.cameraSha256);
  const range=await x.request(sfmResult.filePath,x.owner.token,{headers:{Range:'bytes=0-31'}});assert.equal(range.status,206);assert.deepEqual(Buffer.from(await range.arrayBuffer()),ply.subarray(0,32));
  await x.restart();assert.equal((await x.get()).status,'ready');
});

test('auth and owner checks cover registration identity, source upload and every result route',async t=>{
  const x=await fixture(t);await x.create();
  assert.equal((await x.request('/v2/video-reconstructions')).status,401);
  assert.equal((await x.request(x.base,x.other.token)).status,404);
  assert.equal((await x.upload(video,x.other.token)).status,404);
  const otherCreate=await x.request('/v2/video-reconstructions',x.other.token,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(x.creation)});assert.equal(otherCreate.status,409);
  await x.upload();const ff=x.repo.claim(x.repo.pendingJobs().find(j=>j.role==='preview').id,'worker-test');const result=await x.publish(ff);
  assert.equal((await x.request(result.filePath)).status,401);assert.equal((await x.request(result.filePath,x.other.token)).status,404);assert.equal((await x.request(result.cameraPath,x.other.token)).status,404);
  const publicText=JSON.stringify(await x.get());assert.ok(!publicText.includes(x.directory));assert.ok(!publicText.includes('claimId'));
});

test('worker claim isolation and independent failure preserve the successful result',async t=>{
  const x=await fixture(t);await x.create();await x.upload();
  const tasks=x.repo.pendingJobs(),ff=x.repo.claim(tasks.find(j=>j.role==='preview').id,'persistent-worker');
  assert.equal(x.repo.claim(ff.id,'persistent-worker').claimId,ff.claimId);assert.throws(()=>x.repo.claim(ff.id,'other-worker'),{code:'claim_conflict'});
  assert.throws(()=>x.repo.source(ff.id,randomUUID()),{code:'claim_conflict'});
  await x.publish(ff);const sfm=x.repo.claim(tasks.find(j=>j.role==='refined').id,'persistent-worker');
  x.repo.setPhase(sfm.id,sfm.claimId,'failed','provider_failed',{code:'training_failed',message:'SYNTHETIC test failure'});
  const result=await x.get();assert.equal(result.status,'partial');assert.equal(result.tasks.find(t=>t.role==='preview').status,'ready');
  assert.equal(result.tasks.find(t=>t.role==='refined').error.code,'training_failed');assert.equal(x.repo.pendingJobs().length,0);
  assert.throws(()=>x.repo.claim(sfm.id,'persistent-worker'),{code:'task_inactive'});
  assert.throws(()=>x.repo.source(sfm.id,sfm.claimId),{code:'task_inactive'});
  assert.throws(()=>x.repo.setPhase(sfm.id,sfm.claimId,'processing','retry'),{code:'task_inactive'});
});

test('bad result provenance, SH3, or camera never publishes; blocked writes do not auto-retry',async t=>{
  const x=await fixture(t);await x.create();await x.upload();
  const sfm=x.repo.claim(x.repo.pendingJobs().find(j=>j.role==='refined').id,'worker-test');
  await assert.rejects(x.publish(sfm,{provenance:{sourceVideoSha256:'0'.repeat(64),projectId:'test',stepId:'test'}}),{code:'result_provenance_mismatch'});
  await writeFile(path.join(x.directory,'refined.ply'),Buffer.from('ply\ninvalid'));await assert.rejects(x.publish(sfm));
  await writeFile(path.join(x.directory,'refined.ply'),ply);await writeFile(path.join(x.directory,'cameras.json'),JSON.stringify({...camera,coordinateSystem:'unknown'}));
  await assert.rejects(x.publish(sfm),{code:'invalid_study_cameras'});
  assert.equal((await x.get()).tasks.find(t=>t.id===sfm.id).result,undefined);
  x.repo.setPhase(sfm.id,sfm.claimId,'blocked','remote_write_unresolved',{code:'write_unknown',message:'Reconcile provider before retry.'});
  assert.ok(!x.repo.pendingJobs().some(t=>t.id===sfm.id));
  assert.deepEqual(await readdir(path.join(x.dataDir,'.tmp')),[]);
});

test('explicit retry replaces only failed branch, retains history and is durable/idempotent',async t=>{
  const x=await fixture(t);await x.create();await x.upload();
  const tasks=x.repo.pendingJobs(),ff=x.repo.claim(tasks.find(j=>j.role==='preview').id,'worker');
  const ready=await x.publish(ff),sfm=x.repo.claim(tasks.find(j=>j.role==='refined').id,'worker');
  const body={failedTaskId:sfm.id,id:randomUUID()};
  const retry=(token=x.owner.token,b=body)=>x.request(x.base+'/retry',token,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});
  assert.equal((await retry()).status,409);
  x.repo.setPhase(sfm.id,sfm.claimId,'failed','provider_failed',{code:'empty_sparse_points',message:'SYNTHETIC test failure'});
  assert.equal((await retry(x.other.token)).status,404);
  assert.equal((await retry()).status,200);assert.equal((await retry()).status,200);
  await x.restart();assert.equal((await retry()).status,200);
  let state=await x.get();assert.equal(state.tasks.length,2);assert.equal(state.previousAttempts.length,1);
  assert.equal(state.previousAttempts[0].id,sfm.id);assert.equal(state.previousAttempts[0].replacementId,body.id);
  assert.equal(state.tasks.find(j=>j.role==='preview').result.sha256,ready.sha256);
  assert.equal((await retry(x.owner.token,{...body,id:randomUUID()})).status,409);
  assert.throws(()=>x.repo.source(sfm.id,sfm.claimId),{code:'video_reconstruction_task_not_found'});
  await assert.rejects(x.publish(sfm),{code:'video_reconstruction_task_not_found'});
  await x.upload();assert.equal((await x.get()).tasks.find(j=>j.role==='refined').id,body.id);
  const replacement=x.repo.claim(body.id,'worker');await x.publish(replacement);
  state=await x.get();assert.equal(state.status,'ready');assert.equal(state.previousAttempts.length,1);
  assert.equal((await retry(x.owner.token,{failedTaskId:ff.id,id:randomUUID()})).status,409);
});

test('retry rejects unknown remote outcomes and deleted sources',async t=>{
  const x=await fixture(t);await x.create();await x.upload();
  const task=x.repo.claim(x.repo.pendingJobs()[0].id,'worker');
  x.repo.setPhase(task.id,task.claimId,'blocked','remote_write_unresolved',{code:'write_unknown',message:'Unconfirmed write'});
  const retry=()=>x.request(x.base+'/retry',x.owner.token,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({failedTaskId:task.id,id:randomUUID()})});
  assert.equal((await retry()).status,409);
  await x.request(x.base,x.owner.token,{method:'DELETE'});assert.equal((await retry()).status,404);
});

test('source deletion during result staging wins; late writes and reuploads cannot revive it',async t=>{
  const x=await fixture(t);await x.create();await x.upload();
  const ff=x.repo.claim(x.repo.pendingJobs().find(j=>j.role==='preview').id,'worker-test');
  const publishing=x.publish(ff).then(value=>({value}),error=>({error}));
  assert.equal((await x.request(x.base,x.owner.token,{method:'DELETE'})).status,200);await publishing;
  assert.equal((await x.request(x.base,x.owner.token)).status,404);assert.equal((await x.upload()).status,404);
  assert.equal((await x.create()).status,409);assert.equal(x.repo.pendingJobs().length,0);
  assert.throws(()=>x.repo.source(ff.id,ff.claimId),{code:'video_reconstruction_task_not_found'});
  await assert.rejects(x.publish(ff),{code:'video_reconstruction_task_not_found'});
  assert.equal((await x.request(x.base,x.owner.token,{method:'DELETE'})).status,200);
  assert.deepEqual(await readdir(path.join(x.dataDir,'video-reconstructions')),[]);
  await x.restart();assert.equal((await x.create()).status,409);
});
