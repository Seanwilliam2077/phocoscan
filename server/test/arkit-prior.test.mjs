import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { arkitPosePriors, posePriorCSV } from '../src/dual-reconstruction-worker.mjs';

// SYNTHETIC frame tables only: no real capture, pose or reconstruction is represented.
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const pose = x => [[1, 0, 0, x], [0, 1, 0, 0.5], [0, 0, 1, -0.25], [0, 0, 0, 1]];

async function source(t, { tracking = () => 'normal', pts = i => i / 30 } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), 'arkit-prior-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const frames = Array.from({ length: 6 }, (_, i) => ({ index: i, arTimestampSeconds: 100 + i / 30, videoPTSSeconds: pts(i),
    cameraToWorldARKit: pose(i * 0.1), intrinsicsPixels: [[1000, 0, 960], [0, 1000, 720], [0, 0, 1]], trackingState: tracking(i) }));
  const envelope = Buffer.from(JSON.stringify({ manifest: {}, framesJSONL: frames.map(f => JSON.stringify(f)).join('\n') + '\n' }));
  const metadata = path.join(directory, 'metadata.json');
  await writeFile(metadata, envelope);
  return { sourceKind: 'native_arkit_capture', captureId: randomUUID(), captureReceiptId: randomUUID(),
    sourceMetadataPath: metadata, sourceMetadataSha256: sha(envelope), sourceMetadataByteSize: envelope.length };
}
// Selected video frames 1, 2, 4 and 5, as frame extraction reports them.
const selected = { frames: [1, 2, 4, 5].map((n, i) => ({ index: i, file: `image_${String(i + 1).padStart(4, '0')}.jpg`,
  sourceFrameIndex: n, sourceTimestampSeconds: n / 30 })) };

const HEADER = 'image_name,camera_id,timestamp_ns,center_x,center_y,center_z,qw,qx,qy,qz,position_std_m';
const rows = csv => csv.trim().split('\n').slice(1).map(line => line.split(','));

test('each selected frame gets the ARKit pose recorded for that exact video frame, in the Hub CSV format', async t => {
  const priors = await arkitPosePriors(await source(t), selected);
  assert.deepEqual(priors.map(p => p.name), ['image_000001.jpg', 'image_000002.jpg', 'image_000003.jpg', 'image_000004.jpg']);
  assert.deepEqual(priors.map(p => p.sourceFrameIndex), [1, 2, 4, 5]);
  assert.deepEqual(priors[2].position, [0.4, 0.5, -0.25]);
  const csv = posePriorCSV(priors);
  assert.equal(csv.split('\n')[0], HEADER);
  const table = rows(csv);
  assert.equal(table.length, 4, 'one row per image: the Hub requires full coverage');
  // ARKit's identity camera is the OpenCV camera turned 180 degrees about x: quaternion (0, 1, 0, 0).
  assert.deepEqual(table[2], ['image_000003.jpg', 'iphone_arkit', String(Math.round((100 + 4 / 30) * 1e9)),
    '0.400000000', '0.500000000', '-0.250000000', '0.000000000', '1.000000000', '0.000000000', '0.000000000', '0.100000']);
});

test('frames with limited tracking keep a row with a much looser prior', async t => {
  const priors = await arkitPosePriors(await source(t, { tracking: i => i === 2 ? 'limited(excessiveMotion)' : 'normal' }), selected);
  assert.equal(priors[1].tracking, 'limited');
  const table = rows(posePriorCSV(priors));
  assert.equal(table.length, 4);
  assert.equal(table[1][10], '1.000000');
  assert.equal(table[0][10], '0.100000');
  await assert.rejects(arkitPosePriors(await source(t, { tracking: i => i >= 4 ? 'normal' : 'notAvailable' }), selected),
    { code: 'arkit_tracking_insufficient' });
});

test('a pose recorded at a different video time, or changed metadata, is rejected rather than interpolated', async t => {
  await assert.rejects(arkitPosePriors(await source(t, { pts: i => i / 30 + (i === 4 ? 0.01 : 0) }), selected), { code: 'arkit_pose_mismatch' });
  const changed = await source(t);
  await writeFile(changed.sourceMetadataPath, '{"framesJSONL":""}');
  await assert.rejects(arkitPosePriors(changed, selected), { code: 'source_changed' });
  await assert.rejects(arkitPosePriors({ ...changed, sourceKind: 'external_rgb_video' }, selected), { code: 'arkit_poses_required' });
});
