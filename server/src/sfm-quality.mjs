import {readFile} from 'node:fs/promises';
const dot=(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),sub=(a,b)=>a.map((v,i)=>v-b[i]),add=(a,b)=>a.map((v,i)=>v+b[i]),mul=(a,s)=>a.map(v=>v*s),norm=a=>Math.sqrt(dot(a,a));
const mean=a=>mul(a.reduce(add,[0,0,0]),1/a.length),mv=(r,v)=>r.map(row=>dot(row,v));
const median=a=>a.sort((a,b)=>a-b)[Math.floor(a.length/2)];
function reject(reason){const e=new Error('Camera quality checks failed: '+reason);e.code='sfm_quality_insufficient';throw e;}
export function fitSimilarity(a,b){
 const ma=mean(a),mb=mean(b),aa=a.map(v=>sub(v,ma)),bb=b.map(v=>sub(v,mb));
 const h=Array.from({length:3},()=>[0,0,0]);aa.forEach((v,k)=>v.forEach((x,i)=>bb[k].forEach((y,j)=>h[i][j]+=x*y)));
 const [[xx,xy,xz],[yx,yy,yz],[zx,zy,zz]]=h;
 const m=[[xx+yy+zz,yz-zy,zx-xz,xy-yx],[yz-zy,xx-yy-zz,xy+yx,zx+xz],[zx-xz,xy+yx,-xx+yy-zz,yz+zy],[xy-yx,zx+xz,yz+zy,-xx-yy+zz]];
 const v=Array.from({length:4},(_,i)=>Array.from({length:4},(_,j)=>i===j?1:0));
 for(let it=0;it<80;it++){
  let p=0,q=1;for(let i=0;i<4;i++)for(let j=i+1;j<4;j++)if(Math.abs(m[i][j])>Math.abs(m[p][q])){p=i;q=j;}
  if(Math.abs(m[p][q])<1e-12)break;
  const angle=.5*Math.atan2(2*m[p][q],m[q][q]-m[p][p]),c=Math.cos(angle),s=Math.sin(angle),pp=m[p][p],qq=m[q][q],pq=m[p][q];
  m[p][p]=c*c*pp-2*s*c*pq+s*s*qq;m[q][q]=s*s*pp+2*s*c*pq+c*c*qq;m[p][q]=m[q][p]=0;
  for(let k=0;k<4;k++)if(k!==p&&k!==q){const x=m[k][p],y=m[k][q];m[k][p]=m[p][k]=c*x-s*y;m[k][q]=m[q][k]=s*x+c*y;}
  for(let k=0;k<4;k++){const x=v[k][p],y=v[k][q];v[k][p]=c*x-s*y;v[k][q]=s*x+c*y;}
 }
 let best=0;for(let i=1;i<4;i++)if(m[i][i]>m[best][best])best=i;
 const [w,x,y,z]=v.map(row=>row[best]);
 const r=[[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]];
 const spread=aa.reduce((s,v)=>s+dot(v,v),0);const scale=aa.reduce((s,v,i)=>s+dot(bb[i],mv(r,v)),0)/spread;
 if(!Number.isFinite(scale)||scale<=0)reject('degenerate_alignment');
 return{rotation:r,scale,translation:sub(mb,mul(mv(r,ma),scale))};
}
export function evaluateSfMQuality(records,cameras,selectedCount) {
 const registeredRatio=cameras.length/selectedCount;if(registeredRatio<.6)reject('registration_ratio');
 const pairs=cameras.map(c=>{const r=records.find(r=>r.trackingState==='normal'&&Math.abs(r.videoPTSSeconds-c.timeSeconds)<=.003);return r?{a:r.cameraToWorldARKit.flat(),b:c.cameraToWorld}:null;}).filter(Boolean);
 if(pairs.length<4)reject('tracked_camera_matches');
 const center=m=>[m[3],m[7],m[11]],forward=m=>[-m[2],-m[6],-m[10]],up=m=>[m[1],m[5],m[9]];
 const a=pairs.map(p=>center(p.a)),b=pairs.map(p=>center(p.b)),ma=mean(a),mb=mean(b);
 const sa=a.reduce((s,p)=>s+dot(sub(p,ma),sub(p,ma)),0),sb=b.reduce((s,p)=>s+dot(sub(p,mb),sub(p,mb)),0);
 if(Math.sqrt(sa/a.length)<.025||sb<1e-10)reject('insufficient_baseline');
 const rough=Math.sqrt(sb/sa);
 const from=a.concat(pairs.map(p=>add(center(p.a),forward(p.a)))),to=b.concat(pairs.map(p=>add(center(p.b),mul(forward(p.b),rough))));
 const fit=fitSimilarity(from,to),residual=a.reduce((s,p,i)=>{const e=sub(add(mul(mv(fit.rotation,p),fit.scale),fit.translation),b[i]);return s+dot(e,e);},0);
 const centerResidualRatio=Math.sqrt(residual/sb),residualMeters=Math.sqrt(residual/a.length)/fit.scale;
 const angles=pairs.map(p=>Math.max(...[forward,up].map(axis=>Math.acos(Math.max(-1,Math.min(1,dot(mv(fit.rotation,axis(p.a)),axis(p.b)))))*180/Math.PI)));
 const rotationErrorDegrees=median(angles);
 if(centerResidualRatio>.5||residualMeters>.15||rotationErrorDegrees>25)reject('pose_disagreement');
 return{version:1,registeredRatio,matchedCameras:pairs.length,centerResidualRatio,residualMeters,rotationErrorDegrees,reference:'device_reported_arkit',metricAccuracyVerified:false};
}
export async function checkNativeSfM(source,cameras,selectedCount) {
 if(source.sourceKind!=='native_arkit_capture')return null;
 const metadata=JSON.parse(await readFile(source.sourceMetadataPath,'utf8'));
 return evaluateSfMQuality(metadata.framesJSONL.split('\n').filter(Boolean).map(JSON.parse),cameras.frames,selectedCount);
}
