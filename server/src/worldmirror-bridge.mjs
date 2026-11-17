import { open, mkdir, readFile, writeFile, rename, rm, lstat, readdir } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { WorldMirrorClient, originOnly, sha256File } from './worldmirror-client.mjs';
import * as workflow from './worldmirror-run.mjs';
import { uuid, validateGaussian, validateJPEG, validateVideo } from './validation.mjs';

const MiB=1024*1024;
const stamp=()=>new Date().toISOString();
const present=file=>lstat(file).then(()=>true,e=>{if(e.code==='ENOENT')return false;throw e;});
export class BridgeError extends Error {
  constructor(code,message,{status,outcomeUnknown=false,retryable=false}={}){super(message);Object.assign(this,{code,status,outcomeUnknown,retryable});}
}
function check(condition,code,message){if(!condition)throw new BridgeError(code,message);}
function identifier(value){check(uuid(value),'invalid_id','A valid PocketWorld job/session UUID is required.');return value;}
function positive(value,fallback,max,name){const n=value??fallback;check(Number.isInteger(n)&&n>0&&n<=max,'invalid_config',`Invalid ${name} limit.`);return n;}
async function regular(file,max){const s=await lstat(file);check(s.isFile()&&!s.isSymbolicLink()&&s.size>0&&s.size<=max,'invalid_file','Expected a bounded regular file.');return s;}
async function jsonFile(file){await regular(file,MiB);try{return JSON.parse(await readFile(file,'utf8'));}catch(e){if(e instanceof BridgeError)throw e;throw new BridgeError('invalid_manifest','The local bridge manifest is not valid JSON.');}}
async function save(file,value){const temp=`${file}.${randomUUID()}.tmp`;let handle;try{handle=await open(temp,'wx',0o600);await handle.writeFile(JSON.stringify(value,null,2)+'\n');await handle.sync();await handle.close();handle=null;await rename(temp,file);}finally{await handle?.close();await rm(temp,{force:true});}}
function safeError(error){return {code:/^[A-Za-z0-9_-]{1,80}$/.test(error.code||'')?error.code:'local_failure',...(Number.isInteger(error.status)?{status:error.status}:{}),outcomeUnknown:!!error.outcomeUnknown,at:stamp()};}

export function bridgeOptions(input={}){
  check(typeof input.adminToken==='string'&&/^[A-Za-z0-9_-]{32,200}$/.test(input.adminToken),'invalid_config','Load the existing PocketWorld administrator credential from its private config.');
  check(path.isAbsolute(input.workDir||''),'invalid_config','Use an absolute ignored work directory.');
  check([8,16].includes(input.frameCount??8),'invalid_config','frameCount must be 8 or 16.');
  check(input.providerVersion===undefined||typeof input.providerVersion==='string'&&input.providerVersion.length<=80&&!/[\r\n]/.test(input.providerVersion),'invalid_config','Provider version must be an optional verified version string.');
  check(input.successStatus==null||typeof input.successStatus==='string'&&/^[A-Z_]{1,40}$/.test(input.successStatus),'invalid_config','successStatus must be an explicitly verified provider success token.');
  check(input.plyProfile==null||input.plyProfile==='worldmirror2-probability-v1','invalid_config','plyProfile must identify the explicitly verified WorldMirror probability exporter.');
  return {...input,successStatus:input.successStatus||null,providerVersion:input.providerVersion||'',backendOrigin:originOnly(input.backendOrigin),providerOrigin:originOnly(input.providerOrigin),workDir:path.resolve(input.workDir),frameCount:input.frameCount??8,
    timeoutMs:positive(input.timeoutMs,30000,300000,'request timeout'),downloadTimeoutMs:positive(input.downloadTimeoutMs,120000,300000,'download timeout'),
    ffmpegTimeoutMs:positive(input.ffmpegTimeoutMs,90000,300000,'ffmpeg timeout'),maxVideoBytes:positive(input.maxVideoBytes,80*MiB,500*MiB,'video bytes'),
    maxPLYBytes:positive(input.maxPLYBytes,150*MiB,150*MiB,'PLY bytes'),maxFrameBytes:positive(input.maxFrameBytes,4*MiB,20*MiB,'frame bytes')};
}

// Every URL is constructed from a fixed admin route. Bundle-provided URLs are
// checked for equality, never followed; credentials cannot cross an origin.
export class PocketWorldBridgeClient {
  constructor({origin,token,timeoutMs=30000,fetchImpl=fetch}){this.origin=originOnly(origin);this.token=token;this.timeoutMs=timeoutMs;this.fetchImpl=fetchImpl;}
  async request(endpoint,{method='GET',json,file,consume,timeoutMs=this.timeoutMs}={}){
    check(typeof endpoint==='string'&&/^\/v1\/admin\/(jobs(?:\/[^/?]+\/(?:status|asset))?|sessions\/[^/?]+\/(?:bundle|video))(?:\?[^#]*)?$/.test(endpoint)&&!endpoint.includes('\\')&&new URL(endpoint,this.origin).origin===this.origin,'unsafe_endpoint','Only fixed PocketWorld admin routes may be requested.');
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeoutMs),mutating=method!=='GET';
    let stream;
    try{
      const headers={Authorization:`Bearer ${this.token}`},options={method,headers,redirect:'error',signal:controller.signal};
      if(file){const size=(await regular(file,150*MiB)).size;headers['Content-Type']='application/octet-stream';headers['Content-Length']=String(size);stream=createReadStream(file);options.body=stream;options.duplex='half';}
      else if(json!==undefined){headers['Content-Type']='application/json';options.body=JSON.stringify(json);}
      const response=await this.fetchImpl(this.origin+endpoint,options);
      if(!response.ok){await response.body?.cancel();throw new BridgeError('backend_http',`PocketWorld returned HTTP ${response.status}.`,{status:response.status,outcomeUnknown:mutating&&response.status>=500,retryable:response.status>=500||response.status===429});}
      if(consume)return await consume(response,controller);
      let length=0;const chunks=[];for await(const chunk of response.body??[]){length+=chunk.length;if(length>8*MiB){controller.abort();throw new BridgeError('response_too_large','PocketWorld response exceeds the limit.',{outcomeUnknown:mutating});}chunks.push(chunk);}
      try{return JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{throw new BridgeError('invalid_json','PocketWorld returned invalid JSON.',{outcomeUnknown:mutating});}
    }catch(error){if(error instanceof BridgeError)throw error;throw new BridgeError(controller.signal.aborted?'request_timeout':'request_failed','PocketWorld request did not complete.',{outcomeUnknown:mutating,retryable:true});}
    finally{clearTimeout(timer);stream?.destroy();}
  }
  jobs(){return this.request('/v1/admin/jobs');}
  bundle(id){return this.request(`/v1/admin/sessions/${identifier(id)}/bundle`);}
  status(id,status,expectedStatus,errorMessage,workerClaimId){return this.request(`/v1/admin/jobs/${identifier(id)}/status`,{method:'PUT',json:{status,expectedStatus,...(errorMessage?{errorMessage}:{}),...(workerClaimId?{workerClaimId}:{}),notes:'Windows WorldMirror2 bridge; no quality or training acceptance claimed.'}});}
  importPLY(id,file,version,plyProfile){const query=new URLSearchParams({format:'ply',tool:'WorldMirror2'});if(version)query.set('version',version);if(plyProfile)query.set('plyProfile',plyProfile);return this.request(`/v1/admin/jobs/${identifier(id)}/asset?${query}`,{method:'PUT',file,timeoutMs:120000});}
  async video(id,destination,expected,{maxBytes,timeoutMs}){
    const temporary=`${destination}.${randomUUID()}.part`;let handle;
    try{
      handle=await open(temporary,'wx',0o600);
      await this.request(`/v1/admin/sessions/${identifier(id)}/video`,{timeoutMs,consume:async(response,controller)=>{
        const declared=Number(response.headers.get('content-length')),headerHash=response.headers.get('x-content-sha256');
        check(!declared||declared<=maxBytes,'video_too_large','The source video exceeds the worker limit.');
        check(!headerHash||headerHash===expected.sha256,'source_changed','The video response hash differs from its bundle.');
        let size=0;const hash=createHash('sha256');
        for await(const chunk of response.body??[]){size+=chunk.length;if(size>maxBytes||size>expected.size){controller.abort();throw new BridgeError('video_too_large','The source video exceeded its bound.');}hash.update(chunk);await handle.writeFile(chunk);}
        check(size===expected.size&&hash.digest('hex')===expected.sha256,'source_changed','The downloaded source video does not match its recorded size/hash.');await handle.sync();
      }});
      await handle.close();handle=null;await rename(temporary,destination);
    }finally{await handle?.close();await rm(temporary,{force:true});}
  }
}

export async function extractBridgeFrames({sourceVideo,outputDirectory,ffmpegPath,frameCount,durationSeconds,timeoutMs=90000,maxFrameBytes=4*MiB,spawnImpl=spawn}){
  check(path.isAbsolute(ffmpegPath||''),'ffmpeg_missing','Set FFMPEG_PATH or ffmpegPath to the absolute executable path.');await regular(ffmpegPath,500*MiB);
  check([8,16].includes(frameCount)&&Number.isFinite(durationSeconds)&&durationSeconds>0&&durationSeconds<=600,'invalid_capture_metadata','A real bounded capture duration is required for sampling.');
  await mkdir(outputDirectory,{recursive:false,mode:0o700});
  const rate=(frameCount/durationSeconds).toFixed(8),filter=`fps=${rate},scale=1024:1024:force_original_aspect_ratio=decrease`;
  const args=['-nostdin','-hide_banner','-loglevel','error','-n','-protocol_whitelist','file,pipe','-i',sourceVideo,'-vf',filter,'-frames:v',String(frameCount),'-q:v','3','-an','-sn','-dn',path.join(outputDirectory,'frame-%03d.jpg')];
  await new Promise((resolve,reject)=>{
    const child=spawnImpl(ffmpegPath,args,{windowsHide:true,shell:false,stdio:['ignore','ignore','pipe']});let timedOut=false,settled=false;
    const finish=error=>{if(settled)return;settled=true;clearTimeout(timer);error?reject(error):resolve();};
    const timer=setTimeout(()=>{timedOut=true;child.kill('SIGKILL');},timeoutMs);
    // Drain without retaining/logging FFmpeg's potentially private paths/metadata.
    child.stderr?.on('data',()=>{});
    child.once('error',()=>finish(new BridgeError('ffmpeg_failed','FFmpeg could not start.')));
    child.once('close',code=>finish(timedOut?new BridgeError('ffmpeg_timeout','Frame extraction exceeded its deadline.'):code!==0?new BridgeError('ffmpeg_failed','FFmpeg could not decode this source video.'):null));
  });
  const names=(await readdir(outputDirectory)).sort();check(names.length>=2&&names.length<=frameCount&&names.every(n=>/^frame-\d{3}\.jpg$/.test(n)),'invalid_frames','Frame extraction did not produce 2 to the configured maximum frames.');
  const files=[];for(const name of names){const file=path.join(outputDirectory,name),size=(await regular(file,maxFrameBytes)).size;await validateJPEG(file);files.push({name,size,sha256:await sha256File(file)});}
  return {files,method:'ffmpeg_uniform_fps',samplingDurationSeconds:durationSeconds,samplingDurationSource:'client_reported',frameLimit:frameCount,noCameraCalibration:true};
}

function sourceFrom(bundle,jobId){
  const session=bundle?.manifest,job=bundle?.processing?.job;
  check(session&&uuid(session.id)&&job?.id===jobId&&job.sessionId===session.id,'source_changed','Bundle session/job binding is invalid.');
  check(session.captureMode==='in_app_rgb'&&session.captureStatus==='submitted'&&session.rawDataAvailable===true,'unsupported_source','Only submitted original native videos may be reconstructed.');
  if(session.linkedCaptureId)check(uuid(session.linkedCaptureId)&&uuid(session.linkedCaptureReceiptId)&&session.provenance==='device_capture_v2_verified'&&session.originalVideoId===session.linkedCaptureId&&/^[a-f0-9]{64}$/.test(session.linkedCaptureMetadataSHA256),'invalid_source','The verified v2 source link is incomplete.');
  const expectedURL=`/v1/admin/sessions/${session.id}/video`,videos=(bundle.files||[]).filter(f=>f.url===expectedURL);
  check(videos.length===1&&/^[a-f0-9]{64}$/.test(videos[0].sha256)&&Number.isSafeInteger(videos[0].size)&&videos[0].size>0,'invalid_source','A single fixed-route video with size/hash is required.');
  check((bundle.files||[]).filter(f=>/capture\.(mp4|mov)$/.test(f.path||'')).every(f=>f.url===expectedURL),'unsafe_endpoint','Video download URLs must equal the fixed same-origin source route.');
  return {sessionId:session.id,userId:session.userId,originalVideoId:session.originalVideoId,sha256:videos[0].sha256,size:videos[0].size,durationSeconds:session.videoDurationSeconds,
    linkedCaptureId:session.linkedCaptureId??null,linkedCaptureReceiptId:session.linkedCaptureReceiptId??null,linkedCaptureMetadataSHA256:session.linkedCaptureMetadataSHA256??null};
}
function sameSource(a,b){return ['sessionId','userId','originalVideoId','sha256','size','durationSeconds','linkedCaptureId','linkedCaptureReceiptId','linkedCaptureMetadataSHA256'].every(k=>(a[k]??null)===(b[k]??null));}
async function activeSource(client,jobId,bound,{allowReady=false}={}){
  const jobs=await client.jobs();check(Array.isArray(jobs.jobs),'invalid_json','PocketWorld jobs list is missing.');
  const envelope=jobs.jobs.find(e=>e?.job?.id===jobId);
  if(!envelope)throw new BridgeError('source_deleted','The source job/session was deleted.');
  if(envelope.job.status==='cancelled')throw new BridgeError('source_cancelled','The source job was cancelled.');
  check(['queued','processing',...(allowReady?['ready']:[])].includes(envelope.job.status),'source_inactive','The source job is no longer active.');
  const bundle=await client.bundle(envelope.session.id),source=sourceFrom(bundle,jobId);
  if(bundle.processing.job.status==='cancelled')throw new BridgeError('source_cancelled','The source job was cancelled.');
  check(['queued','processing',...(allowReady?['ready']:[])].includes(bundle.processing.job.status),'source_inactive','The source job is no longer active.');
  check(!bound||sameSource(bound,source),'source_changed','The source identity or immutable video changed.');
  return {envelope,bundle,source};
}

async function lock(directory,action){
  await mkdir(directory,{recursive:true,mode:0o700});
  const filename=path.join(directory,'.bridge.lock'),nonce=randomUUID();let handle;
  for(let n=0;n<2;n++)try{handle=await open(filename,'wx',0o600);break;}catch(error){
    if(error.code!=='EEXIST'||n)throw new BridgeError('bridge_busy','Another bridge process owns this job.');
    let owner;try{owner=await jsonFile(filename);}catch{throw new BridgeError('bridge_busy','Inspect an incomplete lock before recovering this job.');}
    check(Number.isInteger(owner.pid)&&owner.pid>0&&typeof owner.nonce==='string','bridge_busy','The bridge lock cannot be recovered automatically.');
    try{process.kill(owner.pid,0);throw new Error('alive');}catch(probe){check(probe.code==='ESRCH','bridge_busy','A live process may still own this bridge job.');}
    check((await jsonFile(filename)).nonce===owner.nonce,'bridge_busy','Bridge lock changed during recovery.');await rm(filename);
  }
  try{await handle.writeFile(JSON.stringify({pid:process.pid,nonce}));await handle.sync();return await action();}
  finally{await handle?.close();try{if((await jsonFile(filename)).nonce===nonce)await rm(filename);}catch(e){if(e.code!=='ENOENT')throw e;}}
}

export function bridgeSummary(state){return {jobId:state.jobId,phase:state.phase,...(state.provider?{provider:state.provider}:{}),...(state.assetId?{assetId:state.assetId}:{}),...(state.error?{error:state.error}:{})};}
export async function runBridgeOnce(input,{jobId,fetchImpl=fetch,providerWorkflow=workflow,providerClient,extractFrames=extractBridgeFrames}={}){
  const options=bridgeOptions(input),client=new PocketWorldBridgeClient({origin:options.backendOrigin,token:options.adminToken,timeoutMs:options.timeoutMs,fetchImpl});
  const profile={backendOrigin:options.backendOrigin,providerOrigin:options.providerOrigin,adminFingerprint:createHash('sha256').update(options.adminToken).digest('hex'),providerFingerprint:createHash('sha256').update(options.providerToken||'').digest('hex'),groupId:options.groupId||null,frameCount:options.frameCount,providerVersion:options.providerVersion,successStatus:options.successStatus};
  if(options.plyProfile)profile.plyProfile=options.plyProfile;
  if(!jobId){
    const jobs=await client.jobs();check(Array.isArray(jobs.jobs),'invalid_json','PocketWorld jobs list is missing.');
    // Resume only processing jobs that this worker already owns. Fresh manual
    // processing jobs belong to another operator and must not be adopted.
    for(const e of jobs.jobs){if(e?.job?.status==='processing'&&uuid(e.job.id)&&await present(path.join(options.workDir,e.job.id,'bridge.json'))){jobId=e.job.id;break;}}
    jobId??=jobs.jobs.slice().reverse().find(e=>e?.job?.status==='queued'&&e.session?.captureMode==='in_app_rgb')?.job.id;
    if(!jobId)return {phase:'idle'};
  }
  identifier(jobId);const directory=path.join(options.workDir,jobId),manifestFile=path.join(directory,'bridge.json');
  return lock(directory,async()=>{
    let state=await present(manifestFile)?await jsonFile(manifestFile):null;
    if(state){
      const oldProfile={...state.profile,successStatus:state.profile?.successStatus??null};
      const firstVerifiedStatus=!oldProfile.successStatus&&!!profile.successStatus&&!state.output&&!state.importAttemptedAt&&JSON.stringify({...oldProfile,successStatus:profile.successStatus})===JSON.stringify(profile);
      check(state.version===1&&state.jobId===jobId&&(JSON.stringify(oldProfile)===JSON.stringify(profile)||firstVerifiedStatus),'profile_mismatch','This bridge manifest belongs to another backend, provider, credential or sampling profile.');
      if(firstVerifiedStatus){state.profile=profile;await save(manifestFile,state);}
    }
    let current;
    try{
      current=await activeSource(client,jobId,state?.source,{allowReady:true});
      if(!state){
        check(current.envelope.job.status==='queued','source_inactive','Only a queued native job may begin a new bridge run.');
        check(current.source.size<=options.maxVideoBytes,'video_too_large','The source video exceeds the worker limit.');
        state={version:1,jobId,profile,source:current.source,phase:'initialized',createdAt:stamp()};await save(manifestFile,state);
        await save(path.join(directory,'source-manifest.json'),current.bundle.manifest);
      }
      if(current.envelope.job.status==='ready'){
        check(state.output&&current.envelope.asset?.sha256===state.output.sha256&&current.envelope.asset?.reconstructionTool==='WorldMirror2'&&(current.envelope.asset?.plyProfile??null)===(options.plyProfile??null),'result_conflict','A different result/profile already owns this source job.');
        state.phase='imported';state.assetId=current.envelope.asset.id;delete state.error;await save(manifestFile,state);return bridgeSummary(state);
      }
      if(state.phase==='cancelled'&&current.envelope.job.status!=='queued')return bridgeSummary(state);
      if(current.envelope.job.status==='queued'){
        // A local manifest or an attempted write is not proof of ownership.
        // Only a confirmed queued→processing CAS permits this worker to mutate
        // a processing job. Lost claim responses stop for operator reconciliation.
        state.claim={id:randomUUID(),attemptedAt:stamp()};await save(manifestFile,state);
        let claimed;
        try{claimed=await client.status(jobId,'processing','queued',undefined,state.claim.id);}
        catch(error){if(error.status===409)throw new BridgeError('claim_conflict','Another operator claimed this job; this worker will not mutate it.',{status:409});throw new BridgeError('claim_unconfirmed','The processing claim was not confirmed; inspect the saved attempt.',{status:error.status,outcomeUnknown:true,retryable:false});}
        check(claimed?.job?.id===jobId&&claimed.job.status==='processing','claim_unconfirmed','The processing claim response did not confirm this job.');
        state.claim.confirmedAt=stamp();state.claim.jobUpdatedAt=claimed.job.updatedAt||null;await save(manifestFile,state);current=await activeSource(client,jobId,state.source);
      }
      check(!!state.claim?.confirmedAt,'claim_unconfirmed','This worker has no confirmed ownership of the processing job.');
      check(!current.envelope.job.workerClaimId||current.envelope.job.workerClaimId===state.claim.id,'claim_conflict','Another worker owns this processing job.');
      const ownedSource=async({allowReady=false}={})=>{
        const live=await activeSource(client,jobId,state.source,{allowReady});
        if(live.envelope.job.status!=='ready'){
          check(live.envelope.job.status==='processing','claim_conflict','An operator released this worker claim.');
          check(!live.envelope.job.workerClaimId||live.envelope.job.workerClaimId===state.claim.id,'claim_conflict','Another worker owns this processing job.');
        }
        return live;
      };
      const videoFile=path.join(directory,'source-video.mp4');
      if(await present(videoFile)){await regular(videoFile,options.maxVideoBytes);check(await sha256File(videoFile)===state.source.sha256,'source_changed','The local original video changed.');}
      else await client.video(state.source.sessionId,videoFile,state.source,{maxBytes:options.maxVideoBytes,timeoutMs:options.downloadTimeoutMs});
      await validateVideo(videoFile);
      if(!state.frames){
        await ownedSource();
        const framesName='frames-'+randomUUID(),frameDirectory=path.join(directory,framesName);
        const frames=await extractFrames({sourceVideo:videoFile,outputDirectory:frameDirectory,ffmpegPath:options.ffmpegPath,frameCount:options.frameCount,durationSeconds:state.source.durationSeconds,timeoutMs:options.ffmpegTimeoutMs,maxFrameBytes:options.maxFrameBytes});
        check(Array.isArray(frames.files)&&frames.files.length>=2&&frames.files.length<=options.frameCount,'invalid_frames','Frame extraction exceeded its count limit.');
        state.frames={...frames,directory:framesName};state.phase='frames_ready';await save(manifestFile,state);
      }
      check(/^frames-[a-f0-9-]{36}$/.test(state.frames.directory),'invalid_manifest','The frame directory is outside this run.');
      check(Array.isArray(state.frames.files)&&state.frames.files.length>=2&&state.frames.files.length<=options.frameCount,'invalid_manifest','The saved frame count exceeds the configured limit.');
      const framesDirectory=path.join(directory,state.frames.directory);
      for(const frame of state.frames.files){check(/^frame-\d{3}\.jpg$/.test(frame.name),'invalid_manifest','Unsafe local frame name.');const file=path.join(framesDirectory,frame.name);check((await regular(file,options.maxFrameBytes)).size===frame.size&&await sha256File(file)===frame.sha256,'input_changed','Extracted frames changed since the run was saved.');}
      const providerDirectory=path.join(directory,'provider'),provider=providerClient||new WorldMirrorClient({origin:options.providerOrigin,token:options.providerToken||'',timeoutMs:options.timeoutMs,maxPLYBytes:options.maxPLYBytes,successStatus:options.successStatus});
      check(provider.origin===options.providerOrigin,'profile_mismatch','Provider client origin differs from the bridge profile.');
      await ownedSource();
      const beforeMutation=()=>ownedSource();
      // The Hub rejects project names containing whitespace.
      let run=await providerWorkflow.uploadRun({directory:providerDirectory,filesDirectory:framesDirectory,name:'PocketWorld-'+jobId,client:provider,beforeMutation,...(options.groupId?{groupId:options.groupId}:{})});
      state.provider=providerWorkflow.runSummary(run);state.phase='provider_uploaded';await save(manifestFile,state);
      await ownedSource();
      run=await providerWorkflow.quickRun({directory:providerDirectory,client:provider,beforeMutation});state.provider=providerWorkflow.runSummary(run);state.phase='provider_processing';await save(manifestFile,state);
      await ownedSource();
      run=await providerWorkflow.resumeRun({directory:providerDirectory,client:provider,maxWaitMs:0,downloadTimeoutMs:options.downloadTimeoutMs});state.provider=providerWorkflow.runSummary(run);await save(manifestFile,state);
      if(run.phase==='provider_failed')throw new BridgeError('provider_failed','WorldMirror2 reported a failed or cancelled reconstruction.');
      if(run.phase!=='downloaded')return bridgeSummary(state);
      check(run.output?.file==='scene.ply'&&/^[a-f0-9]{64}$/.test(run.output.sha256),'invalid_result','Provider output is not a validated local PLY.');
      const ply=path.join(providerDirectory,'scene.ply'),size=(await regular(ply,options.maxPLYBytes)).size;
      check(size===run.output.size&&await sha256File(ply)===run.output.sha256,'output_changed','The downloaded provider model changed.');
      const validation=await validateGaussian(ply,'ply');state.output={sha256:run.output.sha256,size,gaussianCount:validation.gaussianCount};state.phase='output_validated';await save(manifestFile,state);
      current=await ownedSource({allowReady:true});
      if(current.envelope.job.status!=='ready'){
        state.phase='import_pending';state.importAttemptedAt??=stamp();await save(manifestFile,state);
        await client.importPLY(jobId,ply,options.providerVersion,options.plyProfile);
      }
      // A lost import response is resolved on the next run by this same immutable
      // output hash. No new provider run or invented ready state is generated.
      current=await ownedSource({allowReady:true});
      check(current.envelope.job.status==='ready'&&current.envelope.asset?.sha256===state.output.sha256&&current.envelope.asset?.format==='ply'&&current.envelope.asset?.reconstructionTool==='WorldMirror2'&&(current.envelope.asset?.plyProfile??null)===(options.plyProfile??null),'import_unconfirmed','The imported result/profile has not been confirmed on its source job.');
      state.phase='imported';state.assetId=current.envelope.asset.id;state.importedAt=stamp();delete state.error;await save(manifestFile,state);return bridgeSummary(state);
    }catch(error){
      if(!state)throw error;
      const cancelled=['source_deleted','source_cancelled'].includes(error.code),ambiguous=!!error.outcomeUnknown||['mutation_unresolved','import_unconfirmed','claim_conflict','claim_unconfirmed'].includes(error.code),retryable=!!error.retryable||(!ambiguous&&(['request_timeout','request_failed'].includes(error.code)||(error.code==='provider_http'&&(error.status>=500||error.status===429))));
      state.error=safeError(error);state.phase=cancelled?'cancelled':ambiguous?'blocked':retryable?'retry_wait':'failed';await save(manifestFile,state);
      if(state.claim?.confirmedAt&&!cancelled&&!ambiguous&&!retryable&&!['source_inactive','result_conflict','source_changed','profile_mismatch'].includes(error.code)){
        try{const live=await activeSource(client,jobId,state.source);if(live.envelope.job.status!=='processing'||live.envelope.job.workerClaimId&&live.envelope.job.workerClaimId!==state.claim.id)throw new BridgeError('claim_conflict','Another worker owns this job.');await client.status(jobId,'failed',live.envelope.job.status,'WorldMirror2 bridge stopped: '+state.error.code+'. Inspect the private worker manifest.',state.claim.id);}catch{/* Never resurrect a cancelled/deleted job to record a worker error. */}
      }
      if(cancelled)return bridgeSummary(state);throw error;
    }
  });
}
