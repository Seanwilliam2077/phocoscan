#!/usr/bin/env node
import { readFile, lstat, mkdir, realpath } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { runBridgeOnce, bridgeOptions } from '../src/worldmirror-bridge.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const help=`PocketWorld outbound Windows → WorldMirror2 bridge

  node server/tools/worldmirror-worker.mjs --once --job-id UUID --config ABSOLUTE_PRIVATE_JSON
  node server/tools/worldmirror-worker.mjs --watch --config ABSOLUTE_PRIVATE_JSON

No worker is started by default. --once requires one explicit job ID.
--watch explicitly opts into processing queued native jobs and resuming this
worker's saved processing jobs. Ctrl+C stops after the current bounded operation.

Private JSON fields:
  backendOrigin, adminConfigFile, providerOrigin, workDir,
  providerVersion (optional, only if the actual version is verified),
  ffmpegPath (or FFMPEG_PATH), frameCount (8 or 16, default 8),
  providerTokenEnv (optional environment variable NAME), groupId (optional),
  successStatus (only a verified terminal success token; default fail-closed),
  timeoutMs, downloadTimeoutMs, ffmpegTimeoutMs, maxVideoBytes,
  pollIntervalMs (5000–60000, default 15000).

adminConfigFile references an EXISTING operator config containing adminToken.
Do not copy credentials, source video, frames, or manifests into Git.
workDir and this private JSON must stay under this repository's ignored work/.
No provider result means no fabricated ready state; ambiguous writes require
inspection of the persisted provider manifest before further mutation.
`;
function inside(parent,child){const relative=path.relative(parent,child);return !!relative&&!relative.startsWith('..'+path.sep)&&relative!=='..'&&!path.isAbsolute(relative);}
async function privateJSON(file){const stat=await lstat(file);if(!stat.isFile()||stat.isSymbolicLink()||stat.size>65536)throw Error('Use a bounded regular private configuration file.');return JSON.parse(await readFile(file,'utf8'));}
export async function loadWorkerConfig(file,{environment=process.env}={}){
  const workRoot=path.join(root,'work'),configFile=path.resolve(file);
  if(!inside(workRoot,configFile))throw Error('Keep the private bridge configuration under ignored work/.');
  const raw=await privateJSON(configFile);
  if(!path.isAbsolute(raw.adminConfigFile||''))throw Error('adminConfigFile must be an absolute existing operator-config path.');
  const admin=await privateJSON(raw.adminConfigFile);
  const workDir=path.resolve(raw.workDir||path.join(workRoot,'worldmirror-bridge'));
  if(!inside(workRoot,workDir))throw Error('Bridge artifacts must stay in a subfolder of ignored work/.');
  await mkdir(workDir,{recursive:true,mode:0o700});
  if(!inside(await realpath(workRoot),await realpath(workDir)))throw Error('Bridge work directory must resolve inside ignored work/.');
  const tokenName=raw.providerTokenEnv||'';
  if(tokenName&&!/^[A-Z_][A-Z0-9_]{0,99}$/.test(tokenName))throw Error('providerTokenEnv must name one environment variable.');
  if(tokenName&&typeof environment[tokenName]!=='string')throw Error('The requested provider credential environment variable is not set.');
  const config=bridgeOptions({...raw,workDir,adminToken:admin.adminToken,providerToken:tokenName?environment[tokenName]:'',ffmpegPath:environment.FFMPEG_PATH||raw.ffmpegPath,successStatus:environment.WORLDMIRROR_SUCCESS_STATUS||raw.successStatus||null});
  const pollIntervalMs=raw.pollIntervalMs??15000;
  if(!Number.isInteger(pollIntervalMs)||pollIntervalMs<5000||pollIntervalMs>60000)throw Error('pollIntervalMs must be between 5000 and 60000.');
  return {...config,pollIntervalMs};
}
export async function main(args=process.argv.slice(2)){
  const {values}=parseArgs({args,options:{help:{type:'boolean',short:'h'},once:{type:'boolean'},watch:{type:'boolean'},'job-id':{type:'string'},config:{type:'string'}},strict:true,allowPositionals:false});
  if(values.help||(!values.once&&!values.watch)){console.log(help);return;}
  if(values.once&&values.watch)throw Error('Choose --once or --watch, not both.');
  if(values.once&&!values['job-id'])throw Error('--once requires --job-id so the first run processes only the explicitly selected capture.');
  if(!values.config||!path.isAbsolute(values.config))throw Error('Supply --config with the absolute private JSON path under work/.');
  const config=await loadWorkerConfig(values.config);let stopping=false,interrupt;
  const stop=()=>{stopping=true;interrupt?.();};process.on('SIGINT',stop);process.on('SIGTERM',stop);
  try{
    do{
      try{const result=await runBridgeOnce(config,{jobId:values['job-id']});console.log(JSON.stringify(result));}
      catch(error){console.error(JSON.stringify({phase:'worker_error',code:typeof error.code==='string'?error.code:'local_failure',...(Number.isInteger(error.status)?{status:error.status}:{}),outcomeUnknown:!!error.outcomeUnknown}));if(values.once){process.exitCode=1;break;}}
      if(values.once||stopping)break;
      await new Promise(resolve=>{const timer=setTimeout(()=>{interrupt=null;resolve();},config.pollIntervalMs);interrupt=()=>{clearTimeout(timer);interrupt=null;resolve();};});
    }while(!stopping);
  }finally{process.off('SIGINT',stop);process.off('SIGTERM',stop);}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(()=>{console.error('Worker configuration/arguments invalid. Use --help; no credentials are printed.');process.exitCode=1;});
