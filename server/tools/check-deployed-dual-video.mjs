// Real client-side acceptance against a separately deployed API/worker.
// Uses an external RGB video. No ARKit metadata, receipt or GPU result is fabricated.
import { readFile,writeFile,mkdir,stat,rename } from 'node:fs/promises';
import { createReadStream,openAsBlob } from 'node:fs';
import { createHash,randomUUID } from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { validateGaussian } from '../src/validation.mjs';
import { validateStudyCameras } from '../src/reconstruction-studies.mjs';

const args=process.argv.slice(2);
assert.ok(args.length>=2&&(args.length-2)%2===0);assert.equal(args[0],'--config');
const retryTaskIDs=[];
for(let i=2;i<args.length;i+=2){assert.equal(args[i],'--retry-failed-task');assert.match(args[i+1],/^[a-f0-9-]{36}$/);retryTaskIDs.push(args[i+1]);}
const config=JSON.parse(await readFile(path.resolve(args[1]),'utf8'));
const origin=new URL(config.apiOrigin);assert.ok(['http:','https:'].includes(origin.protocol)&&!origin.username&&!origin.password&&origin.pathname==='/'&&!origin.search&&!origin.hash);
const root=fileURLToPath(new URL('../../',import.meta.url)),directory=path.resolve(config.runDirectory);
assert.ok(directory.startsWith(path.join(root,'work')+path.sep),'Private acceptance state belongs under work/.');
await mkdir(directory,{recursive:true});
const hash=async file=>{const h=createHash('sha256');for await(const b of createReadStream(file))h.update(b);return h.digest('hex');};
const sourceSHA=await hash(config.videoPath),sourceBytes=(await stat(config.videoPath)).size;
assert.equal(sourceSHA,config.expectedSourceSha256,'Input video changed.');
const stateFile=path.join(directory,'client-private.json'),reportFile=path.join(directory,'deployed-report.json');
let state;
try{state=JSON.parse(await readFile(stateFile,'utf8'));assert.equal(state.origin,origin.origin);assert.equal(state.sourceSHA256,sourceSHA);}
catch(e){if(e.code!=='ENOENT')throw e;state={origin:origin.origin,id:randomUUID(),sourceSHA256:sourceSHA,createdAt:new Date().toISOString()};}
const save=async(file,value)=>{const temporary=file+'.'+randomUUID()+'.tmp';await writeFile(temporary,JSON.stringify(value,null,2)+'\n',{mode:0o600});await rename(temporary,file);};
await save(stateFile,state);
const report={id:state.id,origin:origin.origin,startedAt:new Date().toISOString(),sourceVideoSha256:sourceSHA,sourceByteSize:sourceBytes,
  sourceKind:'external_rgb_video',iphoneVerified:false,nativeCaptureVerified:false,events:[],results:[]};
const request=(route,options={},token=state.auth?.token)=>{
  assert.ok(route.startsWith('/')&&!route.startsWith('//'));
  return fetch(origin.origin+route,{...options,headers:{...(token?{Authorization:`Bearer ${token}`} : {}),...options.headers},redirect:'error',signal:AbortSignal.timeout(120000)});
};
const json=async(route,options,token)=>{
  for(let attempt=0;;attempt++){
    try{const r=await request(route,options,token),data=await r.json();if(!r.ok)throw Object.assign(Error(`HTTP ${r.status}: ${data.error?.code??'request_failed'}`),{status:r.status});return data;}
    catch(e){if((options?.method??'GET')!=='GET'||attempt>=5||e.status&&![502,503,504].includes(e.status))throw e;
      report.readReconnects=(report.readReconnects??0)+1;await new Promise(r=>setTimeout(r,1000));}
  }
};
const post=body=>({method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
const base=`/v2/video-reconstructions/${state.id}`,downloads=path.join(directory,'downloads');await mkdir(downloads,{recursive:true});
async function verifyReady(task,reconstruction) {
  const v=task.result;assert.equal(v.id,task.id);assert.equal(v.algorithm,task.algorithm);
  assert.equal(v.filePath,`${base}/results/${task.id}/file`);assert.equal(v.cameraPath,`${base}/results/${task.id}/cameras`);
  assert.ok(v.byteSize>0&&v.byteSize<=150*1024*1024);assert.ok(v.cameraByteSize>0&&v.cameraByteSize<=4*1024*1024);
  for(const token of [null,state.otherAuth.token])for(const route of [v.filePath,v.cameraPath])assert.equal((await request(route,{},token)).status,token?404:401);
  const model=await request(v.filePath);assert.equal(model.status,200);const bytes=Buffer.from(await model.arrayBuffer());
  assert.equal(bytes.length,v.byteSize);assert.equal(createHash('sha256').update(bytes).digest('hex'),v.sha256);
  const modelFile=path.join(downloads,`${task.role}.${v.format}`);await writeFile(modelFile,bytes);
  let degree=0;const parsed=await validateGaussian(modelFile,v.format,{onHeader:h=>degree=h.properties?.some(p=>p.name==='f_rest_44')?3:0});
  assert.equal(parsed.gaussianCount,v.pointCount);assert.equal(degree,v.shDegree);assert.equal(degree,task.role==='refined'?3:0);
  const cr=await request(v.cameraPath);assert.equal(cr.status,200);const cameraBytes=Buffer.from(await cr.arrayBuffer());
  assert.equal(cameraBytes.length,v.cameraByteSize);assert.equal(createHash('sha256').update(cameraBytes).digest('hex'),v.cameraSha256);
  const cameras=validateStudyCameras(JSON.parse(cameraBytes));await writeFile(path.join(downloads,`${task.role}.cameras.json`),cameraBytes);
  const range=await request(v.filePath,{headers:{Range:'bytes=0-31'}});assert.equal(range.status,206);assert.deepEqual(Buffer.from(await range.arrayBuffer()),bytes.subarray(0,32));
  report.results.push({...v,cameraCount:cameras.frames.length,downloadVerifiedAt:new Date().toISOString(),ownershipVerified:true,rangeVerified:true,otherBranchStillPending:reconstruction.tasks.some(t=>t.status!=='ready')});
  console.log(JSON.stringify({stage:'download_verified',role:task.role,byteSize:v.byteSize,pointCount:v.pointCount,cameras:cameras.frames.length}));
  await save(reportFile,report);
}
try{
  assert.equal((await json('/health')).ok,true);
  for(const key of ['auth','otherAuth'])if(!state[key]){state[key]=await json('/v1/auth/anonymous',post({}),null);await save(stateFile,state);}
  await json('/v2/video-reconstructions',post({id:state.id,title:'Windows→A10 常驻双重建验证',consentVersion:'2026-11-03-video-dual-v1',expectedSha256:sourceSHA,expectedByteSize:sourceBytes}));
  const put=async()=>json(base+'/video',{method:'PUT',headers:{'Content-Type':'video/mp4'},body:await openAsBlob(config.videoPath,{type:'video/mp4'})});
  let first=(await put()).reconstruction;assert.equal(first.tasks.length,2);let ids=first.tasks.map(t=>t.id).sort();
  assert.deepEqual((await put()).reconstruction.tasks.map(t=>t.id).sort(),ids);report.duplicateUploadCreatesNoExtraTasks=true;
  report.explicitRetries=[];
  for(const failedTaskId of retryTaskIDs){
    state.retryRequests??={};state.retryRequests[failedTaskId]??=randomUUID();await save(stateFile,state);
    const body={failedTaskId,id:state.retryRequests[failedTaskId]};
    first=(await json(base+'/retry',post(body))).reconstruction;ids=first.tasks.map(t=>t.id).sort();
    assert.deepEqual((await json(base+'/retry',post(body))).reconstruction.tasks.map(t=>t.id).sort(),ids);
    report.explicitRetries.push({...body,idempotencyVerified:true});
  }
  assert.equal((await request(base,{},state.otherAuth.token)).status,404);
  console.log(JSON.stringify({stage:'uploaded_to_deployed_api',id:state.id,tasks:first.tasks.map(t=>({id:t.id,algorithm:t.algorithm}))}));
  let previous='';const deadline=Date.now()+(config.maxWaitMs??1200000);
  while(true){
    const reconstruction=(await json(base)).reconstruction;report.reconstruction=reconstruction;
    assert.equal(reconstruction.sourceVideoSha256,sourceSHA);assert.equal(reconstruction.sourceKind,'external_rgb_video');assert.equal(reconstruction.captureId,undefined);
    assert.deepEqual(reconstruction.tasks.map(t=>t.id).sort(),ids);
    const snapshot=JSON.stringify(reconstruction.tasks.map(t=>({algorithm:t.algorithm,status:t.status,phase:t.phase,error:t.error})));
    if(snapshot!==previous){previous=snapshot;const event={at:new Date().toISOString(),tasks:JSON.parse(snapshot)};report.events.push(event);console.log(JSON.stringify(event));await save(reportFile,report);}
    for(const task of reconstruction.tasks)if(task.status==='ready'&&!report.results.some(r=>r.id===task.id))await verifyReady(task,reconstruction);
    if(reconstruction.tasks.every(t=>t.status==='ready'))break;
    if(reconstruction.tasks.every(t=>['ready','failed','blocked'].includes(t.status)))throw Error('Provider branch requires inspection; no replacement task was submitted.');
    if(Date.now()>deadline)throw Error('Wait limit reached; resume the same persistent client state.');
    await new Promise(r=>setTimeout(r,5000));
  }
  assert.equal(report.results.length,2);
  const captures=await json('/v2/captures');assert.equal(captures.captures.length,0);report.noNativeCaptureFabricated=true;
  report.passed=true;report.finishedAt=new Date().toISOString();await save(reportFile,report);
  console.log(JSON.stringify({passed:true,reportFile,results:report.results.map(r=>({role:r.role,byteSize:r.byteSize,cameras:r.cameraCount}))},null,2));
}catch(error){report.passed=false;report.error=error.message;report.finishedAt=new Date().toISOString();await save(reportFile,report);console.error(error.message);process.exitCode=1;}
