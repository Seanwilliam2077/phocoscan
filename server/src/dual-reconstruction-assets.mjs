import { checkNativeSfM } from './sfm-quality.mjs';
import { validateSPZ } from './spz.mjs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const executeFile = promisify(execFile);
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir, copyFile, open, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { sha256File } from './worldmirror-client.mjs';
import { validateGaussian } from './validation.mjs';
import { validateStudyCameras } from './reconstruction-studies.mjs';

const toolPath=fileURLToPath(new URL('../tools/read-hub-cameras.py',import.meta.url));
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
function artifactError(code,message,retryable=false) {
  return Object.assign(Error(message),{code,retryable});
}
function sshExitError(code,stderr) {
  // Only known transport failures are safe to retry. Authentication, host-key,
  // remote decoding and exact-task validation failures need operator attention.
  const denied=/permission denied|host key verification failed|remote host identification has changed|bad configuration|bad permissions|invalid format/i.test(stderr);
  const transport=/connection (?:timed out|refused|reset|closed)|operation timed out|no route to host|network is unreachable|temporary failure in name resolution|broken pipe/i.test(stderr);
  if(code===255&&!denied&&transport)return artifactError('artifact_transport_failed','Read-only artifact transport failed',true);
  if(code===65)return artifactError('artifact_verification_mismatch','Exact-task artifact verification failed');
  return artifactError('artifact_read_failed','Read-only artifact command failed');
}
export async function sshEvidence(config, request, {spawnProcess=spawn,timeoutMs=45000}={}) {
  const s=config.artifactSSH;
  assert.ok(s && /^[A-Za-z0-9.-]+$/.test(s.host) && /^[A-Za-z0-9_-]+$/.test(s.user),'Configure authorized artifactSSH host/user');
  assert.ok(Number.isInteger(s.port)&&s.port>0&&s.port<65536&&path.isAbsolute(s.identityFile));
  const encoded=Buffer.from(JSON.stringify(request)).toString('base64');
  const input=`REQUEST_B64 = '${encoded}'\n`+await readFile(toolPath,'utf8');
  return runEvidence('ssh',['-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-i',s.identityFile,'-p',String(s.port),`${s.user}@${s.host}`,'sudo','-n','python3','-'],input,{spawnProcess,timeoutMs});
}
export async function localEvidence(config,request,{spawnProcess=spawn,timeoutMs=45000}={}) {
  const local=config.artifactLocal;
  assert.ok(local&&path.isAbsolute(local.pythonPath)&&path.isAbsolute(local.helperPath),'Configure absolute local helper paths');
  assert.equal(typeof local.useSudo,'boolean');
  const input=JSON.stringify(request);assert.ok(Buffer.byteLength(input)<=16384);
  const command=local.useSudo?'sudo':local.pythonPath;
  const args=local.useSudo?['-n',local.pythonPath,'-I',local.helperPath]:['-I',local.helperPath];
  return runEvidence(command,args,input,{spawnProcess,timeoutMs});
}
export async function readArtifactEvidence(config,request,dependencies) {
  assert.ok(!(config.artifactLocal&&config.artifactSSH),'Choose exactly one artifact transport');
  return config.artifactLocal?localEvidence(config,request,dependencies):sshEvidence(config,request,dependencies);
}
async function runEvidence(command,args,input,{spawnProcess,timeoutMs}) {
  return await new Promise((resolve,reject)=>{
    const proc=spawnProcess(command,args,{windowsHide:true});
    const chunks=[];let size=0,stderr='',settled=false;const fail=error=>{if(!settled){settled=true;clearTimeout(timer);reject(error);}};
    const timer=setTimeout(()=>{fail(artifactError('artifact_transport_timeout','Read-only camera artifact request timed out',true));proc.kill();},timeoutMs);
    proc.stdout.on('data',b=>{size+=b.length;if(size>16*1024*1024){fail(artifactError('artifact_response_invalid','Camera response exceeds limit'));proc.kill();}else chunks.push(b);});
    // Keep a bounded diagnostic only for classification, never in public errors.
    proc.stderr.on('data',b=>{if(stderr.length<16384)stderr=(stderr+b.toString('utf8')).slice(0,16384);});
    proc.on('error',()=>fail(artifactError('artifact_transport_unavailable','Cannot start the artifact transport')));
    proc.stdin.on('error',e=>{if(e.code!=='EPIPE')fail(artifactError('artifact_transport_unavailable','Cannot write artifact transport request'));});
    proc.on('close',code=>{if(settled)return;clearTimeout(timer);if(code!==0){fail(sshExitError(code,stderr));return;}
      try{const parsed=JSON.parse(Buffer.concat(chunks));settled=true;resolve(parsed);}catch{fail(artifactError('artifact_response_invalid','Invalid camera artifact response'));}});
    proc.stdin.end(input);
  });
}
function validateEvidenceBinding(evidence,request) {
  assert.equal(evidence.sourcePlySHA256,request.plySha256,'Cached exact-task model changed');
  for(const k of ['projectId','stepId','groupId','algorithm'])assert.equal(evidence[k],request[k],`Artifact ${k} mismatch`);
  assert.equal(evidence.status,'SUCCESS');
  return evidence;
}
export async function cachedArtifactEvidence(config,request,filename,{readEvidence=readArtifactEvidence}={}) {
  let text;
  try{text=await readFile(filename,'utf8');}catch(e){if(e.code!=='ENOENT')throw e;}
  if(text!==undefined) {
    let evidence;
    try{evidence=JSON.parse(text);}catch(e){if(!(e instanceof SyntaxError))throw e;}
    // A legacy interrupted write may be fetched again, but a valid mismatched
    // cache must fail closed instead of being silently replaced.
    if(evidence!==undefined)return validateEvidenceBinding(evidence,request);
  }
  const evidence=validateEvidenceBinding({...await readEvidence(config,request),sourcePlySHA256:request.plySha256},request);
  const temporary=filename+'.'+randomUUID()+'.tmp';let file;
  try {
    file=await open(temporary,'wx');await file.writeFile(JSON.stringify(evidence,null,2)+'\n');await file.sync();await file.close();file=null;
    await rename(temporary,filename);
  }finally{if(file)await file.close();await rm(temporary,{force:true});}
  return evidence;
}
export function validateSfMExport(check,pointCount) {
  assert.ok(check&&check.N_written===pointCount,'Final export count differs');
  for(const name of ['header_62_match','n_written','transform_roundtrip','bbox_vs_colmap_points','unnormalization_applied']) {
    assert.equal(check.checks?.[name],true,`SfM export check failed: ${name}`);
  }
}
function rotation(q) {const n=Math.hypot(...q);assert.ok(Math.abs(n-1)<1e-4);const[w,x,y,z]=q.map(v=>v/n);return [[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]];}
function inverseRigid(m) {const r=m.slice(0,3),t=r.map(x=>x[3]);return[0,1,2].map(i=>[r[0][i],r[1][i],r[2][i],-r.reduce((s,row,j)=>s+row[i]*t[j],0)]).concat([[0,0,0,1]]);}
function camera(frame,k,width,height,m,name) {return{sourceFrame:name,timeSeconds:frame.sourceTimestampSeconds,width,height,fx:k[0][0],fy:k[1][1],cx:k[0][2],cy:k[1][2],cameraToWorld:m.map(row=>row.map((v,col)=>col===1||col===2?-v:v)).flat()};}

export function camerasFromEvidence(evidence,frames) {
  const source=frames.frames;let converted;
  if(evidence.algorithm==='gs_worldmirror2') {
    assert.equal(evidence.convention,'opencv_camera_to_world');
    converted=evidence.cameras.extrinsics.map(e=>{
      const mapping=evidence.selected.find(x=>x.cameraIndex===e.camera_id);assert.ok(mapping);
      const f=source[mapping.sourceIndex];assert.ok(f);assert.equal(mapping.sha256,f.sha256,'FF input frame changed');
      const k=evidence.cameras.intrinsics.find(x=>x.camera_id===e.camera_id);assert.ok(k);
      return camera(f,k.matrix,evidence.imageWidth,evidence.imageHeight,e.matrix,f.file);
    });
  } else {
    assert.equal(evidence.algorithm,'gs_mcmc');assert.equal(evidence.convention,'opencv_world_to_camera');
    const registeredSources=new Set();
    converted=evidence.images.map(image=>{
      const match=/^image_(\d{6})\.jpg$/.exec(image.name);assert.ok(match);
      const sourceIndex=Number(match[1])-1;
      assert.ok(!registeredSources.has(sourceIndex),'Duplicate SfM source mapping');registeredSources.add(sourceIndex);
      const f=source[sourceIndex];assert.ok(f);assert.equal(image.sha256,f.sha256,'SfM original input image changed');assert.equal(image.sourceName,f.file,'SfM image name mapping changed');
      const k=evidence.cameras.find(c=>c.id===image.cameraId);assert.ok(k);
      const r=rotation(image.worldToCamera.quaternionWXYZ),t=image.worldToCamera.translation;
      return camera(f,k.intrinsics,k.width,k.height,inverseRigid(r.map((row,i)=>[...row,t[i]]).concat([[0,0,0,1]])),image.name);
    });
  }
  if(evidence.algorithm==='gs_worldmirror2')assert.equal(converted.length,source.length,'Expected all selected FF images to register');
  else assert.ok(converted.length>=Math.max(2,Math.ceil(source.length*.5)),'SfM registered cameras must cover at least half of selected frames and at least two views');
  converted.sort((a,b)=>a.timeSeconds-b.timeSeconds);
  return validateStudyCameras({version:1,coordinateSystem:'opengl_camera_to_world',matrixLayout:'row-major',scale:'unknown',frames:converted});
}

export async function convertFullWorldMirror(source,destination,profile) {
  assert.equal(profile,'worldmirror2-probability-v1','Unverified WorldMirror opacity profile');
  let buffer,properties,written=0,count;
  const byte=x=>Math.round(Math.max(0,Math.min(255,x)));
  await validateGaussian(source,'ply',{onHeader(h){count=h.gaussianCount;assert.ok(count<=1000000);buffer=Buffer.alloc(count*32);properties=new Map(h.properties.map((p,i)=>[p.name,i]));},onRecord(row,i){
    const get=n=>row[properties.get(n)],o=i*32,a=get('opacity');assert.ok(a>=0&&a<=1,'Opacity profile mismatch');
    for(let k=0;k<3;k++){buffer.writeFloatLE(get(['x','y','z'][k]),o+k*4);const scale=Math.exp(get('scale_'+k));assert.ok(Number.isFinite(scale)&&scale>0);buffer.writeFloatLE(scale,o+12+k*4);buffer[o+24+k]=byte((.5+.28209479177387814*get('f_dc_'+k))*255);}
    buffer[o+27]=byte(a*255);const q=[0,1,2,3].map(k=>get('rot_'+k)),n=Math.hypot(...q);assert.ok(n>0&&Number.isFinite(n));q.forEach((v,k)=>buffer[o+28+k]=byte(128+128*v/n));written++;
  }});
  assert.equal(written,count);await writeFile(destination,buffer);await validateGaussian(destination,'splat');
  return{sha256:digest(buffer),pointCount:count,byteSize:buffer.length,profile,decimated:false,shDegree:0,lossy:true};
}

export async function materializeDualResult({directory,job,source,frames,providerResult,config}) {
  assert.ok(providerResult.plyPath&&providerResult.plySha256);
  assert.equal(await sha256File(providerResult.plyPath),providerResult.plySha256,'Provider PLY changed');
  // The ARKit-prior branch is the Hub's own gs_mcmc step; its artifacts are read as gs_mcmc.
  const usesPrior=job.algorithm==='gs_mcmc_arkit_prior',hubAlgorithm=usesPrior?'gs_mcmc':job.algorithm;
  const request={projectId:providerResult.projectId,stepId:providerResult.stepId,groupId:providerResult.groupId,imagesAssetId:providerResult.imagesAssetId,algorithm:hubAlgorithm,plySha256:providerResult.plySha256};
  const out=path.join(directory,'mobile-result');await mkdir(out,{recursive:true});
  const evidenceFile=path.join(out,'artifact-evidence.json');
  const evidence=await cachedArtifactEvidence(config,request,evidenceFile);
  if(hubAlgorithm==='gs_mcmc') {
    // The delivered Gaussian PLY is the unnormalized export matched to sfm_images cameras.
    validateSfMExport(evidence.exportCheck,providerResult.pointCount);
  }
  const cameras=camerasFromEvidence(evidence,frames),cameraFile=path.join(out,'cameras.json');
  const quality=hubAlgorithm==='gs_mcmc'?await checkNativeSfM(source,cameras,frames.frames.length):null;
  await writeFile(cameraFile,JSON.stringify(cameras,null,2)+'\n');
  const modelFile=path.join(out,job.algorithm==='gs_worldmirror2'?'scene.splat':'scene.ply');let conversion=null;
  if(job.algorithm==='gs_worldmirror2')conversion=await convertFullWorldMirror(providerResult.plyPath,modelFile,config.plyProfile);
  else {await copyFile(providerResult.plyPath,modelFile);assert.equal(await sha256File(modelFile),providerResult.plySha256);}
  let mobileFile=null, mobileConversion=null;
  if(config.splatExport && hubAlgorithm==='gs_mcmc') {
    const destination=path.join(out,'scene.spz');
    try {
      const {stdout}=await executeFile(config.splatExport.python,[config.splatExport.helper,modelFile,destination],{timeout:180000,maxBuffer:16384});
      mobileConversion=JSON.parse(stdout);
      await validateSPZ(destination,{pointCount:providerResult.pointCount,shDegree:3});mobileFile=destination;
    } catch { await rm(destination,{force:true});mobileConversion={available:false,reason:'derivative_validation_failed'}; }
  }
  return{modelFile,cameraFile,mobileFile,provenance:{sourceVideoSha256:source.sourceVideoSha256,projectId:request.projectId,stepId:request.stepId,groupId:request.groupId,algorithm:job.algorithm,...(usesPrior?{posePrior:'arkit_device_reported_camera_centres',posePriorSha256:providerResult.posePriorSha256??null}:{}),...(frames.selection==='phone_keyframes'?{inputFrames:'phone_keyframes',keyframesSha256:frames.keyframesSha256,masksAssetId:providerResult.masksAssetId??null,maskPolarity:providerResult.masksAssetId?'white_keep':null}:{}),imagesAssetId:providerResult.imagesAssetId,inputRevision:providerResult.inputRevision,originalPlySHA256:request.plySha256,artifactEvidenceSHA256:await sha256File(evidenceFile),cameraSHA256:await sha256File(cameraFile),selectedFrameCount:frames.frames.length,registeredCameraCount:cameras.frames.length,metricScaleVerified:false,crossVersionAlignmentVerified:false,quality,mobileConversion,conversion}};
}
