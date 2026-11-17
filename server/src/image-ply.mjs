import {readFile,writeFile,copyFile,rename,rm} from 'node:fs/promises';
import {constants} from 'node:fs';
import {createHash} from 'node:crypto';
import {requireThat,validateGaussian} from './validation.mjs';

// TripoSplat can export logit(0/1) as +/-Infinity. Preserve the untouched provider
// file, and saturate ONLY these opacity endpoints in the mobile derivative.
// Positions, SH, scales, rotations and NaNs still fail strict validation.
export function normalizeImagePLYBytes(input) {
  requireThat(input.length>0&&input.length<=150*1024*1024,422,'invalid_ply','Invalid image result size.');
  const head=input.subarray(0,65536).toString('ascii'), match=/(?:^|\n)end_header\r?\n/.exec(head);
  requireThat(match,422,'invalid_ply','Missing bounded PLY header.');
  const offset=match.index+match[0].length, lines=head.slice(0,offset).split(/\r?\n/);
  if(!lines.includes('format binary_little_endian 1.0'))return {bytes:input,changed:0};
  const elements=lines.filter(l=>l.startsWith('element '));
  requireThat(elements.length===1&&/^element vertex \d+$/.test(elements[0]),422,'invalid_ply','Unexpected PLY elements.');
  const count=Number(elements[0].split(' ')[2]);
  const props=lines.filter(l=>l.startsWith('property ')).map(l=>l.trim().split(/\s+/));
  requireThat(count>0&&count<=262144&&props.length>=14&&props.length<=256&&props.every(p=>p.length===3&&['float','float32'].includes(p[1]))
    &&new Set(props.map(p=>p[2])).size===props.length&&offset+count*props.length*4===input.length,422,'invalid_ply','Unexpected single-image PLY profile.');
  const opacity=props.findIndex(p=>p[2]==='opacity');
  requireThat(opacity>=0,422,'invalid_ply','Missing opacity.');
  const bytes=Buffer.from(input);let changed=0;
  for(let i=0;i<count;i++)for(let j=0;j<props.length;j++){
    const at=offset+(i*props.length+j)*4,v=bytes.readFloatLE(at);
    if(Number.isFinite(v))continue;
    requireThat(j===opacity&&(v===Infinity||v===-Infinity),422,'invalid_ply_record','Nonfinite geometry or color.');
    bytes.writeFloatLE(v>0?20:-20,at);changed++;
  }
  return {bytes,changed};
}
export async function normalizeImagePLY(file) {
  const original=await readFile(file),{bytes,changed}=normalizeImagePLYBytes(original);
  if(!changed)return null;
  const temporary=file+'.finite';
  try {
    await writeFile(temporary,bytes,{mode:0o600});
    await validateGaussian(temporary,'ply');
    // Keep the provider original even if publication subsequently fails.
    try{await copyFile(file,file+'.provider-original',constants.COPYFILE_EXCL);}catch(e){if(e.code!=='EEXIST')throw e;}
    await rename(temporary,file);
  } finally {await rm(temporary,{force:true});}
  return {kind:'saturated_opacity_endpoints',changed,finiteLogitBound:20,
    maxAlphaError:1/(1+Math.exp(20)),providerSha256:createHash('sha256').update(original).digest('hex')};
}
