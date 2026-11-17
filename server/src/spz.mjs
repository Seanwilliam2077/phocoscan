import { readFile } from 'node:fs/promises';
import { gunzipSync } from 'node:zlib';
import { requireThat } from './validation.mjs';
/** Bounded structural check of the v3 derivative; never replaces original PLY validation. */
export async function validateSPZ(file, {pointCount,shDegree}={}) {
  const compressed=await readFile(file);
  requireThat(compressed.length>16&&compressed.length<=150*1024*1024,422,'invalid_spz','Invalid SPZ size.');
  let data;try{data=gunzipSync(compressed,{maxOutputLength:70*1024*1024});}catch{requireThat(false,422,'invalid_spz','Invalid SPZ compression.');}
  const n=data.length>=16?data.readUInt32LE(8):0, degree=data[12];
  requireThat(data.length>=16&&data.readUInt32LE(0)===0x5053474e&&data.readUInt32LE(4)===3&&n>0&&n<=1000000&&degree<=3&&data[13]<=24
    &&(pointCount===undefined||n===pointCount)&&(shDegree===undefined||degree===shDegree)
    &&data.length===16+n*(20+3*((degree+1)**2-1)),422,'invalid_spz','SPZ profile does not match the result.');
  return {pointCount:n,shDegree:degree,byteSize:compressed.length};
}
