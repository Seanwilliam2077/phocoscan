import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {createServer} from '../src/server.mjs';
import {IMAGE_CONSENT} from '../src/image-generations.mjs';
import {APIError} from '../src/validation.mjs';
import {normalizeImagePLY,normalizeImagePLYBytes} from '../src/image-ply.mjs';
import {validateGaussian} from '../src/validation.mjs';
import {readFile} from 'node:fs/promises';
import {validateSPZ} from '../src/spz.mjs';
async function fixture(t) {
 const root=await mkdtemp(path.join(tmpdir(),'phoco-image-test-'));let busy=false,executorBusy=false,phase='running',calls=0;
 const server=createServer({imageGeneration:{dynamicGPU:true},dataDir:root,adminToken:'a'.repeat(40),logger:{error(){}},gpuAdmission:async()=>{if(busy)throw new APIError(503,'server_busy','服务器繁忙中');},imageBridge:async(op,row)=>{
  if(op==='admit')return{available:!executorBusy};
  if(op==='delete')return{ok:true};calls++;
  if(op==='cancel')return{status:'cancelled'};
  if(phase==='lost'){const e=new Error();e.code='provider_unavailable';throw e;}
  if(['succeeded','endpoint','bad-result'].includes(phase)){
   const props=['x','y','z','f_dc_0','f_dc_1','f_dc_2','opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3'];
   await writeFile(path.join(root,'image-generations',row.id,'model.ply'),`ply\nformat ascii 1.0\ncomment SYNTHETIC FIXTURE\nelement vertex 1\n${props.map(p=>'property float '+p).join('\n')}\nend_header\n0 0 0 0 0 0 2 -3 -3 -3 1 0 0 0\n`);
   if(phase==='endpoint')await writeFile(path.join(root,'image-generations',row.id,'model.ply'),endpointPLY().bytes);
   if(phase==='bad-result')await writeFile(path.join(root,'image-generations',row.id,'model.ply'),'invalid');
   const packed=Buffer.alloc(phase==='endpoint'?56:36);packed.writeUInt32LE(0x5053474e);packed.writeUInt32LE(3,4);packed.writeUInt32LE(phase==='endpoint'?2:1,8);packed[13]=12;
   await writeFile(path.join(root,'image-generations',row.id,'model.spz'),gzipSync(packed));
  }
  return{status:['endpoint','bad-result'].includes(phase)?'succeeded':phase,jobId:'00000000-0000-0000-0000-000000000001',stage:'inference',progress:42};
 }});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 t.after(async()=>{await new Promise(r=>server.close(r));server.closeDatabase();await rm(root,{recursive:true,force:true});});
 const base=`http://127.0.0.1:${server.address().port}`;
 async function req(endpoint,method='GET',body,token,headers={}){const response=await fetch(base+endpoint,{method,headers:{...(token?{Authorization:'Bearer '+token}:{}),...(body&&!Buffer.isBuffer(body)?{'Content-Type':'application/json'}:{}),...headers},body:body===undefined?undefined:Buffer.isBuffer(body)?body:JSON.stringify(body)});return{status:response.status,data:response.headers.get('content-type')?.includes('json')?await response.json():await response.arrayBuffer()};}
 const token=(await req('/v1/auth/anonymous','POST',{})).data.token;
 const other=(await req('/v1/auth/anonymous','POST',{})).data.token;
 const image=Buffer.from([255,216,255,0,255,217]),sha256=createHash('sha256').update(image).digest('hex');
 async function uploaded(){const id=randomUUID(),url='/v2/image-generations/'+id;assert.equal((await req('/v2/image-generations','POST',{id,sha256,byteSize:image.length,consentVersion:IMAGE_CONSENT},token)).status,201);
  assert.equal((await req(url+'/image-upload','POST',{sha256,byteSize:image.length,mime:'image/jpeg'},token)).status,200);
  assert.equal((await req(url+'/image-upload','PATCH',image.subarray(0,3),token,{'Content-Type':'application/offset+octet-stream','Upload-Offset':'0'})).data.upload.offset,3);
  assert.equal((await req(url+'/image-upload','PATCH',image.subarray(3),token,{'Content-Type':'application/offset+octet-stream','Upload-Offset':'3'})).data.upload.complete,true);return{url,id};}
 return{req,token,other,uploaded,server,root,setBusy:v=>busy=v,setExecutorBusy:v=>executorBusy=v,setPhase:v=>phase=v,calls:()=>calls,start:(url,id=randomUUID())=>req(url+'/start','POST',{id,consentVersion:IMAGE_CONSENT},token)};
}
test('single-image lineage, resumable upload, explicit start, ownership, busy refusal, idempotency, verified result',async t=>{
 const h=await fixture(t),{url}=await h.uploaded();assert.equal(h.calls(),0);
 assert.equal((await h.req(url,'GET',undefined,h.other)).status,404);
 h.setBusy(true);assert.equal((await h.start(url)).status,503);assert.equal((await h.req(url,'GET',undefined,h.token)).data.image.status,'uploaded');
 h.setBusy(false);const first=await h.start(url);assert.equal(first.data.image.status,'queued');h.setBusy(true);
 assert.equal((await h.start(url)).data.image.attemptId,first.data.image.attemptId);
 h.setPhase('lost');await h.server.imageTick();assert.equal((await h.req(url,'GET',undefined,h.token)).data.image.connectionInterrupted,true);
 h.setPhase('succeeded');await h.server.imageTick();const ready=(await h.req(url,'GET',undefined,h.token)).data.image;assert.equal(ready.status,'ready');assert.equal(ready.result.provenance,'ai_single_image');assert.equal(ready.result.metricScaleVerified,false);
 assert.equal((await h.req(ready.result.spz.path,'GET',undefined,h.token)).status,200);
 assert.equal((await h.req(ready.result.spz.path,'GET',undefined,h.other)).status,404);
 assert.equal((await h.req(url,'DELETE',undefined,h.token)).status,200);
});
test('cancel before submission never invokes a GPU job; deletion requires terminal state',async t=>{
 const h=await fixture(t),{url}=await h.uploaded();await h.start(url);
 assert.equal((await h.req(url,'DELETE',undefined,h.token)).status,409);
 await h.req(url+'/cancel','POST',{},h.token);await h.server.imageTick();assert.equal(h.calls(),0);
 assert.equal((await h.req(url,'GET',undefined,h.token)).data.image.status,'cancelled');
});
test('SPZ rejects truncated or misidentified derivatives',async t=>{
 const h=await fixture(t),file=path.join(h.root,'bad.spz');await writeFile(file,gzipSync(Buffer.alloc(36)));
 await assert.rejects(validateSPZ(file),e=>e.code==='invalid_spz');
});

test('executor memory refusal precedes persisting a generation attempt',async t=>{
 const h=await fixture(t),{url}=await h.uploaded();h.setExecutorBusy(true);
 const result=await h.start(url);assert.equal(result.status,503);assert.equal(result.data.error.code,'server_busy');
 const image=(await h.req(url,'GET',undefined,h.token)).data.image;
 assert.equal(image.status,'uploaded');assert.equal(image.attemptId,undefined);assert.equal(h.calls(),0);
});

function endpointPLY() {
 const props=['x','y','z','f_dc_0','f_dc_1','f_dc_2','opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3'];
 const header=Buffer.from(`ply\nformat binary_little_endian 1.0\nelement vertex 2\n${props.map(p=>'property float '+p).join('\n')}\nend_header\n`);
 const body=Buffer.alloc(2*props.length*4);
 for(let i=0;i<2;i++)[0,0,1,0,0,0,i? -Infinity:Infinity,-3,-3,-3,1,0,0,0].forEach((v,j)=>body.writeFloatLE(v,(i*props.length+j)*4));
 return {bytes:Buffer.concat([header,body]),offset:header.length};
}
test('TripoSplat opacity endpoints become finite without changing geometry, retaining the original',async t=>{
 const h=await fixture(t), file=path.join(h.root,'endpoint.ply'), {bytes,offset}=endpointPLY();
 await writeFile(file,bytes);await assert.rejects(validateGaussian(file,'ply'),e=>e.code==='invalid_ply_record');
 const report=await normalizeImagePLY(file);assert.equal(report.changed,2);assert.ok(report.maxAlphaError<3e-9);
 assert.deepEqual(await readFile(file+'.provider-original'),bytes);
 const finite=await readFile(file);assert.equal(finite.readFloatLE(offset+6*4),20);assert.equal(finite.readFloatLE(offset+(14+6)*4),-20);
 assert.equal((await validateGaussian(file,'ply')).gaussianCount,2);
 assert.equal(await normalizeImagePLY(file),null);
 for(let i=0;i<finite.length;i++)if(![offset+26,offset+27,offset+82,offset+83].includes(i))assert.equal(finite[i],bytes[i]);
});
test('single-image endpoint conversion still rejects NaNs and nonfinite geometry',()=>{
 const {bytes,offset}=endpointPLY();
 for(const [property,value] of [[0,Infinity],[7,-Infinity],[6,NaN]]) {
  const bad=Buffer.from(bytes);bad.writeFloatLE(value,offset+property*4);
  assert.throws(()=>normalizeImagePLYBytes(bad),e=>e.code==='invalid_ply_record');
 }
});

test('failed delivery can recover the same provider attempt without rerunning GPU admission',async t=>{
 const h=await fixture(t),{url}=await h.uploaded();const first=(await h.start(url)).data.image;
 h.setPhase('bad-result');await h.server.imageTick();
 assert.equal((await h.req(url,'GET',undefined,h.token)).data.image.errorCode,'invalid_result');
 assert.equal((await h.req(url+'/retry-delivery','POST',{},h.other)).status,404);
 h.setBusy(true);h.setExecutorBusy(true);h.setPhase('endpoint');
 const retry=await h.req(url+'/retry-delivery','POST',{},h.token);assert.equal(retry.status,200);assert.equal(retry.data.image.attemptId,first.attemptId);
 await h.server.imageTick();const ready=(await h.req(url,'GET',undefined,h.token)).data.image;
 assert.equal(ready.status,'ready');assert.equal(ready.attemptId,first.attemptId);assert.equal(ready.attempts.length,0);assert.equal(ready.result.normalization.changed,2);
 assert.equal((await h.req(ready.result.spz.path,'GET',undefined,h.token)).status,200);
 assert.equal((await h.req(url+'/retry-delivery','POST',{},h.token)).data.image.status,'ready');
 const fresh=await h.uploaded();assert.equal((await h.req(fresh.url+'/retry-delivery','POST',{},h.token)).status,409);
});
