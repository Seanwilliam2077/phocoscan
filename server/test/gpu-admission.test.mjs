import test from 'node:test';
import assert from 'node:assert/strict';
import { gpuAdmission } from '../src/gpu-admission.mjs';
const check = gpus => gpuAdmission({snapshotPath:'fixture'}, {now:()=>100000,read:async()=>JSON.stringify({at:100000,gpus})});
test('GPU admission considers all cards rather than a fixed index',async()=>{
  const admit=check([{uuid:'GPU-0',freeMiB:1000},{uuid:'GPU-7',freeMiB:22000}]);
  await admit(['preview']); await admit(['refined']);
  await assert.rejects(admit(['preview','refined']),e=>e.status===503&&e.code==='server_busy');
  await assert.rejects(admit(['preview'],['refined']),e=>e.code==='server_busy');
});
test('missing stale or unreadable GPU telemetry fails closed',async()=>{
  for(const read of [async()=>'{',async()=>{throw Error('private');},async()=>JSON.stringify({at:0,gpus:[{uuid:'GPU-1',freeMiB:99999}]})]){
    const admit=gpuAdmission({snapshotPath:'fixture'},{now:()=>100000,read});
    await assert.rejects(admit(['arkit']),e=>e.code==='server_busy'&&!e.message.includes('private'));
    await admit([]);
  }
});

test('temporary executor affinity cannot admit a job against a different free card',async()=>{
  const admit=gpuAdmission({snapshotPath:'fixture',roleGPUUUIDs:{preview:['GPU-0']}},
    {now:()=>1,read:async()=>JSON.stringify({at:1,gpus:[{uuid:'GPU-0',freeMiB:1000},{uuid:'GPU-7',freeMiB:22000}]})});
  await admit(['refined']);
  await assert.rejects(admit(['preview']),e=>e.code==='server_busy');
});

test('single-image admission dynamically uses another card at its own memory threshold',async()=>{
 const admit=gpuAdmission({snapshotPath:'fixture',roleMinFreeMiB:{image:7000}},
  {now:()=>1,read:async()=>JSON.stringify({at:1,gpus:[{uuid:'GPU-0',freeMiB:1000},{uuid:'GPU-3',freeMiB:8000}]})});
 await admit(['image']);await assert.rejects(admit(['image'],['image']),e=>e.code==='server_busy');
 await assert.rejects(admit(['refined']),e=>e.code==='server_busy');
});
