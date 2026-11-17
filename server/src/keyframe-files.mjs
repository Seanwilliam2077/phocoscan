import path from 'node:path';
import {mkdir,readFile,writeFile,rename,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {requireThat} from './validation.mjs';
import {resumableUploads} from './resumable-upload.mjs';
import {MAX_KEYFRAME_PACK,KEYFRAME_PACK_MIME} from './keyframe-pack.mjs';
const hash=b=>createHash('sha256').update(b).digest('hex');
const SHA=/^[a-f0-9]{64}$/;
export function keyframeFileRoutes({root,ownCapture,captureStatus,acceptKeyframes,locked,bodyJSON,json}) {
 const transfers=resumableUploads({limit:20*1024*1024,types:new Set(['application/octet-stream'])});
 async function manifest(dir){try{return JSON.parse(await readFile(path.join(dir,'manifest.json'),'utf8'));}catch(e){if(e.code==='ENOENT')return null;throw e;}}
 return async(req,res,userId,pathname)=>{
  const m=/^\/v2\/captures\/([^/]+)\/keyframe-files(?:\/(commit)|\/files\/([a-f0-9]{64}))?$/.exec(pathname);if(!m)return false;
  const [,id,commit,sha]=m;ownCapture(id,userId);
  await locked(id,async()=>{
   const row=ownCapture(id,userId);requireThat(row.verifiedAt&&row.metadataPath,409,'capture_incomplete','Verify the capture first.');
   const dir=path.join(root,'captures-v2',id,'keyframe-files'),stored=await manifest(dir);
   if(!commit&&!sha&&req.method==='POST'){
    const b=await bodyJSON(req,1024*1024);requireThat(SHA.test(b.sha256??'')&&Number.isSafeInteger(b.byteSize)&&b.byteSize>12&&b.byteSize<=MAX_KEYFRAME_PACK&&typeof b.indexBase64==='string'&&b.indexBase64.length<300000,422,'invalid_keyframe_pack','Invalid keyframe file manifest.');
    const raw=Buffer.from(b.indexBase64,'base64');let index;try{index=JSON.parse(raw);}catch{requireThat(false,422,'invalid_keyframe_pack','Invalid keyframe index.');}
    requireThat(index.version===1&&index.captureId===id&&Array.isArray(index.files)&&index.files.length>=9&&index.files.length<=130,422,'invalid_keyframe_pack','Invalid keyframe files.');
    const names=new Set();let size=12+raw.length;
    for(const f of index.files){requireThat(/^(transforms\.json|meta\.json|images\/image_\d{6}\.jpg|masks\/image_\d{6}\.png)$/.test(f.path??'')&&!names.has(f.path)&&SHA.test(f.sha256??'')&&Number.isSafeInteger(f.byteSize)&&f.byteSize>0&&f.byteSize<=20*1024*1024,422,'invalid_keyframe_pack','Invalid keyframe entry.');names.add(f.path);size+=f.byteSize;}
    requireThat(size===b.byteSize,422,'invalid_keyframe_pack','Manifest size mismatch.');
    requireThat(!stored||stored.sha256===b.sha256&&stored.indexBase64===b.indexBase64,409,'keyframes_conflict','A different manifest already exists.');
    requireThat(!row.keyframesHash||row.keyframesHash===b.sha256,409,'keyframes_conflict','Keyframes are immutable.');
    await mkdir(dir,{recursive:true});if(!stored)await writeFile(path.join(dir,'manifest.json'),JSON.stringify({...b,files:index.files}),{flag:'wx',mode:0o600});
    json(res,200,{complete:!!row.keyframesHash,capture:captureStatus(row)});return;
   }
   requireThat(stored,404,'manifest_required','Declare the keyframe manifest first.');
   if(sha){
    const entry=stored.files.find(f=>f.sha256===sha);requireThat(entry,404,'file_not_in_manifest','File is not part of this capture.');
    const file=path.join(dir,sha),partial=path.join(dir,sha+'.partial');
    let complete=false;try{const bytes=await readFile(file);complete=bytes.length===entry.byteSize&&hash(bytes)===sha;}catch(e){if(e.code!=='ENOENT')throw e;}
    const done={sha256:sha,byteSize:entry.byteSize,mime:'application/octet-stream',offset:entry.byteSize,complete:true};
    if(req.method==='POST'){
     const b=await bodyJSON(req,4096);requireThat(b.sha256===sha&&b.byteSize===entry.byteSize&&b.mime==='application/octet-stream',409,'source_conflict','File differs from manifest.');
     json(res,200,{upload:complete?done:await transfers.begin(partial,b)});return;
    }
    if(req.method==='PATCH'){
     requireThat(!complete,409,'offset_mismatch','File is already complete.');const status=await transfers.append(partial,req);
     if(status.offset===entry.byteSize){const upload=await transfers.finalize(partial);await rename(upload.temporary,file);await transfers.discard(partial);json(res,200,{upload:done});}
     else json(res,200,{upload:status});return;
    }
    if(req.method==='GET'){json(res,200,{upload:complete?done:await transfers.status(partial)});return;}
   }
   if(commit&&req.method==='POST'){
    await bodyJSON(req,4096);if(row.keyframesHash){requireThat(row.keyframesHash===stored.sha256,409,'keyframes_conflict','Keyframes changed.');json(res,200,{capture:captureStatus(row)});return;}
    const index=Buffer.from(stored.indexBase64,'base64'),prefix=Buffer.alloc(12);prefix.write('PWPACK01');prefix.writeUInt32LE(index.length,8);
    const chunks=[prefix,index];for(const f of stored.files){let data;try{data=await readFile(path.join(dir,f.sha256));}catch{requireThat(false,409,'file_missing','A keyframe file needs uploading.');}requireThat(data.length===f.byteSize&&hash(data)===f.sha256,409,'hash_mismatch','A keyframe file needs uploading.');chunks.push(data);}
    const bytes=Buffer.concat(chunks);requireThat(bytes.length===stored.byteSize&&hash(bytes)===stored.sha256,422,'hash_mismatch','Keyframe package hash differs.');
    const temporary=path.join(dir,'assembled.pwpack');await writeFile(temporary,bytes,{mode:0o600});
    try{const capture=await acceptKeyframes(row,id,userId,{temporary,size:bytes.length,hash:stored.sha256,mime:KEYFRAME_PACK_MIME});json(res,200,{capture});}
    finally{await rm(temporary,{force:true});}return;
   }
   requireThat(false,405,'method_not_allowed','Invalid keyframe upload operation.');
  });return true;
 };
}
