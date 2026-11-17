import test from 'node:test';import assert from 'node:assert/strict';
import {evaluateSfMQuality,fitSimilarity} from '../src/sfm-quality.mjs';
const poses=()=>Array.from({length:8},(_,i)=>({trackingState:'normal',videoPTSSeconds:i,cameraToWorldARKit:[[1,0,0,Math.sin(i)*.5],[0,1,0,0],[0,0,1,Math.cos(i)*.5],[0,0,0,1]]}));
test('similarity and camera quality preserve independent SfM scale and orientation',()=>{
 const a=[[0,0,0],[1,0,0],[0,1,0],[0,0,1]],b=a.map(([x,y,z])=>[4-2*y,5+2*x,6+2*z]);const f=fitSimilarity(a,b);assert.ok(Math.abs(f.scale-2)<1e-9);assert.ok(Math.abs(f.rotation[0][1]+1)<1e-9);
 const records=poses();const cameras=records.map(r=>({timeSeconds:r.videoPTSSeconds,cameraToWorld:r.cameraToWorldARKit.flat()}));
 const result=evaluateSfMQuality(records,cameras,8);assert.equal(result.registeredRatio,1);assert.ok(result.residualMeters<1e-8);
 assert.throws(()=>evaluateSfMQuality(records,cameras.slice(0,4),8),e=>e.code==='sfm_quality_insufficient');
 cameras[2].cameraToWorld[3]+=4;assert.throws(()=>evaluateSfMQuality(records,cameras,8),e=>e.code==='sfm_quality_insufficient');
});
