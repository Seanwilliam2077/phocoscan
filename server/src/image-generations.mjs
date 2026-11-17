import { normalizeImagePLY } from './image-ply.mjs';
import { validateSPZ } from './spz.mjs';
import path from 'node:path';
import { mkdir, readFile, rename, rm, stat } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { requireThat, uuid, validateJPEG, validateGaussian } from './validation.mjs';
import { resumableUploads } from './resumable-upload.mjs';
const exec = promisify(execFile);
const now = () => new Date().toISOString();
export const IMAGE_CONSENT = '2026-11-10-single-image-v1';
const SHA = /^[a-f0-9]{64}$/;
const LIMIT = 20 * 1024 * 1024;
const pending = ['queued', 'processing', 'cancelling'];
function presentationHint(hint) {
  const valid = a => Array.isArray(a) && a.every(n => typeof n === 'number' && Number.isFinite(n) && Math.abs(n) < 10000);
  return hint && valid(hint.center) && hint.center.length === 3 && Array.isArray(hint.first_camera_to_world)
    && hint.first_camera_to_world.length === 4 && hint.first_camera_to_world.every(r => valid(r) && r.length === 4)
    ? {center:hint.center,first_camera_to_world:hint.first_camera_to_world} : null;
}

// A separate lineage: an AI-generated object from one JPEG is never a native scan receipt.
export function imageGenerations(db, { root, config, locked, checkGPU, sendFile, json, bodyJSON, bridge: suppliedBridge }) {
  db.exec(`CREATE TABLE IF NOT EXISTS image_generations (id TEXT PRIMARY KEY,userId TEXT NOT NULL,json TEXT NOT NULL)`);
  const uploads = resumableUploads({ limit: LIMIT, types: new Set(['image/jpeg']) });
  const folder = id => path.join(root, 'image-generations', id);
  const read = (id, userId) => {
    requireThat(uuid(id),422,'invalid_id','无效项目编号。'); const row = db.prepare('SELECT * FROM image_generations WHERE id=? AND userId=?').get(id,userId);
    requireThat(row,404,'not_found','图片项目不存在。'); return JSON.parse(row.json);
  };
  const save = row => { row.updatedAt=now(); db.prepare('INSERT INTO image_generations VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json').run(row.id,row.userId,JSON.stringify(row)); return row; };
  const view = ({userId,providerId,...row}) => row;
  const bridge = suppliedBridge ?? (async (operation, row) => {
    requireThat(config?.python && config?.helper,503,'service_unavailable','单图生成服务暂不可用。');
    try {
      const {stdout}=await exec(config.python,[config.helper,'--config',config.configFile,operation,row.id,row.attemptId ?? row.id,folder(row.id),row.providerId ?? ''],{timeout:180000,maxBuffer:1024*1024});
      return JSON.parse(stdout);
    } catch { const e=new Error('图片服务连接中断，请稍后刷新。');e.code='provider_unavailable';throw e; }
  });
  const countQueued=()=>db.prepare('SELECT json FROM image_generations').all().map(r=>JSON.parse(r.json)).filter(r=>pending.includes(r.status)).length;
  const fileInfo=async(id,name)=>{
    const file=path.join(folder(id),name), size=(await stat(file)).size;
    requireThat(size>0&&size<=150*1024*1024,422,'invalid_result','生成结果不完整。');
    return {sha256:createHash('sha256').update(await readFile(file)).digest('hex'),byteSize:size};
  };
  async function tickRow(row) {
    if (row.status==='cancelling') {
      if(!row.submitAttempted){row.status='cancelled';save(row);return;}
      // Re-submit the same key if an earlier submit response was lost, then cancel that exact job.
      const r=await bridge('cancel',row);
      if(['cancelled','canceled','failed','succeeded'].includes(r.status)) { row.status='cancelled';save(row); }
      return;
    }
    row.submitAttempted=true;row.connectionInterrupted=false;save(row);
    const r=await bridge('advance',row);
    if(r.jobId)row.providerId=r.jobId;
    row.phase=['queued','loading','preprocessing','inference','exporting','uploading'].includes(r.stage)?r.stage:'processing';
    row.progress=Math.round(Math.max(0,Math.min(99,Number(r.progress)||0)));
    if(r.status==='succeeded') {
      const normalization=await normalizeImagePLY(path.join(folder(row.id),'model.ply'));
      const model=await validateGaussian(path.join(folder(row.id),'model.ply'),'ply');
      await validateSPZ(path.join(folder(row.id),'model.spz'),{pointCount:model.gaussianCount,shDegree:0});
      const ply=await fileInfo(row.id,'model.ply'),spz=await fileInfo(row.id,'model.spz');
      requireThat(model.gaussianCount>0&&model.gaussianCount<=262144,422,'invalid_result','生成结果超出范围。');
      row.result={ply:{...ply,path:`/v2/image-generations/${row.id}/result/ply`},spz:{...spz,path:`/v2/image-generations/${row.id}/result/spz`},pointCount:model.gaussianCount,viewHint:presentationHint(r.viewHint),sourceImageSha256:row.sha256,algorithm:'triposplat',provenance:'ai_single_image',metricScaleVerified:false,...(normalization?{normalization}:{})};
      row.status='ready';row.progress=100;row.phase='ready';row.errorCode=null;
    } else if(['failed','cancelled','canceled'].includes(r.status)) {
      row.status='failed';row.errorCode=['GPU_BUSY','GPU_OOM','INSUFFICIENT_GPU_MEMORY'].includes(r.errorCode)?'server_busy':'image_generation_failed';
    } else row.status='processing';
    save(row);
  }
  let ticking=false;
  async function tick() {
    if(ticking||!config&&!suppliedBridge)return;
    ticking=true;
    try { for(const {json:raw} of db.prepare('SELECT json FROM image_generations').all()) {
      const row=JSON.parse(raw);if(!pending.includes(row.status))continue;
      await locked('image:'+row.id,async()=>{
        const current=read(row.id,row.userId);if(!pending.includes(current.status))return;
        try { await tickRow(current); } catch(e) {
          if(e.code==='provider_unavailable') {current.connectionInterrupted=true;save(current);}
          else {current.status='failed';current.errorCode='invalid_result';save(current);}
        }
      });
    }} finally {ticking=false;}
  }
  async function route(req,res,userId,pathname) {
    if(!pathname.startsWith('/v2/image-generations'))return false;
    const method=req.method;
    if(pathname==='/v2/image-generations') {
      if(method==='GET'){json(res,200,{images:db.prepare('SELECT json FROM image_generations WHERE userId=? ORDER BY rowid DESC').all(userId).map(r=>view(JSON.parse(r.json)))});return true;}
      if(method==='POST'){
        const b=await bodyJSON(req);requireThat(uuid(b.id),422,'invalid_id','无效请求编号。');
        requireThat(b.consentVersion===IMAGE_CONSENT&&SHA.test(b.sha256??'')&&Number.isSafeInteger(b.byteSize)&&b.byteSize>0&&b.byteSize<=LIMIT,422,'invalid_image','请确认单图生成并选择有效图片。');
        await locked('image:'+b.id,async()=>{
          const old=db.prepare('SELECT userId,json FROM image_generations WHERE id=?').get(b.id);
          if(old){requireThat(old.userId===userId,404,'not_found','图片项目不存在。');const r=JSON.parse(old.json);requireThat(r.sha256===b.sha256&&r.byteSize===b.byteSize,409,'source_conflict','原图不可替换。');json(res,200,{image:view(r)});return;}
          await mkdir(folder(b.id),{recursive:true});
          json(res,201,{image:view(save({id:b.id,userId,sha256:b.sha256,byteSize:b.byteSize,status:'draft',sourceKind:'ai_single_image',createdAt:now(),attempts:[]}))});
        });return true;
      }
    }
    const m=/^\/v2\/image-generations\/([^/]+)(?:\/(image-upload|start|retry-delivery|cancel|result\/(?:ply|spz)))?$/.exec(pathname);
    requireThat(m,404,'not_found','接口不存在。');const [,id,action]=m;read(id,userId);
    await locked('image:'+id,async()=>{
      let row=read(id,userId);const dir=path.join(folder(id),'upload');
      if(!action&&method==='GET'){json(res,200,{image:view(row)});return;}
      if(!action&&method==='DELETE'){
        requireThat(!pending.includes(row.status),409,'task_active','请先取消生成。');
        await bridge('delete',row);await uploads.discard(dir);await rm(folder(id),{recursive:true,force:true});db.prepare('DELETE FROM image_generations WHERE id=? AND userId=?').run(id,userId);json(res,200,{ok:true});return;
      }
      if(action==='image-upload'){
        const complete={sha256:row.sha256,byteSize:row.byteSize,mime:'image/jpeg',offset:row.byteSize,complete:true};
        if(method==='GET'){json(res,200,{upload:row.status!=='draft'?complete:await uploads.status(dir)});return;}
        if(method==='POST'){
          const b=await bodyJSON(req);requireThat(b.sha256===row.sha256&&b.byteSize===row.byteSize&&b.mime==='image/jpeg',409,'source_conflict','原图不可替换。');
          json(res,200,{upload:row.status!=='draft'?complete:await uploads.begin(dir,b)});return;
        }
        if(method==='PATCH'){
          requireThat(row.status==='draft',409,'already_uploaded','图片已上传。');
          const s=await uploads.append(dir,req);
          if(s.offset===s.byteSize){const file=await uploads.finalize(dir);await validateJPEG(file.temporary);await rename(file.temporary,path.join(folder(id),'image.jpg'));await uploads.discard(dir);row.status='uploaded';save(row);}
          json(res,200,{upload:row.status==='uploaded'?complete:s});return;
        }
      }
      if(action==='retry-delivery'&&method==='POST'){
        await bodyJSON(req);
        if(row.status==='ready'||pending.includes(row.status)){json(res,200,{image:view(row)});return;}
        requireThat(row.status==='failed'&&row.errorCode==='invalid_result'&&uuid(row.providerId)&&uuid(row.attemptId),409,'delivery_unavailable','没有可恢复的已生成结果。');
        // Keep the exact provider/attempt. This only fetches and validates its files;
        // it never calls admission or starts a fresh GPU job.
        row.status='processing';row.phase='exporting';row.connectionInterrupted=false;save(row);
        json(res,200,{image:view(row)});return;
      }
      if(action==='start'&&method==='POST'){
        const b=await bodyJSON(req);requireThat(uuid(b.id),422,'invalid_id','无效请求编号。');requireThat(b.consentVersion===IMAGE_CONSENT,422,'consent_required','请确认单图生成。');
        requireThat(config||suppliedBridge,503,'service_unavailable','单图生成服务暂不可用。');
        if(row.attemptId===b.id||pending.includes(row.status)||row.status==='ready'){json(res,200,{image:view(row)});return;}
        requireThat(['uploaded','failed','cancelled'].includes(row.status),409,'image_required','请先上传图片。');
        await locked('gpu-admission',async()=>{
          await checkGPU(['image'],countQueued());
          if(config?.dynamicGPU) {
            const admission=await bridge('admit',row);
            requireThat(admission.available===true,503,'server_busy','服务器繁忙中');
          }
          if(row.attemptId)row.attempts.push({id:row.attemptId,status:row.status,errorCode:row.errorCode??null});
          row.attemptId=b.id;row.providerId=null;row.submitAttempted=false;row.status='queued';row.errorCode=null;row.connectionInterrupted=false;save(row);
        });json(res,200,{image:view(row)});return;
      }
      if(action==='cancel'&&method==='POST'){
        await bodyJSON(req);if(pending.includes(row.status)){row.status='cancelling';save(row);}json(res,200,{image:view(row)});return;
      }
      if(action?.startsWith('result/')&&method==='GET'){
        requireThat(row.status==='ready'&&row.result,404,'not_ready','结果尚未就绪。');const kind=action.split('/')[1],file=row.result[kind];
        await sendFile(req,res,path.relative(root,path.join(folder(id),'model.'+kind)),'application/octet-stream',file.sha256);return;
      }
      requireThat(false,404,'not_found','接口不存在。');
    });return true;
  }
  return {route,tick,countQueued};
}
