// Synthetic error-path acceptance against an already deployed API/worker.
// The tiny container has no decodable video track and must fail before provider
// submission. This is not camera data, a reconstruction, or iPhone acceptance.
import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

const args=process.argv.slice(2);
assert.equal(args.length,2,'Use --config <private JSON under work/>');assert.equal(args[0],'--config');
const root=fileURLToPath(new URL('../../',import.meta.url)),workRoot=path.join(root,'work')+path.sep;
const configFile=path.resolve(args[1]);assert.ok(configFile.startsWith(workRoot),'Configuration must stay under ignored work/.');
const config=JSON.parse(await readFile(configFile,'utf8'));
const origin=new URL(config.apiOrigin);
assert.ok(['http:','https:'].includes(origin.protocol)&&!origin.username&&!origin.password&&origin.pathname==='/'&&!origin.search&&!origin.hash);
const directory=path.resolve(config.runDirectory);assert.ok(directory.startsWith(workRoot),'Private acceptance files belong under work/.');
const maxWaitMs=config.maxWaitMs??180000,pollMs=config.pollMs??2000;
assert.ok(Number.isInteger(maxWaitMs)&&maxWaitMs>=5000&&maxWaitMs<=900000);
assert.ok(Number.isInteger(pollMs)&&pollMs>=500&&pollMs<=10000);
await mkdir(directory,{recursive:true});
const box=(name,payload)=>{const header=Buffer.alloc(8);header.writeUInt32BE(payload.length+8);header.write(name,4);return Buffer.concat([header,payload]);};
const video=Buffer.concat([box('ftyp',Buffer.from('isom\0\0\0\0isom')),box('moov',box('free',Buffer.from('SYNTHETIC_NO_VIDEO_TRACK'))),box('mdat',Buffer.from('SYNTHETIC_INVALID_VIDEO_NO_TRACK_TEST_ONLY'))]);
assert.ok(video.length<1024);
const sourceSHA=createHash('sha256').update(video).digest('hex');
// Retain the exact artificial bytes for an independent read-only ffprobe audit.
await writeFile(path.join(directory,'SYNTHETIC_NO_VIDEO_TRACK.mp4'),video,{mode:0o600});
const stateFile=path.join(directory,'retry-client-private.json'),reportFile=path.join(directory,'deployed-retry-report.json');
const save=async(file,value)=>{const temporary=file+'.'+randomUUID()+'.tmp';await writeFile(temporary,JSON.stringify(value,null,2)+'\n',{mode:0o600});await rename(temporary,file);};
let state;
try {
  state=JSON.parse(await readFile(stateFile,'utf8'));
  assert.equal(state.version,1);assert.equal(state.origin,origin.origin);assert.equal(state.sourceSHA256,sourceSHA);
}catch(error){if(error.code!=='ENOENT')throw error;state={version:1,id:randomUUID(),retryId:randomUUID(),origin:origin.origin,sourceSHA256:sourceSHA,phase:'new',createdAt:new Date().toISOString()};}
await save(stateFile,state);
let report;
try {report=JSON.parse(await readFile(reportFile,'utf8'));assert.equal(report.id,state.id);assert.equal(report.sourceVideoSha256,sourceSHA);}
catch(error){if(error.code!=='ENOENT')throw error;report={id:state.id,origin:origin.origin,startedAt:state.createdAt,sourceVideoSha256:sourceSHA,sourceByteSize:video.length,
  fixtureKind:'SYNTHETIC_INVALID_VIDEO_NO_TRACK_TEST_ONLY',realCameraData:false,realReconstructionVerified:false,iphoneVerified:false,nativeCaptureVerified:false,
  sourceKind:'external_rgb_video',expectedFailureStage:'ffprobe/frame extraction before provider submission',providerJournalVerification:'pending_remote_read_only_check',events:[]};}
report.lastStartedAt=new Date().toISOString();report.passed=false;delete report.error;delete report.finishedAt;
const persist=()=>save(stateFile,state);
const post=body=>({method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
const request=(route,options={},token=state.auth?.token)=>{
  assert.ok(route.startsWith('/')&&!route.startsWith('//'));
  return fetch(origin.origin+route,{...options,headers:{...(token?{Authorization:`Bearer ${token}`} : {}),...options.headers},redirect:'error',signal:AbortSignal.timeout(30000)});
};
const json=async(route,options={},token)=>{const response=await request(route,options,token),body=await response.json();if(!response.ok)throw Error(`HTTP ${response.status}: ${body.error?.code??'request_failed'}`);return body;};
const expectStatus=async(route,status,options={},token)=>{
  const response=await request(route,options,token),body=await response.json();assert.equal(response.status,status,`Unexpected status for ${options.method??'GET'} ${route}`);return body;
};
const base=`/v2/video-reconstructions/${state.id}`;
const creation={id:state.id,title:'SYNTHETIC INVALID VIDEO — error-path test only',consentVersion:'2026-11-03-video-dual-v1',expectedSha256:sourceSHA,expectedByteSize:video.length};
const put={method:'PUT',headers:{'Content-Type':'video/mp4'},body:video};
const snapshot=async reconstruction=>{
  assert.equal(reconstruction.id,state.id);assert.equal(reconstruction.sourceKind,'external_rgb_video');assert.equal(reconstruction.captureId,undefined);
  assert.equal(reconstruction.sourceVideoSha256,sourceSHA);assert.equal(reconstruction.sourceByteSize,video.length);assert.equal(reconstruction.tasks.length,2);
  assert.ok(reconstruction.tasks.every(t=>!t.result),'Synthetic undecodable input must never publish a result.');
  const tasks=reconstruction.tasks.map(({id,algorithm,role,status,phase,error})=>({id,algorithm,role,status,phase,...(error?{error}:{})}));
  const last=report.events.at(-1);
  if(JSON.stringify(last?.tasks)!==JSON.stringify(tasks)) {
    const event={at:new Date().toISOString(),tasks};report.events.push(event);console.log(JSON.stringify(event));
  }
  report.reconstruction=reconstruction;await save(reportFile,report);
};
const awaitFailed=async(ids)=>{
  const deadline=Date.now()+maxWaitMs;
  while(true) {
    const reconstruction=(await json(base)).reconstruction;await snapshot(reconstruction);
    assert.deepEqual(reconstruction.tasks.map(t=>t.id).sort(),[...ids].sort());
    for(const task of reconstruction.tasks) {
      assert.ok(['queued','processing','failed'].includes(task.status),'Invalid fixture reached an unexpected task state.');
      assert.ok(!/provider|waiting_gpu|ff_processing|sfm_gs_processing|packaging/.test(task.phase),'Invalid fixture passed the local decode stage.');
      if(task.status==='failed')assert.equal(task.phase,'worker_failed','Fixture must fail in worker decode, not in a provider job.');
    }
    if(reconstruction.tasks.every(t=>t.status==='failed'))return reconstruction;
    if(Date.now()>deadline)throw Error('Synthetic failure wait limit reached; resume the same saved identities.');
    await new Promise(resolve=>setTimeout(resolve,pollMs));
  }
};
const assertRetried=reconstruction=>{
  assert.equal(reconstruction.tasks.length,2);assert.equal(reconstruction.previousAttempts.length,1);
  assert.deepEqual(reconstruction.tasks.map(t=>t.id).sort(),[state.retryId,state.untouchedTask.id].sort());
  const archived=reconstruction.previousAttempts[0];assert.equal(archived.id,state.failedTask.id);assert.equal(archived.replacementId,state.retryId);assert.equal(archived.status,'failed');
  const untouched=reconstruction.tasks.find(t=>t.id===state.untouchedTask.id);
  assert.equal(untouched.status,'failed');assert.equal(untouched.updatedAt,state.untouchedTask.updatedAt);
};

try {
  assert.equal((await json('/health')).ok,true);
  for(const key of ['auth','otherAuth'])if(!state[key]){state[key]=await json('/v1/auth/anonymous',post({}),null);await persist();}
  if(!['deleting','deleted','complete'].includes(state.phase)) {
    await json('/v2/video-reconstructions',post(creation));
    const uploaded=(await json(base+'/video',put)).reconstruction;
    if(!state.originalTasks){state.originalTasks=uploaded.tasks.map(t=>({id:t.id,algorithm:t.algorithm,role:t.role}));state.phase='uploaded';await persist();}
    const second=(await json(base+'/video',put)).reconstruction;
    assert.deepEqual(second.tasks.map(t=>t.id).sort(),uploaded.tasks.map(t=>t.id).sort());report.duplicateUploadIdempotent=true;
    if(!state.retryIntent) {
      const failed=await awaitFailed(state.originalTasks.map(t=>t.id));
      state.failedTask=failed.tasks.find(t=>t.role==='preview');state.untouchedTask=failed.tasks.find(t=>t.role==='refined');
      assert.ok(state.failedTask&&state.untouchedTask);report.originalTasks=failed.tasks;
      state.phase='original_failed';await persist();report.originalBranchesFailedBeforeProvider=true;
      assert.equal(failed.previousAttempts.length,0);
      for(const token of [null,state.otherAuth.token]) {
        await expectStatus(base,token?404:401,{},token);
        await expectStatus(base+'/retry',token?404:401,post({failedTaskId:state.failedTask.id,id:state.retryId}),token);
        await expectStatus(base,token?404:401,{method:'DELETE'},token);
      }
      report.ownershipAndAuthenticationVerified=true;
      state.retryIntent=true;state.phase='retry_intent';await persist(); // Durable identity before mutation.
    }
    const retryBody={failedTaskId:state.failedTask.id,id:state.retryId};
    const retried=(await json(base+'/retry',post(retryBody))).reconstruction;assertRetried(retried);
    const repeated=(await json(base+'/retry',post(retryBody))).reconstruction;assertRetried(repeated);
    report.sameRetryIdIdempotent=true;state.phase='retry_sent';await persist();
    const retryFailed=await awaitFailed([state.retryId,state.untouchedTask.id]);assertRetried(retryFailed);
    report.failedBranchOnlyRetried=true;report.retryId=state.retryId;report.retryHistoryCount=1;
    report.allAttemptIds=[...state.originalTasks.map(t=>t.id),state.retryId];
    assert.equal((await json('/v2/captures')).captures.length,0);report.noNativeCaptureOrReceiptCreated=true;
    state.phase='deleting';await persist();
  }
  // Repeating this block is safe after a lost deletion response or process exit.
  await expectStatus(base,200,{method:'DELETE'});state.phase='deleted';await persist();
  await expectStatus(base,404);await expectStatus(base+'/video',404,put);
  await expectStatus(base+'/retry',404,post({failedTaskId:state.failedTask.id,id:state.retryId}));
  const recreate=await expectStatus('/v2/video-reconstructions',409,post(creation));assert.equal(recreate.error.code,'video_reconstruction_deleted');
  await expectStatus(base,200,{method:'DELETE'});
  await new Promise(resolve=>setTimeout(resolve,pollMs));await expectStatus(base,404);
  assert.ok(!(await json('/v2/video-reconstructions')).reconstructions.some(r=>r.id===state.id));
  report.deletionAndTombstoneVerified=true;report.passed=true;report.finishedAt=new Date().toISOString();
  state.phase='complete';await persist();await save(reportFile,report);
  console.log(JSON.stringify({passed:true,fixtureKind:report.fixtureKind,reportFile,id:state.id,attemptIds:report.allAttemptIds,
    providerJournalVerification:report.providerJournalVerification,realReconstructionVerified:false},null,2));
}catch(error){report.error=error.message;report.passed=false;report.finishedAt=new Date().toISOString();await save(reportFile,report);console.error(error.message);process.exitCode=1;}
