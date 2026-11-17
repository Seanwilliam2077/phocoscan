// Prepare a private, source-bound FF/SfM display study from completed experiments.
// This tool never submits a reconstruction job or fabricates ARKit measurements.
import { readFile, writeFile, mkdir, copyFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';

const arg = process.argv.indexOf('--config');
if (arg < 0 || !process.argv[arg + 1]) throw Error('Use --config <private JSON file>.');
const configPath = path.resolve(process.argv[arg + 1]);
const json = async file => JSON.parse((await readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const config = await json(configPath);
const resolve = file => path.resolve(path.dirname(configPath), file);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const hashFile = async file => sha(await readFile(file));
const out = resolve(config.outputDirectory);
await mkdir(out, { recursive: true });
const ffDir = resolve(config.ffDirectory), sfmDir = resolve(config.sfmDirectory);
const ffSelectionPath = resolve(config.ffFrameManifest), sfmSelectionPath = resolve(config.sfmFrameManifest);
const [ff, sfm, ffSelection, sfmSelection, ffCamera, ffCameraProof, sfmCamera, ffDisplay] = await Promise.all([
  json(path.join(ffDir, 'manifest.json')), json(path.join(sfmDir, 'state.json')),
  json(ffSelectionPath), json(sfmSelectionPath), json(path.join(ffDir, 'predicted-cameras.json')),
  json(path.join(ffDir, 'predicted-cameras-provenance.json')), json(path.join(sfmDir, 'sfm-cameras-final.json')),
  json(path.join(ffDir, 'viewer-full-wm-probability-v1.json')),
]);
const sourceVideo = resolve(config.sourceVideoFile);
const sourceHash = await hashFile(sourceVideo);
assert.equal(sourceHash, ffSelection.source.sha256, 'FF source mismatch');
assert.equal(sourceHash, sfmSelection.source.sha256, 'SfM source mismatch');
assert.equal(sourceHash, sfm.source.sha256, 'SfM execution source mismatch');
assert.equal(ff.lastStatus, 'SUCCESS'); assert.equal(sfm.lastStatus, 'SUCCESS');
assert.equal(ff.phase, 'downloaded'); assert.equal(sfm.phase, 'downloaded');
assert.equal(ffCameraProof.projectId, ff.projectId); assert.equal(ffCameraProof.stepId, ff.stepId);
assert.equal(ffCameraProof.sourceModelSHA256, ff.output.sha256);
assert.equal(ffCameraProof.actualConvention, 'camera_to_world OpenCV (+x right,+y down,+z forward)');
assert.equal(await hashFile(path.join(ffDir, 'predicted-cameras.json')), ffCameraProof.localSHA256);
assert.equal(await hashFile(path.join(ffDir, 'scene.ply')), ff.output.sha256);
assert.equal(await hashFile(path.join(sfmDir, 'scene.ply')), sfm.output.sha256);
assert.equal(ffDisplay.sourceSha256, ff.output.sha256); assert.equal(ffDisplay.opacityEncoding, 'direct_probability');
assert.equal(ffDisplay.decimated, false); assert.equal(ffDisplay.pointCount, ff.output.gaussianCount);
assert.equal(ff.input.files.length, ffSelection.frames.length);
ff.input.files.forEach((f, i) => { assert.equal(f.sha256, ffSelection.frames[i].sha256); });
assert.deepEqual(sfm.frames, sfmSelection.frames);

function rotation(q) {
  assert.equal(q.length, 4); const norm = Math.hypot(...q);
  assert.ok(Math.abs(norm - 1) < 1e-4, 'Invalid source quaternion');
  const [w,x,y,z] = q.map(v => v / norm);
  return [[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
          [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
          [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]];
}
function inverseRigid(matrix) {
  const r = matrix.slice(0,3).map(row => row.slice(0,3));
  const t = matrix.slice(0,3).map(row => row[3]);
  return [0,1,2].map(i => [r[0][i],r[1][i],r[2][i],-r.reduce((s,row,j)=>s+row[i]*t[j],0)]).concat([[0,0,0,1]]);
}
function toGL(c2w) { return c2w.map(row => row.map((v,col) => col === 1 || col === 2 ? -v : v)).flat(); }
function record(frame, k, width, height, c2w, name) {
  assert.ok(frame && width > 0 && height > 0);
  return {sourceFrame:name, timeSeconds:frame.sourceTimestampSeconds, width,height,
    fx:k[0][0],fy:k[1][1],cx:k[0][2],cy:k[1][2],cameraToWorld:toGL(c2w)};
}
const ffFrames = ffCamera.extrinsics.map(e => {
  const k = ffCamera.intrinsics.find(i => i.camera_id === e.camera_id);
  assert.ok(k); return record(ffSelection.frames[e.camera_id],k.matrix,ffCameraProof.imageWidth,ffCameraProof.imageHeight,e.matrix,ffSelection.frames[e.camera_id].file);
});
assert.equal(ffFrames.length, ffSelection.frames.length);
assert.equal(new Set(ffFrames.map(f=>f.sourceFrame)).size, ffFrames.length);
const sfmFrames = sfmCamera.images.map(image => {
  const match = /^image_(\d{6})\.jpg$/.exec(image.name); assert.ok(match, 'Unrecognized prepared image name');
  const source = sfmSelection.frames[Number(match[1])-1]; assert.ok(source);
  const camera = sfmCamera.cameras.find(c=>c.id===image.cameraId); assert.equal(camera.model,'SIMPLE_PINHOLE');
  const r = rotation(image.worldToCamera.quaternionWXYZ), t=image.worldToCamera.translation;
  const c2w = inverseRigid(r.map((row,i)=>[...row,t[i]]).concat([[0,0,0,1]]));
  return record(source,camera.intrinsics,camera.width,camera.height,c2w,image.name);
}).sort((a,b)=>a.timeSeconds-b.timeSeconds);
assert.equal(sfmFrames.length, sfmSelection.frames.length);
assert.equal(new Set(sfmFrames.map(f=>f.sourceFrame)).size, sfmFrames.length);
const cameraPath = frames => ({version:1,coordinateSystem:'opengl_camera_to_world',matrixLayout:'row-major',scale:'unknown',frames});

// Independent check against observed COLMAP pixel coordinates, not a dummy camera.
// images.bin: image id, qvec, tvec, camera id, zero-terminated name, observations.
function reader(bytes) {
  let offset=0;
  const take=(method,size)=>{const v=bytes[method](offset);offset+=size;return v;};
  return {u64:()=>Number(take('readBigUInt64LE',8)),i64:()=>take('readBigInt64LE',8),u32:()=>take('readUInt32LE',4),f64:()=>take('readDoubleLE',8),
    skip:n=>{offset+=n;assert.ok(offset<=bytes.length);},
    string:()=>{const end=bytes.indexOf(0,offset);assert.ok(end>=offset);const v=bytes.subarray(offset,end).toString('utf8');offset=end+1;return v;},
    end:()=>assert.equal(offset,bytes.length)};
}
const sparseDir = path.join(sfmDir,'sfm-sparse-final');
const pr=reader(await readFile(path.join(sparseDir,'points3D.bin'))), points=new Map();
const pointCount=pr.u64(); let storedPointErrorSum=0;
for(let i=0;i<pointCount;i++) {const id=pr.u64(),xyz=[pr.f64(),pr.f64(),pr.f64()];pr.skip(3);storedPointErrorSum+=pr.f64();const tracks=pr.u64();pr.skip(tracks*8);points.set(BigInt(id),xyz);}
pr.end();
const ir=reader(await readFile(path.join(sparseDir,'images.bin'))), images=ir.u64();
const byName=new Map(sfmFrames.map(f=>[f.sourceFrame,f])); let observations=0,errorSum=0,maxError=0,behind=0;
for(let i=0;i<images;i++) {
  ir.u32(); ir.skip(7*8); ir.u32(); const name=ir.string(), n=ir.u64(), c=byName.get(name);assert.ok(c);
  const m=c.cameraToWorld,center=[m[3],m[7],m[11]];
  for(let j=0;j<n;j++) {
    const x=ir.f64(),y=ir.f64(),id=ir.i64();if(id===-1n)continue;
    const p=points.get(id);assert.ok(p);const d=p.map((v,k)=>v-center[k]);
    const cp=[0,1,2].map(k=>m[k]*d[0]+m[4+k]*d[1]+m[8+k]*d[2]);
    if(cp[2]>=0)behind++;
    const u=c.fx*cp[0]/(-cp[2])+c.cx,v=c.cy-c.fy*cp[1]/(-cp[2]);
    const e=Math.hypot(u-x,v-y);assert.ok(Number.isFinite(e));observations++;errorSum+=e;maxError=Math.max(maxError,e);
  }
}
ir.end();
const meanError=errorSum/observations;
assert.ok(observations>1000 && meanError<1 && behind===0,'Converted cameras failed observed-pixel reprojection');

await writeFile(path.join(out,'ff-cameras.json'),JSON.stringify(cameraPath(ffFrames),null,2)+'\n');
await writeFile(path.join(out,'sfm-cameras.json'),JSON.stringify(cameraPath(sfmFrames),null,2)+'\n');
const ffModel=path.join(ffDir,'viewer-full-wm-probability-v1.splat');
assert.equal(await hashFile(ffModel),ffDisplay.sha256);
await copyFile(ffModel,path.join(out,'preview.splat'));
await copyFile(path.join(sfmDir,'scene.ply'),path.join(out,'refined.ply'));
const manifest={id:config.studyId,title:config.title,sourceKind:'external_rgb_video',sourceVideoFile:sourceVideo,sourceVideoSha256:sourceHash,variants:[
  {id:config.previewId,role:'preview',algorithm:'gs_worldmirror2',format:'splat',shDegree:0,sourceFile:'preview.splat',sourceCameraFile:'ff-cameras.json',sha256:ffDisplay.sha256,
   provenance:{projectId:ff.projectId,stepId:ff.stepId,originalPlySHA256:ff.output.sha256,sourceFrameManifestSHA256:await hashFile(ffSelectionPath),cameraSource:'model_prediction',originalCameraSHA256:ffCameraProof.localSHA256,opacityProfile:'worldmirror2_probability_v1',lossy:true,decimated:false}},
  {id:config.refinedId,role:'refined',algorithm:'gs_mcmc',format:'ply',shDegree:3,sourceFile:'refined.ply',sourceCameraFile:'sfm-cameras.json',sha256:sfm.output.sha256,
   provenance:{projectId:sfm.projectId,stepId:sfm.stepId,sourceFrameManifestSHA256:await hashFile(sfmSelectionPath),cameraSource:'sfm_estimated',originalCameraSHA256:await hashFile(path.join(sfmDir,'sfm-cameras-final.json')),opacityProfile:'standard_logit',lossy:false,decimated:false}},
]};
await writeFile(path.join(out,'study-manifest.json'),JSON.stringify(manifest,null,2)+'\n');
const report={sourceVideoSHA256:sourceHash,ffCameras:ffFrames.length,sfmCameras:sfmFrames.length,
  sfmProjection:{method:'Project final COLMAP sparse observations using delivered OpenGL C2W/intrinsics',images,points:pointCount,observations,behindCamera:behind,meanErrorPixels:meanError,maxErrorPixels:maxError,storedMeanPerPointErrorPixels:storedPointErrorSum/pointCount},
  assets:await Promise.all(manifest.variants.map(async v=>({id:v.id,role:v.role,format:v.format,shDegree:v.shDegree,sha256:await hashFile(path.join(out,v.sourceFile)),byteSize:(await stat(path.join(out,v.sourceFile))).size,cameraSha256:await hashFile(path.join(out,v.sourceCameraFile))}))),
  iphoneVerified:false,metricScaleVerified:false,crossVersionAlignmentVerified:false};
await writeFile(path.join(out,'preparation-report.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
