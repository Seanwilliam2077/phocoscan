import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { advanceDualProvider } from '../src/dual-reconstruction-provider.mjs';
import { WorldMirrorClient, WorldMirrorError } from '../src/worldmirror-client.mjs';

// HTTP, JPEG and Gaussian data below are explicitly SYNTHETIC interface fixtures.
// They do not represent an actual video, reconstruction or native-device render.
function ply(shDegree) {
  const props=['x','y','z','f_dc_0','f_dc_1','f_dc_2',...(shDegree===3?Array.from({length:45},(_,i)=>`f_rest_${i}`):[]),'opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3'];
  const values=props.map(name=>name==='z'||name==='rot_0'?1:name.startsWith('scale_')?-3:0);
  return Buffer.from(`ply\nformat ascii 1.0\ncomment SYNTHETIC TEST ONLY\nelement vertex 1\n${props.map(p=>`property float ${p}`).join('\n')}\nend_header\n${values.join(' ')}\n`);
}
async function harness(t, algorithm='gs_mcmc') {
  // The ARKit branch is the Hub's own gs_mcmc step; the mock reports it as such.
  const sfm=algorithm==='gs_mcmc'||algorithm==='gs_mcmc_arkit_prior',hubAlgorithm=sfm?'gs_mcmc':algorithm;
  const directory=await mkdtemp(path.join(tmpdir(),'dual-provider-')),framesDirectory=path.join(directory,'frames'),run=path.join(directory,'run');
  await mkdir(framesDirectory);await writeFile(path.join(framesDirectory,'image_0001.jpg'),'SYNTHETIC FRAME ONE');await writeFile(path.join(framesDirectory,'image_0002.jpg'),'SYNTHETIC FRAME TWO');
  const state={prepareReady:false,ready:false,failed:false,getFailures:0,badResult:false,ambiguousPath:null,usePosePrior:algorithm==='gs_mcmc_arkit_prior'},calls=[];
  const model=ply(sfm?3:0);
  const inputs=()=>({source_kind:'images',images:{id:'images_test',group_id:'group_test',kind:'images',image_count:2},
    ...(state.reportMasks?{masks:{id:state.reportMasks,kind:'masks'}}:{}),revision:1,prepared_revision:1,ready:true,needs_prepare:false,legacy:false});
  const output=()=>{
    const importStep={id:'prepare_test',project_id:'project_test',type:'gs_import',status:state.prepareReady?'SUCCESS':'RUNNING',exit_code:state.prepareReady?0:null,report:{image_sources:[{image_name:'image_000001.jpg',source_name:'image_0001.jpg'}]}};
    const step={id:state.badResult?'other_attempt':'step_test',project_id:'project_test',type:hubAlgorithm,status:state.failed?'FAILED':state.ready?'SUCCESS':'RUNNING',exit_code:state.ready?0:null,params:{input_revision:1,import_step_id:sfm?'prepare_test':null},report:{use_pose_prior:state.usePosePrior,phase:state.ready?'complete':'waiting_gpu',...state.failureReport}};
    return {algorithm:hubAlgorithm,project:{id:'project_test',group_id:'group_test'},step,import_step:sfm?importStep:null,result_step:state.ready?step:null,artifacts:{ply:state.ready?{size:model.length}:null}};
  };
  const server=http.createServer(async(req,res)=>{
    const chunks=[];for await(const c of req)chunks.push(c);const body=Buffer.concat(chunks).toString('utf8'),url=new URL(req.url,'http://mock');calls.push({method:req.method,path:url.pathname,url:req.url,body});
    if(state.ambiguousPath===url.pathname&&req.method!=='GET'){res.writeHead(503);res.end('synthetic unknown write');return;}
    if(state.getFailures>0&&req.method==='GET'&&url.pathname.endsWith('/3dgs')){state.getFailures--;res.writeHead(503);res.end();return;}
    let data;
    if(url.pathname.endsWith('/capabilities'))data={available:true,type:'gs_worldmirror2',engine:'worldmirror2',defaults:{max_frames:16,target_size:518},limits:{max_frames:[2,32]}};
    else if(url.pathname==='/api/project_groups')data={id:'group_test'};
    else if(url.pathname==='/api/3dgs/assets/images')data={id:'images_test',kind:'images',group_id:'group_test',image_count:2};
    else if(url.pathname==='/api/3dgs/assets/masks')data={id:'masks_test',kind:'masks',group_id:'group_test'};
    else if(url.pathname==='/api/3dgs/scenes')data={id:'project_test',group_id:'group_test'};
    else if(url.pathname==='/api/3dgs/quick-reconstruct')data={project_id:'project_test',step_id:'step_test',status:'PENDING'};
    else if(url.pathname.endsWith('/inputs'))data=inputs();
    else if(url.pathname.endsWith('/prepare'))data={step_id:'prepare_test',status:'PENDING'};
    else if(url.pathname.endsWith('/gs_mcmc/run'))data={step_id:'step_test',status:'PENDING'};
    else if(url.pathname.endsWith('/3dgs/pose-prior')&&req.method==='POST')data={ok:true};
    else if(url.pathname.endsWith('/point_cloud.ply')){res.writeHead(200,{'Content-Type':'application/octet-stream','Content-Length':model.length});res.end(model);return;}
    else if(url.pathname.endsWith('/3dgs'))data=output();
    else{res.writeHead(404);res.end();return;}
    res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify(data));
  });
  server.listen(0,'127.0.0.1');await once(server,'listening');
  const client=()=>new WorldMirrorClient({origin:`http://127.0.0.1:${server.address().port}`,successStatus:'SUCCESS',token:'SYNTHETIC_DO_NOT_PRINT',timeoutMs:1000});
  const options={algorithm,directory:run,framesDirectory,sourceVideoSha256:'a'.repeat(64),client:client()};
  const advance=extra=>advanceDualProvider({...options,client:client(),...extra});
  const mutations=()=>calls.filter(c=>c.method!=='GET');
  t.after(async()=>{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await rm(directory,{recursive:true,force:true});});
  return {state,calls,options,advance,mutations,model,directory,run,framesDirectory};
}

test('independent SfM prepares, submits once, resumes and preserves original full SH3 output',async t=>{
  const h=await harness(t);
  let result=await h.advance();assert.equal(result.phase,'preparing');assert.equal(result.status,'processing');assert.equal(h.mutations().length,5);
  await h.advance();assert.equal(h.mutations().length,5);
  h.state.prepareReady=true;result=await h.advance();assert.equal(result.phase,'waiting_gpu');assert.equal(h.mutations().length,6);
  const submitted=JSON.parse(h.mutations().at(-1).body);assert.equal(submitted.steps,7000);assert.equal(submitted.matcher,'exhaustive');assert.equal(submitted.camera_model,'SIMPLE_PINHOLE');assert.ok(!('pose_prior' in submitted));
  h.state.ready=true;result=await h.advance();assert.equal(result.status,'ready');assert.equal(result.inputRevision,1);assert.equal(result.importStepId,'prepare_test');assert.equal(result.pointCount,1);
  assert.deepEqual(await readFile(result.plyPath),h.model);assert.equal((await JSON.parse(await readFile(result.resultPath,'utf8'))).step.id,'step_test');
  const count=h.calls.length;const resumed=await h.advance();assert.equal(resumed.plySha256,result.plySha256);assert.equal(h.calls.length,count);
  assert.equal(h.calls.filter(c=>c.path.endsWith('/point_cloud.ply')).length,1);
  assert.doesNotMatch(await readFile(path.join(h.run,'provider-state.json'),'utf8'),/SYNTHETIC_DO_NOT_PRINT/);
});

test('FF reuses durable WorldMirror submission and exposes source-bound downloaded PLY',async t=>{
  const h=await harness(t,'gs_worldmirror2');
  let result=await h.advance();assert.equal(result.status,'processing');assert.equal(h.mutations().length,3);
  h.state.ready=true;result=await h.advance();assert.equal(result.status,'ready');assert.equal(result.algorithm,'gs_worldmirror2');assert.deepEqual(await readFile(result.plyPath),h.model);
  const persisted=JSON.parse(await readFile(result.resultPath,'utf8'));
  assert.equal(persisted.groupId,result.groupId);assert.equal(persisted.imagesAssetId,result.imagesAssetId);
  assert.equal(persisted.inputRevision,1);assert.equal(persisted.sourceVideoSha256,h.options.sourceVideoSha256);
  await h.advance();assert.equal(h.mutations().length,3);
  assert.equal(h.calls.filter(c=>c.path.endsWith('/point_cloud.ply')).length,1);
  for(const c of h.calls.filter(c=>c.path.endsWith('/3dgs')||c.path.endsWith('/point_cloud.ply'))){assert.match(c.url,/algorithm=gs_worldmirror2/);assert.match(c.url,/step_id=step_test/);}
});

for(const algorithm of ['gs_mcmc','gs_worldmirror2'])test(`${algorithm} ambiguous provider mutation blocks restarts without duplicate writes`,async t=>{
  const h=await harness(t,algorithm);h.state.ambiguousPath='/api/project_groups';
  let r=await h.advance();assert.equal(r.status,'blocked');assert.equal(r.phase,'mutation_unresolved');assert.equal(h.mutations().length,1);
  h.state.ambiguousPath=null;r=await h.advance();assert.equal(r.status,'blocked');assert.equal(h.mutations().length,1);
});

test('transient SfM polling failure retries reads while keeping exactly one submission',async t=>{
  const h=await harness(t);h.state.prepareReady=true;await h.advance();assert.equal(h.mutations().length,6);
  h.state.getFailures=1;let r=await h.advance();assert.equal(r.status,'processing');assert.equal(r.phase,'provider_read_retry');
  h.state.ready=true;r=await h.advance();assert.equal(r.status,'ready');assert.equal(h.mutations().length,6);
});

test('source changes and mismatched successful attempts cannot be published',async t=>{
  const h=await harness(t);h.state.prepareReady=true;await h.advance();
  await assert.rejects(h.advance({sourceVideoSha256:'b'.repeat(64)}),{code:'provider_profile_mismatch'});
  h.state.ready=true;h.state.badResult=true;const r=await h.advance();assert.equal(r.status,'blocked');assert.equal(r.error.code,'result_binding_mismatch');assert.equal(h.calls.filter(c=>c.path.endsWith('/point_cloud.ply')).length,0);
});

test('source deletion callback stops subsequent provider mutation; terminal failed never resubmits',async t=>{
  const h=await harness(t);let guards=0;
  const r=await h.advance({beforeMutation:async()=>{if(++guards===3)throw new WorldMirrorError('source_deleted','Source was deleted.');}});
  assert.equal(r.status,'blocked');assert.equal(h.mutations().length,1);await h.advance();assert.equal(h.mutations().length,1);
  const other=await harness(t,'gs_worldmirror2');other.state.failed=true;const failed=await other.advance();assert.equal(failed.status,'failed');await other.advance();assert.equal(other.mutations().length,3);
});

// ---- ARKit pose-prior branch (synthetic prior values; no real capture) ----
const PRIOR='image_name,camera_id,timestamp_ns,center_x,center_y,center_z,qw,qx,qy,qz,position_std_m\n'
  +'image_000001.jpg,iphone_arkit,0,0.000000000,0.000000000,0.000000000,0,1,0,0,0.100000\n'
  +'image_000002.jpg,iphone_arkit,1,0.100000000,0.000000000,0.000000000,0,1,0,0,0.100000\n';

test('only the ARKit branch accepts a pose prior, and it must supply one',async t=>{
  const sfm=await harness(t);
  await assert.rejects(sfm.advance({posePriorCSV:PRIOR}),{code:'invalid_pose_prior'});
  const arkit=await harness(t,'gs_mcmc_arkit_prior');
  await assert.rejects(arkit.advance(),{code:'invalid_pose_prior'});
  assert.equal(arkit.mutations().length,0);
});

test('ARKit branch uploads its prior once before the gs_mcmc run and publishes only when the Hub used it',async t=>{
  const h=await harness(t,'gs_mcmc_arkit_prior');
  let result=await h.advance({posePriorCSV:PRIOR});assert.equal(result.phase,'preparing');
  h.state.prepareReady=true;result=await h.advance({posePriorCSV:PRIOR});assert.equal(result.phase,'waiting_gpu');
  const writes=h.mutations().map(c=>c.path);
  const prior=writes.findIndex(p=>p.endsWith('/3dgs/pose-prior')),run=writes.findIndex(p=>p.endsWith('/gs_mcmc/run'));
  assert.ok(prior>=0&&prior<run,'prior is uploaded before the training run');
  assert.equal(writes.filter(p=>p.endsWith('/3dgs/pose-prior')).length,1);
  assert.match(h.mutations()[prior].body,/image_000002\.jpg,iphone_arkit,1,0\.100000000/);
  // A different prior on resume is refused instead of silently changing the attempt.
  await assert.rejects(h.advance({posePriorCSV:PRIOR.replace('0.100000000','0.200000000')}),{code:'input_changed'});
  h.state.ready=true;result=await h.advance({posePriorCSV:PRIOR});
  assert.equal(result.status,'ready');assert.equal(result.posePriorSha256.length,64);
  assert.equal(writes.length,h.mutations().length,'no further provider writes after submission');
});

test('ARKit branch is blocked when the Hub reports it trained without the prior',async t=>{
  const h=await harness(t,'gs_mcmc_arkit_prior');
  h.state.prepareReady=true;await h.advance({posePriorCSV:PRIOR});await h.advance({posePriorCSV:PRIOR});
  h.state.ready=true;h.state.usePosePrior=false;
  const result=await h.advance({posePriorCSV:PRIOR});
  assert.equal(result.status,'blocked');assert.equal(result.plyPath,undefined);
});

// ---- Person masks with phone keyframes (synthetic PNG bytes) ----
async function masks(h,names=['image_0001.png','image_0002.png']) {
  const directory=path.join(h.directory,'masks');await mkdir(directory);
  for(const name of names)await writeFile(path.join(directory,name),Buffer.from('SYNTHETIC MASK '+name));
  return directory;
}

test('ARKit keyframe branch uploads white_keep masks for the same images and points the project at them',async t=>{
  const h=await harness(t,'gs_mcmc_arkit_prior'),masksDirectory=await masks(h);
  h.state.prepareReady=true;h.state.reportMasks='masks_test';
  let result=await h.advance({posePriorCSV:PRIOR,masksDirectory});assert.equal(result.phase,'waiting_gpu');
  const writes=h.mutations();
  const upload=writes.find(c=>c.path==='/api/3dgs/assets/masks');
  assert.ok(upload,'masks uploaded');
  assert.match(upload.body,/name="polarity"\r\n\r\nwhite_keep/);assert.match(upload.body,/name="images_asset_id"\r\n\r\nimages_test/);
  assert.match(upload.body,/filename="image_0001\.png"/);
  assert.ok(writes.findIndex(c=>c.path==='/api/3dgs/assets/images')<writes.indexOf(upload),'after the images');
  assert.deepEqual(JSON.parse(writes.find(c=>c.path.endsWith('/3dgs/inputs')).body),{source_kind:'images',images_asset_id:'images_test',masks_asset_id:'masks_test'});
  await assert.rejects(h.advance({posePriorCSV:PRIOR}),{code:'input_changed'},'masks cannot be dropped on resume');
  h.state.ready=true;result=await h.advance({posePriorCSV:PRIOR,masksDirectory});
  assert.equal(result.status,'ready');assert.equal(result.masksAssetId,'masks_test');
  assert.equal(h.mutations().filter(c=>c.path==='/api/3dgs/assets/masks').length,1);
});

test('masks must match the images one to one, belong to an SfM branch, and stay attached in the Hub',async t=>{
  const sfm=await harness(t,'gs_worldmirror2'),sfmMasks=await masks(sfm);
  await assert.rejects(sfm.advance({masksDirectory:sfmMasks}),{code:'invalid_masks'});
  const h=await harness(t,'gs_mcmc_arkit_prior');
  await assert.rejects(h.advance({posePriorCSV:PRIOR,masksDirectory:await masks(h,['image_0001.png'])}),{code:'invalid_masks'});
  assert.equal(h.mutations().length,0);
  const dropped=await harness(t,'gs_mcmc_arkit_prior'),directory=await masks(dropped);
  dropped.state.prepareReady=true;dropped.state.reportMasks='other_masks';
  const result=await dropped.advance({posePriorCSV:PRIOR,masksDirectory:directory});
  assert.equal(result.status,'blocked');assert.equal(result.error.code,'inputs_mismatch');
});


test('terminal provider failures expose safe actionable codes without private report text', async t => {
  const gpu=await harness(t,'gs_mcmc'); gpu.state.prepareReady=true; gpu.state.failed=true;
  gpu.state.failureReport={error:'GPU 显存不足,未启动 3DGS。private debug path /secret'};
  const unavailable=await gpu.advance();
  assert.equal(unavailable.error.code,'gpu_memory_unavailable');
  assert.ok(!JSON.stringify(unavailable.error).includes('/secret'));
  const cancelled=await harness(t,'gs_worldmirror2'); cancelled.state.failed=true;
  cancelled.state.failureReport={phase:'cancelled',cancelled:true,error:'cancelled locally'};
  assert.equal((await cancelled.advance()).error.code,'provider_cancelled');
  const writes=cancelled.mutations().length; await cancelled.advance();
  assert.equal(cancelled.mutations().length,writes,'never automatically resubmit a cancelled job');
});


test('independent SfM uses subject masks without uploading any pose prior',async t=>{
  const h=await harness(t,'gs_mcmc'),masksDirectory=await masks(h);
  h.state.prepareReady=true;h.state.reportMasks='masks_test';
  await h.advance({masksDirectory});await h.advance({masksDirectory});
  assert.ok(h.mutations().some(c=>c.path==='/api/3dgs/assets/masks'));
  assert.ok(h.mutations().every(c=>!c.path.includes('pose-prior')));
  h.state.ready=true;
  const result=await h.advance({masksDirectory});assert.equal(result.status,'ready');assert.equal(result.posePriorSha256,undefined);
});
