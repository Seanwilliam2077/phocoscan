import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, lstat } from 'node:fs/promises';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { createServer } from '../src/server.mjs';
import { runBridgeOnce, PocketWorldBridgeClient, bridgeOptions, extractBridgeFrames } from '../src/worldmirror-bridge.mjs';

// Synthetic isolated transport fixtures. These are neither captured footage nor
// reconstructed scenes; no real user's data or configured Hub is ever accessed.
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
function box(type,contents){const head=Buffer.alloc(8);head.writeUInt32BE(contents.length+8);head.write(type,4);return Buffer.concat([head,contents]);}
const VIDEO=Buffer.concat([box('ftyp',Buffer.from('isom\0\0\0\0')),box('moov',Buffer.from('SYNTHETIC_NOT_PLAYABLE')),box('mdat',Buffer.from('SYNTHETIC_NO_REAL_CAPTURE'))]);
const JPEG=Buffer.from([255,216,255,224,1,2,3,255,217]);
const properties=['x','y','z','f_dc_0','f_dc_1','f_dc_2','opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3'];
const PLY=Buffer.from('ply\nformat ascii 1.0\ncomment SYNTHETIC_NOT_A_RECONSTRUCTION\nelement vertex 1\n'+properties.map(p=>'property float '+p).join('\n')+'\nend_header\n0 0 1 0.3 0.2 0.1 2 -3 -3 -3 1 0 0 0\n');
const digestFile=async file=>hash(await readFile(file));
async function fixture(t,{ply=PLY}={}){
  const directory=await mkdtemp(path.join(os.tmpdir(),'pocketworld-bridge-test-')),adminToken=randomBytes(32).toString('base64url');
  const server=createServer({dataDir:path.join(directory,'backend'),adminToken,logger:{error(){}}});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));const origin='http://127.0.0.1:'+server.address().port;
  t.after(async()=>{await new Promise(r=>{server.close(r);server.closeAllConnections();});server.closeDatabase();await rm(directory,{recursive:true,force:true});});
  let auth;
  async function request(route,{method='GET',body,raw,admin=false}={}){const response=await fetch(origin+route,{method,headers:{Authorization:'Bearer '+(admin?adminToken:auth?.token||''),...(raw?{'Content-Type':'video/mp4'}:body?{'Content-Type':'application/json'}:{})},body:raw||body&&JSON.stringify(body)});assert.ok(response.ok,'Fixture request failed: '+response.status);return response.json();}
  auth=await request('/v1/auth/anonymous',{method:'POST',body:{}});
  const id=randomUUID();await request('/v1/sessions',{method:'POST',body:{id,questId:'first_light',environment:'indoor',captureMode:'in_app_rgb',consentVersion:'2026-10-22-v1'}});
  await request('/v1/sessions/'+id+'/video',{method:'PUT',raw:VIDEO});
  const submitted=await request('/v1/sessions/'+id+'/submit',{method:'POST',body:{capturedAt:'2026-10-26T00:00:00Z',durationSeconds:20,width:640,height:480,fps:30}});
  const options={backendOrigin:origin,providerOrigin:'http://synthetic-provider.invalid',adminToken,workDir:path.join(directory,'ignored-work'),frameCount:8,providerVersion:'synthetic-test-only',ffmpegPath:path.join(directory,'unused-fixture-ffmpeg.exe')};
  const calls={extract:0,upload:0,quick:0,resume:0},control={ready:false};
  const providerClient={origin:options.providerOrigin};
  const get=async dir=>JSON.parse(await readFile(path.join(dir,'manifest.json'),'utf8'));
  const put=async(dir,value)=>{await writeFile(path.join(dir,'manifest.json'),JSON.stringify(value));return value;};
  const providerWorkflow={
    async uploadRun({directory,name}){assert.match(name,/^PocketWorld-[0-9a-f-]{36}$/);try{return await get(directory);}catch(e){if(e.code!=='ENOENT')throw e;}calls.upload++;await mkdir(directory,{recursive:true});return put(directory,{phase:'images_uploaded',groupId:'synthetic-group',imagesAssetId:'synthetic-images'});},
    async quickRun({directory}){const state=await get(directory);if(state.projectId)return state;calls.quick++;return put(directory,{...state,phase:'submitted',projectId:'synthetic-project',stepId:'synthetic-step'});},
    async resumeRun({directory}){calls.resume++;await control.onResume?.();const state=await get(directory);if(!control.ready)return state;if(state.phase==='downloaded')return state;await writeFile(path.join(directory,'scene.ply'),control.invalidPLY?Buffer.from('INVALID SYNTHETIC PLY'):ply);return put(directory,{...state,phase:'downloaded',output:{file:'scene.ply',size:control.invalidPLY?21:ply.length,sha256:control.invalidPLY?hash(Buffer.from('INVALID SYNTHETIC PLY')):hash(ply)}});},
    runSummary(state){return {phase:state.phase,groupId:state.groupId,imagesAssetId:state.imagesAssetId,projectId:state.projectId,stepId:state.stepId};}
  };
  const extractFrames=async({outputDirectory,frameCount})=>{calls.extract++;await mkdir(outputDirectory);const files=[];for(let n=1;n<=frameCount;n++){const name='frame-'+String(n).padStart(3,'0')+'.jpg';await writeFile(path.join(outputDirectory,name),JPEG);files.push({name,size:JPEG.length,sha256:hash(JPEG)});}return {files,method:'synthetic-test-fixture'};};
  const deps={jobId:submitted.job.id,providerClient,providerWorkflow,extractFrames};
  return {directory,options,deps,request,control,calls,id,jobId:submitted.job.id,run:more=>runBridgeOnce(options,{...deps,...more}),manifest:async()=>get(path.join(options.workDir,submitted.job.id)).catch(async()=>JSON.parse(await readFile(path.join(options.workDir,submitted.job.id,'bridge.json'),'utf8')))};
}

test('bridge resumes provider work without reupload, verifies source/model, then imports real admin ready',async t=>{
  const x=await fixture(t);const first=await x.run();assert.equal(first.phase,'provider_processing');assert.deepEqual(x.calls,{extract:1,upload:1,quick:1,resume:1});
  const jobs=await x.request('/v1/admin/jobs',{admin:true});assert.equal(jobs.jobs[0].job.status,'processing');assert.equal(jobs.jobs[0].asset,null);
  x.control.ready=true;const done=await x.run();assert.equal(done.phase,'imported');assert.ok(done.assetId);assert.deepEqual(x.calls,{extract:1,upload:1,quick:1,resume:2});
  const confirmed=(await x.request('/v1/admin/jobs',{admin:true})).jobs[0];assert.equal(confirmed.job.status,'ready');assert.equal(confirmed.asset.sha256,hash(PLY));assert.equal(confirmed.asset.qualityStatus,'needs_review');assert.equal(confirmed.asset.dualUseStatus,'not_evaluated');assert.equal(confirmed.reward,null);
  assert.equal((await x.run()).phase,'imported');assert.equal(x.calls.resume,2);
  const manifest=await readFile(path.join(x.options.workDir,x.jobId,'bridge.json'),'utf8');assert.ok(!manifest.includes(x.options.adminToken));assert.equal(await digestFile(path.join(x.options.workDir,x.jobId,'source-video.mp4')),hash(VIDEO));
});

test('verified probability exporter profile survives worker import and derivative metadata',async t=>{
  const probabilityPLY=Buffer.from(PLY.toString('utf8').replace('0.1 2 -3','0.1 0 -3'));
  const x=await fixture(t,{ply:probabilityPLY});x.options.plyProfile='worldmirror2-probability-v1';x.control.ready=true;
  assert.equal((await x.run()).phase,'imported');
  const e=(await x.request('/v1/admin/jobs',{admin:true})).jobs[0];
  assert.equal(e.asset.plyProfile,'worldmirror2-probability-v1');
  const info=await x.request(`/v1/assets/${e.asset.id}/viewer-info?maxPoints=60000`);
  assert.equal(info.sourcePlyProfile,'worldmirror2-probability-v1');assert.equal(info.derivativeVersion,'splat-sh0-v2');
  assert.equal((await x.run()).phase,'imported');
  await assert.rejects(runBridgeOnce({...x.options,plyProfile:undefined},x.deps),{code:'profile_mismatch'});
});

test('invalid probability-tagged PLY cannot be imported as ready',async t=>{
  const x=await fixture(t);x.options.plyProfile='worldmirror2-probability-v1';x.control.ready=true;
  await assert.rejects(x.run(),e=>e.code==='backend_http'&&e.status===422);
  const e=(await x.request('/v1/admin/jobs',{admin:true})).jobs[0];
  assert.equal(e.asset,null);assert.notEqual(e.job.status,'ready');
});

test('a lost import response is confirmed from its immutable output without another provider job',async t=>{
  const x=await fixture(t);x.control.ready=true;let imports=0;
  const lossy=async(url,options)=>{const response=await fetch(url,options);if(options.method==='PUT'&&url.includes('/asset?')){imports++;await response.arrayBuffer();throw Error('synthetic response lost after successful commit');}return response;};
  await assert.rejects(x.run({fetchImpl:lossy}),e=>e.outcomeUnknown===true);
  const manifest=JSON.parse(await readFile(path.join(x.options.workDir,x.jobId,'bridge.json'),'utf8'));assert.equal(manifest.phase,'blocked');assert.equal(manifest.output.sha256,hash(PLY));
  assert.equal((await x.run()).phase,'imported');assert.equal(imports,1);assert.equal(x.calls.upload,1);assert.equal(x.calls.quick,1);assert.equal(x.calls.resume,1);
});

test('cancellation while provider finishes prevents import and never resurrects the job',async t=>{
  const x=await fixture(t);x.control.ready=true;x.control.onResume=()=>x.request('/v1/admin/jobs/'+x.jobId+'/status',{admin:true,method:'PUT',body:{status:'cancelled'}});
  assert.equal((await x.run()).phase,'cancelled');const e=(await x.request('/v1/admin/jobs',{admin:true})).jobs[0];assert.equal(e.job.status,'cancelled');assert.equal(e.asset,null);
});

test('a cancelled local run resumes only after an explicit queued reset and reuses its provider work',async t=>{
  const x=await fixture(t);x.control.ready=true;x.control.onResume=()=>x.request('/v1/admin/jobs/'+x.jobId+'/status',{admin:true,method:'PUT',body:{status:'cancelled'}});
  assert.equal((await x.run()).phase,'cancelled');
  const firstClaim=(await x.manifest()).claim.id;
  assert.equal((await x.run()).phase,'cancelled');assert.equal(x.calls.resume,1);
  await x.request('/v1/admin/jobs/'+x.jobId+'/status',{admin:true,method:'PUT',body:{status:'queued',expectedStatus:'cancelled'}});
  delete x.control.onResume;
  assert.equal((await x.run()).phase,'imported');assert.notEqual((await x.manifest()).claim.id,firstClaim);
  assert.deepEqual(x.calls,{extract:1,upload:1,quick:1,resume:2});
});

test('the bounded PLY download timeout is forwarded to provider resume, separately from request timeout',async t=>{
  const x=await fixture(t);x.options.timeoutMs=10000;x.options.downloadTimeoutMs=125000;
  const resume=x.deps.providerWorkflow.resumeRun;let received;
  x.deps.providerWorkflow.resumeRun=async options=>{received=options;return resume(options);};
  assert.equal((await x.run()).phase,'provider_processing');
  assert.equal(received.downloadTimeoutMs,125000);assert.equal(received.maxWaitMs,0);
  assert.equal(bridgeOptions(x.options).downloadTimeoutMs,125000);
  assert.equal(bridgeOptions({...x.options,downloadTimeoutMs:undefined}).downloadTimeoutMs,120000);
  assert.throws(()=>bridgeOptions({...x.options,downloadTimeoutMs:300001}),e=>e.code==='invalid_config');
});

test('deletion while provider finishes prevents importing orphaned output',async t=>{
  const x=await fixture(t);x.control.ready=true;x.control.onResume=()=>x.request('/v1/sessions/'+x.id,{method:'DELETE'});
  assert.equal((await x.run()).phase,'cancelled');assert.equal((await x.request('/v1/admin/jobs',{admin:true})).jobs.length,0);
});

test('deletion after provider group creation stops the next image mutation checkpoint',async t=>{
  const x=await fixture(t);let groups=0,images=0;
  x.deps.providerWorkflow.uploadRun=async({beforeMutation})=>{await beforeMutation();groups++;await x.request('/v1/sessions/'+x.id,{method:'DELETE'});await beforeMutation();images++;throw Error('must not upload images');};
  assert.equal((await x.run()).phase,'cancelled');assert.equal(groups,1);assert.equal(images,0);assert.equal(x.calls.quick,0);
});

test('manifest-provided foreign video URLs are never followed or sent administrator credentials',async t=>{
  const x=await fixture(t);const urls=[];
  const poisoned=async(url,options)=>{urls.push(url);const response=await fetch(url,options);if(url.endsWith('/bundle')){const body=await response.json();body.files[0].url='https://untrusted.invalid/steal';return new Response(JSON.stringify(body),{status:200});}return response;};
  await assert.rejects(x.run({fetchImpl:poisoned}),e=>['invalid_source','unsafe_endpoint'].includes(e.code));assert.equal(x.calls.upload,0);assert.ok(urls.every(url=>url.startsWith(x.options.backendOrigin+'/')));
});

test('download hash mismatch stops before frame extraction and provider upload',async t=>{
  const x=await fixture(t);const corrupt=async(url,options)=>url.endsWith('/video')?new Response(Buffer.alloc(VIDEO.length,1),{status:200}):fetch(url,options);
  await assert.rejects(x.run({fetchImpl:corrupt}),e=>e.code==='source_changed');assert.equal(x.calls.extract,0);assert.equal(x.calls.upload,0);
  await assert.rejects(lstat(path.join(x.options.workDir,x.jobId,'source-video.mp4')),{code:'ENOENT'});
});

test('changed backend/provider credential profile cannot resume or mutate the previous run',async t=>{
  const x=await fixture(t);await x.run();let requests=0;
  await assert.rejects(runBridgeOnce({...x.options,adminToken:randomBytes(32).toString('base64url')},{...x.deps,fetchImpl:async()=>{requests++;throw Error('must not contact service');}}),e=>e.code==='profile_mismatch');assert.equal(requests,0);
});

test('a queued claim conflict never marks the winning worker failed or adopts it on restart',async t=>{
  const x=await fixture(t);const writes=[];let won=false;
  const racing=async(url,options)=>{
    if(url.endsWith('/status')&&options.method==='PUT'){
      const body=JSON.parse(options.body);writes.push(body.status);
      if(!won&&body.status==='processing'){won=true;await x.request('/v1/admin/jobs/'+x.jobId+'/status',{admin:true,method:'PUT',body:{status:'processing',expectedStatus:'queued'}});return new Response('{}',{status:409});}
    }
    return fetch(url,options);
  };
  await assert.rejects(x.run({fetchImpl:racing}),e=>e.code==='claim_conflict');assert.deepEqual(writes,['processing']);
  assert.equal((await x.request('/v1/admin/jobs',{admin:true})).jobs[0].job.status,'processing');
  await assert.rejects(x.run({fetchImpl:racing}),e=>e.code==='claim_unconfirmed');assert.deepEqual(writes,['processing']);assert.equal(x.calls.extract,0);assert.equal(x.calls.upload,0);
});

test('an unknown initial processing claim is never inferred from a local manifest',async t=>{
  const x=await fixture(t);let writes=0;
  const lossy=async(url,options)=>{const response=await fetch(url,options);if(url.endsWith('/status')&&options.method==='PUT'){writes++;await response.arrayBuffer();throw Error('synthetic lost claim response');}return response;};
  await assert.rejects(x.run({fetchImpl:lossy}),e=>e.code==='claim_unconfirmed');
  await assert.rejects(x.run(),e=>e.code==='claim_unconfirmed');assert.equal(writes,1);assert.equal(x.calls.upload,0);assert.equal((await x.request('/v1/admin/jobs',{admin:true})).jobs[0].job.status,'processing');
});

test('invalid provider output is never imported or presented as ready',async t=>{
  const x=await fixture(t);x.control.ready=true;x.control.invalidPLY=true;await assert.rejects(x.run());
  const e=(await x.request('/v1/admin/jobs',{admin:true})).jobs[0];assert.equal(e.asset,null);assert.equal(e.job.status,'failed');assert.equal(e.reward,null);
});

test('ambiguous provider mutation stays blocked across restarts without marking a live external job failed',async t=>{
  const x=await fixture(t);let mutation=0;
  x.deps.providerWorkflow.uploadRun=async()=>{if(!mutation++){throw Object.assign(Error('synthetic lost mutation response'),{code:'request_failed',outcomeUnknown:true});}throw Object.assign(Error('synthetic unresolved intent'),{code:'mutation_unresolved'});};
  await assert.rejects(x.run(),e=>e.outcomeUnknown);await assert.rejects(x.run(),e=>e.code==='mutation_unresolved');
  const e=(await x.request('/v1/admin/jobs',{admin:true})).jobs[0];assert.equal(e.job.status,'processing');assert.equal(e.asset,null);assert.equal(x.calls.quick,0);assert.equal(x.calls.extract,1);
});

test('transient provider polling failure can resume without overwriting processing with failed',async t=>{
  const x=await fixture(t);const original=x.deps.providerWorkflow.resumeRun;x.deps.providerWorkflow.resumeRun=async()=>{throw Object.assign(Error('synthetic timeout'),{code:'request_timeout',outcomeUnknown:false});};
  await assert.rejects(x.run(),e=>e.code==='request_timeout');assert.equal((await x.request('/v1/admin/jobs',{admin:true})).jobs[0].job.status,'processing');
  x.deps.providerWorkflow.resumeRun=original;x.control.ready=true;assert.equal((await x.run()).phase,'imported');assert.equal(x.calls.upload,1);assert.equal(x.calls.quick,1);
});

test('worker route/config guards and empty watch selection perform no unintended provider writes',async t=>{
  assert.throws(()=>bridgeOptions({adminToken:'short'}),/existing/);
  const client=new PocketWorldBridgeClient({origin:'https://configured.invalid',token:'synthetic'});
  await assert.rejects(client.request('//another.invalid/v1/admin/jobs'),e=>e.code==='unsafe_endpoint');
  const x=await fixture(t);await x.request('/v1/admin/jobs/'+x.jobId+'/status',{admin:true,method:'PUT',body:{status:'processing'}});
  const result=await runBridgeOnce(x.options,{...x.deps,jobId:undefined});assert.equal(result.phase,'idle');assert.equal(x.calls.upload,0);
});

test('ffmpeg requires an absolute configured executable before creating extraction output',async t=>{
  const directory=await mkdtemp(path.join(os.tmpdir(),'bridge-ffmpeg-guard-'));t.after(()=>rm(directory,{recursive:true,force:true}));
  await assert.rejects(extractBridgeFrames({sourceVideo:path.join(directory,'source.mp4'),outputDirectory:path.join(directory,'frames'),ffmpegPath:'ffmpeg',frameCount:8,durationSeconds:20}),e=>e.code==='ffmpeg_missing');
  await assert.rejects(lstat(path.join(directory,'frames')),{code:'ENOENT'});
});
