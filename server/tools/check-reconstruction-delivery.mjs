// Real-asset HTTP delivery acceptance on loopback. Does not simulate iOS rendering.
import { createServer } from '../src/server.mjs';
import { importReconstructionStudy, validateStudyCameras } from '../src/reconstruction-studies.mjs';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

const flags=process.argv.slice(2), value=key=>{const i=flags.indexOf(key);return i<0?null:flags[i+1];};
if(!value('--manifest') || !value('--work-dir'))throw Error('Use --manifest <study JSON> --work-dir <ignored private directory>.');
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const directory=path.resolve(value('--work-dir'));
assert.ok(directory.startsWith(path.join(root,'work')+path.sep),'Acceptance storage must be inside project work/.');
await mkdir(directory,{recursive:true});
const manifestPath=path.resolve(value('--manifest'));
const manifest=JSON.parse(await readFile(manifestPath,'utf8'));
const configFile=path.join(directory,'delivery-private.json');
let config;
try {config=JSON.parse(await readFile(configFile,'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;
  config={dataDir:path.join(directory,'data'),adminToken:randomBytes(32).toString('base64url')};}
let service,origin;
const start=async()=>{service=createServer({dataDir:config.dataDir,adminToken:config.adminToken,logger:{error:()=>{}}});service.listen(0,'127.0.0.1');await once(service,'listening');origin=`http://127.0.0.1:${service.address().port}`;};
const stop=async()=>{service.closeAllConnections();await new Promise((r,j)=>service.close(e=>e?j(e):r()));service.closeDatabase();};
const authHeaders=(auth=config.owner)=>({'Authorization':`Bearer ${auth.token}`});
const call=(route,options={})=>fetch(origin+route,{redirect:'error',signal:AbortSignal.timeout(45000),...options});
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const report={startedAt:new Date().toISOString(),studyId:manifest.id,sourceVideoSha256:manifest.sourceVideoSha256,checks:[],variants:[],iphoneVerified:false,newGPUJobsSubmitted:0};
const pass=name=>report.checks.push({name,passed:true});
await start();
try {
  if(!config.owner) {
    const response=await call('/v1/auth/anonymous',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});assert.equal(response.status,201);config.owner=await response.json();
    const other=await call('/v1/auth/anonymous',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});assert.equal(other.status,201);config.other=await other.json();
    await writeFile(configFile,JSON.stringify(config,null,2)+'\n',{mode:0o600});
  }
  const imported=await importReconstructionStudy({dataDir:config.dataDir,userId:config.owner.userId,manifestPath});
  assert.equal(imported.study.id,manifest.id);pass('real model/camera import');
  const again=await importReconstructionStudy({dataDir:config.dataDir,userId:config.owner.userId,manifestPath});assert.equal(again.imported,false);pass('idempotent repeated import');
  const unauth=await call('/v2/reconstruction-studies');assert.equal(unauth.status,401);pass('unauthenticated access denied');
  const wrong=await call(`/v2/reconstruction-studies/${manifest.id}`,{headers:authHeaders(config.other)});assert.equal(wrong.status,404);pass('other owner cannot read study');
  const list=await call('/v2/reconstruction-studies',{headers:authHeaders()});assert.equal(list.status,200);
  const studies=(await list.json()).studies;assert.equal(studies.filter(s=>s.id===manifest.id).length,1);pass('private list has exactly one immutable study');
  const response=await call(`/v2/reconstruction-studies/${manifest.id}`,{headers:authHeaders()});assert.equal(response.status,200);
  const study=(await response.json()).study;assert.equal(study.variants.length,2);assert.equal(study.sourceKind,'external_rgb_video');assert.equal(study.captureId,null);
  await mkdir(path.join(directory,'downloads'),{recursive:true});
  for(const variant of study.variants) {
    const startTime=performance.now();
    const model=await call(variant.filePath,{headers:authHeaders()});assert.equal(model.status,200);
    assert.equal(model.headers.get('x-content-sha256'),variant.sha256);
    const bytes=Buffer.from(await model.arrayBuffer());assert.equal(bytes.length,variant.byteSize);assert.equal(digest(bytes),variant.sha256);
    await writeFile(path.join(directory,'downloads',`${variant.role}.${variant.format}`),bytes);
    const cameras=await call(variant.cameraPath,{headers:authHeaders()});assert.equal(cameras.status,200);
    const cameraBytes=Buffer.from(await cameras.arrayBuffer());assert.equal(cameraBytes.length,variant.cameraByteSize);assert.equal(digest(cameraBytes),variant.cameraSha256);
    const cameraData=validateStudyCameras(JSON.parse(cameraBytes));
    await writeFile(path.join(directory,'downloads',`${variant.role}.cameras.json`),cameraBytes);
    const range=await call(variant.filePath,{headers:{...authHeaders(),Range:'bytes=0-127'}});assert.equal(range.status,206);assert.deepEqual(Buffer.from(await range.arrayBuffer()),bytes.subarray(0,128));
    const denied=await call(variant.filePath,{headers:authHeaders(config.other)});assert.equal(denied.status,404);
    if(variant.role==='refined') {const header=bytes.subarray(0,bytes.indexOf('end_header')).toString('ascii');for(let i=0;i<45;i++)assert.ok(header.includes(`property float f_rest_${i}\n`));assert.equal(variant.sha256,manifest.variants.find(v=>v.role==='refined').sha256);}
    report.variants.push({role:variant.role,format:variant.format,shDegree:variant.shDegree,pointCount:variant.pointCount,byteSize:bytes.length,sha256:variant.sha256,cameras:cameraData.frames.length,loopbackDownloadAndVerificationMs:Math.round(performance.now()-startTime)});
  }
  pass('both full files and camera sidecars match source hashes');pass('all 45 refined SH3 coefficients preserved');pass('range downloads and file ownership checked');
  const receipts=await call('/v2/captures',{headers:authHeaders()});assert.equal(receipts.status,200);const receiptData=await receipts.json();assert.equal(receiptData.captures.length,0);pass('external study creates no native capture or growth receipt');
  await stop();await start();
  const after=await call(`/v2/reconstruction-studies/${manifest.id}`,{headers:authHeaders()});assert.equal(after.status,200);pass('restart preserves study and owner authentication');
  // Delete only a disposable clone created by this acceptance run, never the real study.
  const clone={...manifest,id:randomUUID(),variants:manifest.variants.map(v=>({...v,sourceFile:path.resolve(path.dirname(manifestPath),v.sourceFile),sourceCameraFile:path.resolve(path.dirname(manifestPath),v.sourceCameraFile)}))};
  clone.sourceVideoFile=path.resolve(path.dirname(manifestPath),manifest.sourceVideoFile);
  const clonePath=path.join(directory,'delete-test-manifest.json');await writeFile(clonePath,JSON.stringify(clone));
  const cloneResult=await importReconstructionStudy({dataDir:config.dataDir,userId:config.owner.userId,manifestPath:clonePath});
  const deleted=await call(`/v2/reconstruction-studies/${clone.id}`,{method:'DELETE',headers:authHeaders()});assert.equal(deleted.status,200);
  const late=await call(cloneResult.study.variants[0].filePath,{headers:authHeaders()});assert.equal(late.status,404);
  await assert.rejects(importReconstructionStudy({dataDir:config.dataDir,userId:config.owner.userId,manifestPath:clonePath}),e=>e.code==='study_deleted');
  pass('deleted test copy cannot be downloaded or reimported');
  report.finishedAt=new Date().toISOString();report.passed=true;
  await writeFile(path.join(directory,'delivery-report.json'),JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report,null,2));
} catch(error) {
  report.passed=false;report.error=error.message;await writeFile(path.join(directory,'delivery-report.json'),JSON.stringify(report,null,2)+'\n');throw error;
} finally {await stop();}
