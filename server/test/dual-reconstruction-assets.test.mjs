import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import os from 'node:os';
import { sshEvidence, localEvidence, readArtifactEvidence, cachedArtifactEvidence, validateSfMExport, camerasFromEvidence, materializeDualResult } from '../src/dual-reconstruction-assets.mjs';

const request={projectId:'test_project',stepId:'test_step',groupId:'test_group',imagesAssetId:'test_asset',algorithm:'gs_mcmc',plySha256:'a'.repeat(64)};
const validEvidence=()=>({...request,status:'SUCCESS',sourcePlySHA256:request.plySha256});
const config={artifactSSH:{host:'unit-test.invalid',user:'test',port:36000,identityFile:path.resolve('TEST_ONLY.key')}};
test('local artifact reader executes only fixed isolated helper and passes request as JSON data',async()=>{
  const local={pythonPath:path.resolve('TEST_PYTHON'),helperPath:path.resolve('ROOT_OWNED_HELPER.py'),useSudo:true};
  let input='';
  const spawnProcess=(command,args,options)=>{
    assert.equal(command,'sudo');assert.deepEqual(args,['-n',local.pythonPath,'-I',local.helperPath]);assert.equal(options.shell,undefined);
    const proc=new EventEmitter();proc.stdout=new PassThrough();proc.stderr=new PassThrough();proc.stdin=new PassThrough();
    proc.kill=()=>{};proc.stdin.on('data',b=>input+=b);proc.stdin.on('finish',()=>setImmediate(()=>{
      proc.stdout.write(JSON.stringify(validEvidence()));proc.emit('close',0);
    }));return proc;
  };
  assert.deepEqual(await localEvidence({artifactLocal:local},request,{spawnProcess}),validEvidence());
  assert.deepEqual(JSON.parse(input),request);assert.ok(!input.includes('import '));
  await assert.rejects(readArtifactEvidence({...config,artifactLocal:local},request,{spawnProcess}),/one artifact transport/);
  await assert.rejects(localEvidence({artifactLocal:{...local,helperPath:'relative.py'}},request,{spawnProcess}),/absolute local helper paths/);
});
function fakeSSH({code=0,stderr='',stdout='{}',hang=false,brokenInput=false}={}) {
  let killed=false;
  return {get killed(){return killed;},spawnProcess(command,args,options){
    assert.equal(command,'ssh');assert.equal(options.windowsHide,true);assert.equal(options.shell,undefined);
    assert.deepEqual(args.slice(-4),['sudo','-n','python3','-']);
    const proc=new EventEmitter();proc.stdout=new PassThrough();proc.stderr=new PassThrough();proc.stdin=new PassThrough();proc.stdin.resume();
    proc.kill=()=>{killed=true;queueMicrotask(()=>proc.emit('close',null));};
    proc.stdin.on('finish',()=>{if(hang)return;setImmediate(()=>{
      if(brokenInput)proc.stdin.emit('error',Object.assign(Error('private diagnostic'),{code:'EPIPE'}));
      proc.stderr.write(stderr);proc.stdout.write(stdout);proc.emit('close',code);
    });});
    return proc;
  }};
}
async function temporary(t) {
  const directory=await mkdtemp(path.join(os.tmpdir(),'pw-artifact-test-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));return directory;
}

test('artifact SSH retries only recognized transport failures and hides diagnostics',async()=>{
  for(const scenario of [
    {code:255,stderr:'ssh: connect to host test port 22: Connection timed out\nPRIVATE_TOKEN',retryable:true,error:'artifact_transport_failed'},
    {code:255,stderr:'Connection reset by peer',brokenInput:true,retryable:true,error:'artifact_transport_failed'},
    {code:255,stderr:'Permission denied (publickey). Connection closed by remote host\nPRIVATE_TOKEN',retryable:false,error:'artifact_read_failed'},
    {code:255,stderr:'Host key verification failed.',retryable:false,error:'artifact_read_failed'},
    {code:255,stderr:'Unclassified SSH failure',retryable:false,error:'artifact_read_failed'},
    {code:65,stderr:'Exact-task artifact verification failed\nPRIVATE_TOKEN',retryable:false,error:'artifact_verification_mismatch'},
    {code:70,stderr:'Remote decoder failed',retryable:false,error:'artifact_read_failed'},
    {code:1,stderr:'sudo: a password is required',retryable:false,error:'artifact_read_failed'},
  ]) {
    const fake=fakeSSH(scenario);
    await assert.rejects(sshEvidence(config,request,fake),e=>e.code===scenario.error&&e.retryable===scenario.retryable&&!e.message.includes('PRIVATE_TOKEN'));
  }
  assert.deepEqual(await sshEvidence(config,request,fakeSSH({stdout:JSON.stringify(validEvidence())})),validEvidence());
  await assert.rejects(sshEvidence(config,request,fakeSSH({stdout:'incomplete JSON'})),{code:'artifact_response_invalid',retryable:false});
});

test('artifact SSH timeout remains a transport retry and terminates its reader',async()=>{
  const fake=fakeSSH({hang:true});
  await assert.rejects(sshEvidence(config,request,{spawnProcess:fake.spawnProcess,timeoutMs:5}),{code:'artifact_transport_timeout',retryable:true});
  assert.equal(fake.killed,true);
});

test('SfM export gates every alignment and format check before publication',()=>{
  const names=['header_62_match','n_written','transform_roundtrip','bbox_vs_colmap_points','unnormalization_applied'];
  const good={N_written:143064,checks:Object.fromEntries(names.map(n=>[n,true]))};
  assert.doesNotThrow(()=>validateSfMExport(good,143064));
  assert.throws(()=>validateSfMExport(good,143065),/count differs/);
  for(const name of names) {
    for(const value of [false,undefined,'true'])assert.throws(()=>validateSfMExport({...good,checks:{...good.checks,[name]:value}},143064),new RegExp(name));
  }
});

test('atomic artifact cache recovers a truncated legacy write and reuses exact evidence',async t=>{
  const directory=await temporary(t),filename=path.join(directory,'artifact-evidence.json');let reads=0;
  await writeFile(filename,'{"projectId":');
  // An orphaned temporary file from a killed process is never treated as evidence.
  await writeFile(filename+'.orphan.tmp','{"wrongStep":true}');
  const readEvidence=async()=>{reads++;return validEvidence();};
  assert.deepEqual(await cachedArtifactEvidence({},request,filename,{readEvidence}),validEvidence());
  assert.deepEqual(JSON.parse(await readFile(filename,'utf8')),validEvidence());
  assert.deepEqual(await cachedArtifactEvidence({},request,filename,{readEvidence}),validEvidence());
  assert.equal(reads,1);
  assert.deepEqual((await readdir(directory)).sort(),['artifact-evidence.json','artifact-evidence.json.orphan.tmp']);
});

test('artifact cache rejects a different exact step or model without replacing it',async t=>{
  const directory=await temporary(t),filename=path.join(directory,'artifact-evidence.json');let reads=0;
  for(const wrong of [{...validEvidence(),stepId:'another_step'},{...validEvidence(),sourcePlySHA256:'b'.repeat(64)}]) {
    const original=JSON.stringify(wrong);await writeFile(filename,original);
    await assert.rejects(cachedArtifactEvidence({},request,filename,{readEvidence:async()=>{reads++;return validEvidence();}}));
    assert.equal(await readFile(filename,'utf8'),original);
  }
  assert.equal(reads,0);
});

test('failed fresh artifact verification creates no cache or partial replacement',async t=>{
  const directory=await temporary(t),filename=path.join(directory,'artifact-evidence.json');
  await assert.rejects(cachedArtifactEvidence({},request,filename,{readEvidence:async()=>({...validEvidence(),stepId:'another_step'})}));
  assert.deepEqual(await readdir(directory),[]);
  await writeFile(filename,'truncated');
  await assert.rejects(cachedArtifactEvidence({},request,filename,{readEvidence:async()=>{throw Object.assign(Error('transport failed'),{retryable:true});}}),{retryable:true});
  assert.equal(await readFile(filename,'utf8'),'truncated');
  assert.deepEqual(await readdir(directory),['artifact-evidence.json']);
});

// Explicitly synthetic poses and immutable source hashes for mapping tests.
function sfmCameras(selectedCount,registered=Array.from({length:selectedCount},(_,i)=>i)) {
  const frames={frames:Array.from({length:selectedCount},(_,i)=>({file:`source_${i}.jpg`,sha256:i.toString(16).padStart(64,'0'),sourceTimestampSeconds:i*.1}))};
  const evidence={algorithm:'gs_mcmc',convention:'opencv_world_to_camera',
    cameras:[{id:1,width:640,height:480,intrinsics:[[500,0,320],[0,500,240],[0,0,1]]}],
    images:registered.map(i=>({name:`image_${String(i+1).padStart(6,'0')}.jpg`,sourceName:frames.frames[i].file,sha256:frames.frames[i].sha256,
      cameraId:1,worldToCamera:{quaternionWXYZ:[1,0,0,0],translation:[-i,0,0]}}))};
  return {frames,evidence};
}
function ffCameras(count) {
  const {frames}=sfmCameras(count);
  const evidence={algorithm:'gs_worldmirror2',convention:'opencv_camera_to_world',imageWidth:640,imageHeight:480,
    selected:frames.frames.map((f,i)=>({cameraIndex:i,sourceIndex:i,sha256:f.sha256})),
    cameras:{extrinsics:frames.frames.map((_,i)=>({camera_id:i,matrix:[[1,0,0,i],[0,1,0,0],[0,0,1,0],[0,0,0,1]]})),
      intrinsics:frames.frames.map((_,i)=>({camera_id:i,matrix:[[500,0,320],[0,500,240],[0,0,1]]}))}};
  return {frames,evidence};
}

test('partial SfM cameras retain only registered views with exact source times, hashes and poses',()=>{
  const {frames,evidence}=sfmCameras(6,[5,0,2]);
  const converted=camerasFromEvidence(evidence,frames);
  assert.deepEqual(converted.frames.map(f=>f.sourceFrame),['image_000001.jpg','image_000003.jpg','image_000006.jpg']);
  assert.deepEqual(converted.frames.map(f=>f.timeSeconds),[0,.2,.5]);
  converted.frames.forEach((f,i)=>assert.ok(Math.abs(f.cameraToWorld[3]-[0,2,5][i])<1e-12));
  assert.equal(converted.frames.length,3);
  evidence.images[0].sha256='f'.repeat(64);
  assert.throws(()=>camerasFromEvidence(evidence,frames),/original input image changed/);
});

test('SfM rejects duplicate source registration and coverage below ceil-half or two views',()=>{
  const duplicate=sfmCameras(4,[0,1,1]);
  assert.throws(()=>camerasFromEvidence(duplicate.evidence,duplicate.frames),/Duplicate SfM source mapping/);
  for(const [count,registered] of [[5,[0,1]],[3,[0]],[2,[1]]]) {
    const fixture=sfmCameras(count,registered);
    assert.throws(()=>camerasFromEvidence(fixture.evidence,fixture.frames),/at least half.*at least two/);
  }
  const validOdd=sfmCameras(5,[0,2,4]);
  assert.equal(camerasFromEvidence(validOdd.evidence,validOdd.frames).frames.length,3);
});

test('full 16-view FF and 64-view SfM stay intact while partial FF is rejected',()=>{
  const ff=ffCameras(16),sfm=sfmCameras(64);
  assert.equal(camerasFromEvidence(ff.evidence,ff.frames).frames.length,16);
  assert.equal(camerasFromEvidence(sfm.evidence,sfm.frames).frames.length,64);
  ff.evidence.cameras.extrinsics.pop();
  assert.throws(()=>camerasFromEvidence(ff.evidence,ff.frames),/all selected FF images/);
});

test('materializer records selected and actually registered camera counts without filling missing views',async t=>{
  const directory=await temporary(t),out=path.join(directory,'mobile-result');await mkdir(out);
  // TEST_ONLY full SH3 one-Gaussian PLY; no actual reconstruction is claimed.
  const names=['x','y','z','nx','ny','nz','f_dc_0','f_dc_1','f_dc_2',...Array.from({length:45},(_,i)=>'f_rest_'+i),'opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3'];
  const header=Buffer.from(`ply\nformat binary_little_endian 1.0\nelement vertex 1\n${names.map(n=>'property float '+n).join('\n')}\nend_header\n`);
  const record=Buffer.alloc(names.length*4);record.writeFloatLE(1,names.indexOf('rot_0')*4);
  const model=Buffer.concat([header,record]),plyPath=path.join(directory,'provider.ply');await writeFile(plyPath,model);
  const plySha256=createHash('sha256').update(model).digest('hex'),{frames,evidence}=sfmCameras(6,[5,0,2]);
  const checks=Object.fromEntries(['header_62_match','n_written','transform_roundtrip','bbox_vs_colmap_points','unnormalization_applied'].map(n=>[n,true]));
  await writeFile(path.join(out,'artifact-evidence.json'),JSON.stringify({...validEvidence(),...evidence,sourcePlySHA256:plySha256,exportCheck:{N_written:1,checks}}));
  const result=await materializeDualResult({directory,job:{algorithm:'gs_mcmc'},source:{sourceVideoSha256:'c'.repeat(64)},frames,
    providerResult:{...request,plyPath,plySha256,pointCount:1},config:{}});
  assert.equal(result.provenance.selectedFrameCount,6);assert.equal(result.provenance.registeredCameraCount,3);
  assert.equal(JSON.parse(await readFile(result.cameraFile,'utf8')).frames.length,3);
  assert.deepEqual(await readFile(result.modelFile),model);
});
