import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { openVideoReconstructionRepository } from '../src/video-reconstructions.mjs';
import { normalizeDualWorkerConfig, runDualWorkerOnce, selectTimestampedFrames } from '../src/dual-reconstruction-worker.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const box = (name, body) => { const h=Buffer.alloc(8);h.writeUInt32BE(body.length+8);h.write(name,4);return Buffer.concat([h,body]); };
const sourceBytes = Buffer.concat(['moov','mdat'].map(n=>box(n,Buffer.from('SYNTHETIC TEST CONTAINER; NOT A CAMERA VIDEO'))));
const baseNames = ['x','y','z','f_dc_0','f_dc_1','f_dc_2','opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3'];
const sh3 = Buffer.from(`ply\nformat ascii 1.0\ncomment SYNTHETIC WORKER TEST\nelement vertex 1\n${[...baseNames,...Array.from({length:45},(_,i)=>`f_rest_${i}`)].map(n=>`property float ${n}`).join('\n')}\nend_header\n${[0,0,-1,.1,.2,.3,1,-3,-3,-3,1,0,0,0,...Array(45).fill(0)].join(' ')}\n`);
const splat=Buffer.alloc(32,128);[0,0,-1,.1,.1,.1].forEach((v,i)=>splat.writeFloatLE(v,i*4));splat[28]=255;
const cameras={version:1,coordinateSystem:'opengl_camera_to_world',matrixLayout:'row-major',scale:'unknown',frames:[
  {sourceFrame:'synthetic.jpg',timeSeconds:0,width:320,height:240,fx:200,fy:200,cx:160,cy:120,cameraToWorld:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]},
]};

async function fixture(t) {
  const directory=await mkdtemp(path.join(tmpdir(),'pw-dual-worker-test-'));
  const config={dataDir:path.join(directory,'data'),workDir:path.join(directory,'work'),hubOrigin:'http://127.0.0.1:1',successStatus:'SUCCESS',plyProfile:'worldmirror2-probability-v1',ffFrameCount:2,sfmFrameCount:2};
  let repository=openVideoReconstructionRepository(config);
  const owner=randomUUID(),id=randomUUID(),temporary=path.join(directory,'source.upload');
  await writeFile(temporary,sourceBytes);
  repository.create(owner,{id,title:'SYNTHETIC TEST ONLY',consentVersion:'2026-11-03-video-dual-v1',expectedSha256:sha(sourceBytes),expectedByteSize:sourceBytes.length});
  await repository.acceptVideo(id,owner,{temporary,mime:'video/mp4',hash:sha(sourceBytes),size:sourceBytes.length});
  const x={directory,config,owner,id,get repository(){return repository;},extractCalls:0,materializeCalls:0};
  x.reopen=()=>{repository.close();repository=openVideoReconstructionRepository(config);};
  x.extractFrames=async({directory,source,frameCount,beforeMutation})=>{
    await beforeMutation();const manifestPath=path.join(directory,'test-frames.json');
    if(!(await readFile(manifestPath).catch(()=>null))){x.extractCalls++;await writeFile(manifestPath,JSON.stringify({testOnly:true,sourceVideoSha256:source.sourceVideoSha256,frameCount}));}
    return {directory,manifestPath,frames:Array.from({length:frameCount},(_,i)=>({index:i,file:`image_${String(i+1).padStart(4,'0')}.jpg`,sourceTimestampSeconds:i,sourceFrameIndex:i,sha256:'0'.repeat(64),byteSize:1}))};
  };
  x.materialize=async({directory,job,source,providerResult})=>{
    x.materializeCalls++;
    const modelFile=path.join(directory,job.role==='preview'?'fixture.splat':'fixture.ply'),cameraFile=path.join(directory,'fixture-cameras.json');
    await writeFile(modelFile,job.role==='preview'?splat:sh3);await writeFile(cameraFile,JSON.stringify(cameras));
    return {modelFile,cameraFile,provenance:{sourceVideoSha256:source.sourceVideoSha256,projectId:providerResult.projectId,stepId:providerResult.stepId,testOnly:true}};
  };
  x.run=providerStep=>runDualWorkerOnce(config,{repository,providerStep,extractFrames:x.extractFrames,materialize:x.materialize});
  t.after(async()=>{repository.close();await rm(directory,{recursive:true,force:true});});
  return x;
}

test('worker publishes independent branches, resumes persistent claims and never reprocesses ready tasks',async t=>{
  const x=await fixture(t);const calls=new Map();
  const provider=async({algorithm,beforeMutation,directory})=>{
    await beforeMutation();await mkdir(directory,{recursive:true});
    const count=(calls.get(algorithm)??0)+1;calls.set(algorithm,count);
    return {status:algorithm==='gs_mcmc'&&count===1?'processing':'ready',phase:'fixture_provider',projectId:'fixture-project',stepId:'fixture-'+algorithm};
  };
  const first=await x.run(provider);assert.equal(first.jobs.length,2);
  const partial=x.repository.get(x.id,x.owner);assert.equal(partial.status,'partial');assert.equal(partial.tasks.find(t=>t.role==='preview').status,'ready');
  assert.equal(x.materializeCalls,1);x.reopen();
  const second=await x.run(provider);assert.equal(second.workerId,first.workerId);assert.equal(second.jobs.length,1);assert.equal(x.repository.get(x.id,x.owner).status,'ready');
  assert.equal(x.extractCalls,2);assert.equal(x.materializeCalls,2);
  const third=await x.run(provider);assert.equal(third.phase,'idle');assert.equal(calls.get('gs_worldmirror2'),1);assert.equal(calls.get('gs_mcmc'),2);
  const full=x.repository.get(x.id,x.owner).tasks.find(t=>t.role==='refined').result;assert.equal(full.sha256,sha(sh3));assert.equal(full.shDegree,3);
});

test('one provider failure preserves the successful independent result',async t=>{
  const x=await fixture(t);
  await x.run(async({algorithm})=>algorithm==='gs_mcmc'
    ?{status:'failed',phase:'fixture_training_failed',error:{code:'provider_failed',message:'SYNTHETIC failure'}}
    :{status:'ready',phase:'fixture_ready',projectId:'fixture-project',stepId:'fixture-step'});
  const result=x.repository.get(x.id,x.owner);assert.equal(result.status,'partial');
  assert.equal(result.tasks.find(t=>t.role==='refined').status,'failed');assert.equal(result.tasks.find(t=>t.role==='preview').status,'ready');
  assert.equal((await x.run(()=>assert.fail('terminal tasks must not rerun'))).phase,'idle');
});

test('ambiguous remote writes block further ticks instead of submitting again',async t=>{
  const x=await fixture(t);let calls=0;
  await x.run(async()=>{calls++;const e=new Error('Response lost after write');e.code='mutation_unresolved';e.outcomeUnknown=true;throw e;});
  assert.equal(calls,2);assert.equal(x.repository.get(x.id,x.owner).status,'blocked');
  assert.equal((await x.run(()=>{calls++;assert.fail('ambiguous writes must not repeat');})).phase,'idle');
  assert.equal(x.materializeCalls,0);assert.equal(calls,2);
});

test('source mutation before result import prevents every published asset',async t=>{
  const x=await fixture(t);
  await x.run(async()=>{
    const job=x.repository.pendingJobs()[0],source=x.repository.source(job.id,job.claimId);
    await writeFile(source.sourceVideoPath,Buffer.alloc(source.sourceByteSize));
    return {status:'ready',phase:'fixture_ready',projectId:'fixture-project',stepId:'fixture-step'};
  });
  assert.equal(x.materializeCalls,0);assert.ok(x.repository.get(x.id,x.owner).tasks.every(t=>!t.result));
});

test('profile changes and a live global lock stop before provider work',async t=>{
  const x=await fixture(t);
  assert.throws(()=>normalizeDualWorkerConfig({...x.config,ffFrameCount:17}),{code:'invalid_config'});
  await x.run(async()=>({status:'processing',phase:'fixture_running'}));
  await assert.rejects(runDualWorkerOnce({...x.config,hubOrigin:'http://127.0.0.1:2'},{repository:x.repository}),{code:'worker_profile_mismatch'});
  await writeFile(path.join(x.config.workDir,'.dual-worker.lock'),JSON.stringify({pid:process.pid,nonce:randomUUID()}));
  await assert.rejects(x.run(()=>assert.fail('live worker lock must stop work')),{code:'worker_busy'});
});

test('transient artifact reads resume packaging without losing the other ready branch',async t=>{
  const x=await fixture(t), original=x.materialize;
  let first=true;
  x.materialize=async options=>{
    if(options.job.role==='preview'&&first){first=false;const e=new Error('SYNTHETIC read timeout');e.retryable=true;throw e;}
    return original(options);
  };
  const provider=async()=>({status:'ready',phase:'fixture_cached_ready',projectId:'fixture-project',stepId:'fixture-step'});
  const a=await x.run(provider);assert.equal(a.jobs.find(j=>j.algorithm==='gs_worldmirror2').status,'processing');
  assert.equal(x.repository.get(x.id,x.owner).tasks.find(t=>t.role==='refined').status,'ready');
  const b=await x.run(provider);assert.equal(b.jobs.length,1);assert.equal(x.repository.get(x.id,x.owner).status,'ready');
});

test('timestamp selection uses variable-rate source times and rejects nonmonotonic input',()=>{
  const source=[0,.01,.02,.6,2,8,10].map((timestampSeconds,sourceFrameIndex)=>({timestampSeconds,sourceFrameIndex}));
  const selected=selectTimestampedFrames(source,3);
  assert.deepEqual(selected.map(f=>f.sourceFrameIndex),[3,4,6]);
  assert.throws(()=>selectTimestampedFrames([{timestampSeconds:0},{timestampSeconds:0}],2),{code:'invalid_timestamps'});
  assert.throws(()=>selectTimestampedFrames(source,8),{code:'insufficient_frames'});
});

test('native metadata tampering before or after provider work prevents publishing either result',async t=>{
  for(const when of ['before','after']) {
    await t.test(when,async t=>{
      const x=await fixture(t),metadataPath=path.join(x.directory,'SYNTHETIC_NATIVE_METADATA.json');
      const bytes=Buffer.from('{"testOnly":"SYNTHETIC native-source boundary fixture"}');
      await writeFile(metadataPath,bytes);
      const lineage={sourceKind:'native_arkit_capture',captureId:randomUUID(),captureReceiptId:randomUUID(),
        sourceMetadataPath:metadataPath,sourceMetadataSha256:sha(bytes),sourceMetadataByteSize:bytes.length};
      const original=x.repository.source;
      const repository={...x.repository,source:(...args)=>({...original(...args),...lineage})};
      if(when==='before')await writeFile(metadataPath,Buffer.alloc(bytes.length));
      let calls=0,mutation;
      const providerStep=async()=>{
        calls++;mutation??=writeFile(metadataPath,Buffer.alloc(bytes.length));await mutation;
        return {status:'ready',phase:'fixture_ready',projectId:'fixture-project',stepId:'fixture-step'};
      };
      const result=await runDualWorkerOnce(x.config,{repository,providerStep,extractFrames:x.extractFrames,materialize:x.materialize});
      if(when==='before')assert.equal(calls,0);
      assert.equal(x.materializeCalls,0);assert.ok(result.jobs.every(j=>j.status==='blocked'));
      assert.ok(x.repository.get(x.id,x.owner).tasks.every(j=>!j.result));
      const binding=JSON.parse(await readFile(path.join(x.config.workDir,result.jobs[0].jobId,'source-binding.json'),'utf8'));
      assert.equal(binding.captureId,lineage.captureId);assert.equal(binding.sourceMetadataSha256,lineage.sourceMetadataSha256);
    });
  }
});

test('ARKit task pairs frames with recorded poses and hands the prior only to its own provider step',async t=>{
  const x=await fixture(t),config={...x.config,sfmFrameCount:4,maxConcurrentJobs:3};
  // SYNTHETIC frame table: video frame i at i seconds, camera i/10 m along x.
  const table=Array.from({length:4},(_,i)=>({index:i,videoPTSSeconds:i,arTimestampSeconds:i,trackingState:'normal',
    cameraToWorldARKit:[[1,0,0,i/10],[0,1,0,0],[0,0,1,0],[0,0,0,1]]}));
  const bytes=Buffer.from(JSON.stringify({framesJSONL:table.map(f=>JSON.stringify(f)).join('\n')+'\n'}));
  const metadataPath=path.join(x.directory,'SYNTHETIC_ARKIT_METADATA.json');await writeFile(metadataPath,bytes);
  const lineage={sourceKind:'native_arkit_capture',captureId:randomUUID(),captureReceiptId:randomUUID(),
    sourceMetadataPath:metadataPath,sourceMetadataSha256:sha(bytes),sourceMetadataByteSize:bytes.length};
  // The optional third task is inserted directly; its API path is covered in capture-v2 tests.
  const db=new DatabaseSync(path.join(config.dataDir,'pocketworld.sqlite')),taskId=randomUUID(),date=new Date().toISOString();
  db.prepare('INSERT INTO video_reconstruction_tasks_v2 (id,reconstructionId,algorithm,role,status,phase,createdAt,updatedAt) VALUES (?,?,?,?,?,?,?,?)')
    .run(taskId,x.id,'gs_mcmc_arkit_prior','arkit','queued','awaiting_worker',date,date);db.close();
  const original=x.repository.source,repository={...x.repository,source:(...args)=>({...original(...args),...lineage})};
  const seen=new Map();
  const providerStep=async({algorithm,posePriorCSV,beforeMutation})=>{
    await beforeMutation();seen.set(algorithm,posePriorCSV);return {status:'processing',phase:'fixture_waiting'};
  };
  const result=await runDualWorkerOnce(config,{repository,providerStep,extractFrames:x.extractFrames,materialize:x.materialize});
  assert.equal(result.jobs.length,3);
  assert.equal(seen.get('gs_worldmirror2'),undefined);assert.equal(seen.get('gs_mcmc'),undefined);
  const lines=seen.get('gs_mcmc_arkit_prior').trim().split('\n');
  assert.equal(lines[0],'image_name,camera_id,timestamp_ns,center_x,center_y,center_z,qw,qx,qy,qz,position_std_m');
  assert.deepEqual(lines.slice(1).map(l=>l.split(',').slice(0,4)),
    [0,1,2,3].map(i=>[`image_00000${i+1}.jpg`,'iphone_arkit',String(i*1e9),(i/10).toFixed(9)]));
});
