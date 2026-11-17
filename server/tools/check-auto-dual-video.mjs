// Real Windows end-to-end pilot: HTTP upload -> fresh worker processes -> two Hub jobs -> HTTP results.
// Stable run identity survives restarts. Never creates replacement jobs on a failed/unknown mutation.
import { createServer } from '../src/server.mjs';
import { readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { openAsBlob, createReadStream } from 'node:fs';
import { randomUUID, randomBytes, createHash } from 'node:crypto';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

const run=promisify(execFile),args=process.argv.slice(2),option=k=>args[args.indexOf(k)+1];
if(!args.includes('--config'))throw Error('Use --config <ignored private pilot JSON>.');
const configPath=path.resolve(option('--config')),config=JSON.parse(await readFile(configPath,'utf8'));
const root=fileURLToPath(new URL('../../',import.meta.url)),directory=path.resolve(config.runDirectory);
assert.ok(directory.startsWith(path.join(root,'work')+path.sep),'Pilot output must stay under ignored work/.');
await mkdir(directory,{recursive:true});
const stateFile=path.join(directory,'pilot-private.json'),reportFile=path.join(directory,'pilot-report.json');
const sha=async f=>{const h=createHash('sha256');for await(const b of createReadStream(f))h.update(b);return h.digest('hex');};
const inputSHA=await sha(config.videoPath),size=(await stat(config.videoPath)).size;
assert.equal(inputSHA,config.expectedSourceSha256,'Selected original video changed');
let state;
try{state=JSON.parse(await readFile(stateFile,'utf8'));assert.equal(state.sourceSHA256,inputSHA);}catch(e){if(e.code!=='ENOENT')throw e;state={id:randomUUID(),sourceSHA256:inputSHA,adminToken:randomBytes(32).toString('base64url'),createdAt:new Date().toISOString()};}
const persist=async()=>writeFile(stateFile,JSON.stringify(state,null,2)+'\n',{mode:0o600});await persist();
const workerConfig={...config.worker,dataDir:path.join(directory,'data'),workDir:path.join(directory,'worker')};
const workerConfigPath=path.join(directory,'worker-private.json');await writeFile(workerConfigPath,JSON.stringify(workerConfig,null,2)+'\n',{mode:0o600});
let server,origin;
const start=async()=>{server=createServer({dataDir:workerConfig.dataDir,adminToken:state.adminToken});server.listen(0,'127.0.0.1');await once(server,'listening');origin=`http://127.0.0.1:${server.address().port}`;};
const stop=async()=>{server.closeAllConnections();await new Promise((r,j)=>server.close(e=>e?j(e):r()));server.closeDatabase();};
const request=(url,options={})=>fetch(origin+url,{...options,headers:{...(state.auth?{Authorization:`Bearer ${state.auth.token}`} : {}),...options.headers},redirect:'error',signal:AbortSignal.timeout(60000)});
const json=async(url,options)=>{const r=await request(url,options);const d=await r.json();if(!r.ok)throw Error(`HTTP ${r.status} ${d.error?.code??''}`);return d;};
const base=`/v2/video-reconstructions/${state.id}`;
const report={id:state.id,startedAt:new Date().toISOString(),sourceVideoSha256:inputSHA,sourceByteSize:size,sourceKind:'external_rgb_video',events:[],iphoneVerified:false};
const downloads=path.join(directory,'downloads');await mkdir(downloads,{recursive:true});report.results=[];
async function downloadReady(reconstruction) {
  for(const task of reconstruction.tasks.filter(t=>t.status==='ready')) {
    const v=task.result;assert.ok(v);
    if(report.results.some(r=>r.id===v.id&&r.sha256===v.sha256))continue;
    const model=await request(v.filePath);assert.equal(model.status,200);const bytes=Buffer.from(await model.arrayBuffer());
    assert.equal(bytes.length,v.byteSize);assert.equal(createHash('sha256').update(bytes).digest('hex'),v.sha256);
    await writeFile(path.join(downloads,`${v.role}.${v.format}`),bytes);
    const cr=await request(v.cameraPath);assert.equal(cr.status,200);const cb=Buffer.from(await cr.arrayBuffer());
    assert.equal(cb.length,v.cameraByteSize);assert.equal(createHash('sha256').update(cb).digest('hex'),v.cameraSha256);
    await writeFile(path.join(downloads,`${v.role}.cameras.json`),cb);
    const range=await request(v.filePath,{headers:{Range:'bytes=0-31'}});assert.equal(range.status,206);
    assert.deepEqual(Buffer.from(await range.arrayBuffer()),bytes.subarray(0,32));
    report.results.push({...v,cameraCount:JSON.parse(cb).frames.length,rangeVerified:true,downloadVerifiedAt:new Date().toISOString(),otherBranchStillPending:reconstruction.tasks.some(t=>t.status!=='ready')});
    console.log(JSON.stringify({stage:'result_download_verified',role:v.role,byteSize:v.byteSize,cameras:JSON.parse(cb).frames.length}));
    await writeFile(reportFile,JSON.stringify(report,null,2)+'\n');
  }
}
await start();
try {
  if(!state.auth){state.auth=await json('/v1/auth/anonymous',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});await persist();}
  await json('/v2/video-reconstructions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:state.id,title:config.title??'水杯视频自动双重建',consentVersion:'2026-11-03-video-dual-v1',expectedSha256:inputSHA,expectedByteSize:size})});
  let response=await json(base+'/video',{method:'PUT',headers:{'Content-Type':'video/mp4'},body:await openAsBlob(config.videoPath,{type:'video/mp4'})});
  assert.equal(response.reconstruction.tasks.length,2);
  let ids=response.reconstruction.tasks.map(t=>t.id).sort();
  response=await json(base+'/video',{method:'PUT',headers:{'Content-Type':'video/mp4'},body:await openAsBlob(config.videoPath,{type:'video/mp4'})});
  assert.deepEqual(response.reconstruction.tasks.map(t=>t.id).sort(),ids);report.duplicateUploadCreatesNoExtraTasks=true;
  if(args.includes('--retry-failed-task')) {
    const failedTaskId=option('--retry-failed-task');
    assert.match(failedTaskId,/^[a-f0-9-]{36}$/,'Retry requires a concrete failed task ID.');
    state.retryRequests??={};state.retryRequests[failedTaskId]??=randomUUID();await persist();
    const retryRequest={failedTaskId,id:state.retryRequests[failedTaskId]};
    response=await json(base+'/retry',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(retryRequest)});
    ids=response.reconstruction.tasks.map(t=>t.id).sort();
    const repeated=await json(base+'/retry',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(retryRequest)});
    assert.deepEqual(repeated.reconstruction.tasks.map(t=>t.id).sort(),ids);
    report.explicitRetry={...retryRequest,idempotencyVerified:true};
  }
  console.log(JSON.stringify({stage:'uploaded',id:state.id,tasks:response.reconstruction.tasks.map(t=>({id:t.id,algorithm:t.algorithm,status:t.status}))}));
  const deadline=Date.now()+(config.maxWaitMs??1200000);let previous='',cycles=0,restarted=false;
  while(true){
    response=await json(base);const reconstruction=response.reconstruction;report.reconstruction=reconstruction;
    const snapshot=JSON.stringify(reconstruction.tasks.map(t=>({algorithm:t.algorithm,status:t.status,phase:t.phase,error:t.error})));
    if(snapshot!==previous){previous=snapshot;const event={at:new Date().toISOString(),tasks:JSON.parse(snapshot)};report.events.push(event);console.log(JSON.stringify(event));await writeFile(reportFile,JSON.stringify(report,null,2)+'\n');}
    await downloadReady(reconstruction);
    if(reconstruction.tasks.every(t=>t.status==='ready'))break;
    if(reconstruction.tasks.every(t=>['ready','failed','blocked'].includes(t.status)))throw Error('A real branch requires inspection; no new job was created.');
    if(Date.now()>deadline)throw Error('Pilot wait limit reached; same persistent jobs can be resumed.');
    // A fresh OS worker process every cycle exercises its durable queue and provider journals.
    const result=await run(process.execPath,[path.join(root,'server/tools/dual-reconstruction-worker.mjs'),'--config',workerConfigPath,'--once'],{cwd:root,windowsHide:true,timeout:300000,maxBuffer:4*1024*1024});
    report.workerCycles=++cycles;report.freshWorkerProcessPerCycle=true;
    if(result.stdout.trim())console.log(result.stdout.trim());
    if(!restarted&&cycles>=2){await stop();await start();restarted=true;report.apiRestartVerified=true;const resumed=await json(base);assert.deepEqual(resumed.reconstruction.tasks.map(t=>t.id).sort(),ids);}
    await new Promise(r=>setTimeout(r,5000));
  }
  assert.equal(report.results.length,2);
  report.passed=true;report.finishedAt=new Date().toISOString();await writeFile(reportFile,JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify({passed:true,id:state.id,reportFile,results:report.results.map(r=>({role:r.role,pointCount:r.pointCount,byteSize:r.byteSize,sha256:r.sha256,cameras:r.cameraCount}))},null,2));
}catch(error){report.passed=false;report.error=error.message;report.finishedAt=new Date().toISOString();await writeFile(reportFile,JSON.stringify(report,null,2)+'\n');console.error(error.message);process.exitCode=1;}
finally{await stop();}
