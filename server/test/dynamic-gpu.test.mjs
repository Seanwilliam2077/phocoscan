import test from 'node:test';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
test('single-image dynamic GPU selection refuses stale capacity and releases per-job leases',()=>{
 execFileSync('python3',[fileURLToPath(new URL('./dynamic_gpu_test.py',import.meta.url))],{stdio:'pipe'});
});
