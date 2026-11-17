import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makeViewerDerivative } from '../src/viewer.mjs';

const names = ['x', 'y', 'z', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3'];
async function fixture(t, bytes, format) {
  const directory = await mkdtemp(path.join(tmpdir(), 'pocketworld-viewer-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const filename = path.join(directory, `SYNTHETIC_TEST.${format}`); await writeFile(filename, bytes);
  return { filename, asset: { id: 'SYNTHETIC_TEST_ONLY', format, sha256: createHash('sha256').update(bytes).digest('hex') } };
}

test('PLY conversion uses real SH0 color, sigmoid opacity, exp scales, normalized wxyz quaternion and property names', async t => {
  // Deliberately reorder fields to prove conversion is semantic, not fixed offset.
  const reordered = [...names].reverse();
  const values = [1.25, -2.5, 3.75, 0, 10, -10, Math.log(3), Math.log(2), Math.log(0.5), 0, 2, 0, 2, 0];
  for (const encoding of ['ascii', 'binary_little_endian']) {
    const header = Buffer.from(`ply\nformat ${encoding} 1.0\ncomment SYNTHETIC TEST ONLY\nelement vertex 1\n${reordered.map(name => `property float ${name}`).join('\n')}\nend_header\n`);
    let body;
    if (encoding === 'ascii') body = Buffer.from([...values].reverse().join(' ') + '\n');
    else { body = Buffer.alloc(values.length * 4); [...values].reverse().forEach((v, i) => body.writeFloatLE(v, i * 4)); }
    const source = await fixture(t, Buffer.concat([header, body]), 'ply');
    const result = await makeViewerDerivative(source.filename, source.asset);
    [1.25, -2.5, 3.75, 2, 0.5, 1].forEach((v, i) => assert.ok(Math.abs(result.bytes.readFloatLE(i * 4) - v) < 1e-6));
    assert.deepEqual([...result.bytes.subarray(24)], [128, 255, 0, 191, 219, 128, 219, 128]);
    assert.equal(result.info.colorModel, 'SH0'); assert.equal(result.info.quaternionOrder, 'wxyz');
    assert.equal(result.info.sourceSha256, source.asset.sha256);
    await assert.rejects(makeViewerDerivative(source.filename, { ...source.asset, sha256: 'wrong' }), { code: 'source_hash_mismatch' });
  }
});

test('splat decimation deterministically samples the entire source without changing selected records', async t => {
  const sourceBytes = Buffer.alloc(10003 * 32, 128);
  for (let i = 0; i < 10003; i++) {
    [i, -i, 2, 0.1, 0.2, 0.3].forEach((v, j) => sourceBytes.writeFloatLE(v, i * 32 + j * 4));
    sourceBytes[i * 32 + 28] = 255;
  }
  const source = await fixture(t, sourceBytes, 'splat');
  const first = await makeViewerDerivative(source.filename, source.asset, 10000);
  const second = await makeViewerDerivative(source.filename, source.asset, 10000);
  assert.equal(first.info.pointCount, 10000); assert.equal(first.info.originalPointCount, 10003); assert.equal(first.info.decimated, true);
  assert.deepEqual(first.bytes, second.bytes);
  for (let i = 0; i < 10000; i++) {
    const sourceIndex = Math.floor(i * 10003 / 10000);
    assert.deepEqual(first.bytes.subarray(i * 32, i * 32 + 32), sourceBytes.subarray(sourceIndex * 32, sourceIndex * 32 + 32));
  }
  await assert.rejects(makeViewerDerivative(source.filename, source.asset, 100001), { code: 'invalid_point_budget' });
});

test('verified WorldMirror probability profile preserves transparency while standard PLY keeps logits', async t => {
  const ply = opacity => Buffer.from(`ply\nformat ascii 1.0\ncomment SYNTHETIC TEST ONLY\nelement vertex 1\n${names.map(name => `property float ${name}`).join('\n')}\nend_header\n0 0 1 0 0 0 ${opacity} -3 -3 -3 1 0 0 0\n`);
  const x = await fixture(t, ply(0), 'ply');
  const tagged = { ...x.asset, reconstructionTool: 'WorldMirror2', plyProfile: 'worldmirror2-probability-v1' };
  assert.equal((await makeViewerDerivative(x.filename, tagged)).bytes[27], 0);
  assert.equal((await makeViewerDerivative(x.filename, x.asset)).bytes[27], 128);
  await assert.rejects(makeViewerDerivative(x.filename, { ...tagged, reconstructionTool: 'gs_mcmc' }), { code: 'invalid_ply_profile' });
  const invalid = await fixture(t, ply(1.1), 'ply');
  await assert.rejects(makeViewerDerivative(invalid.filename, { ...invalid.asset, reconstructionTool: 'WorldMirror2', plyProfile: 'worldmirror2-probability-v1' }), { code: 'invalid_probability_opacity' });
});
