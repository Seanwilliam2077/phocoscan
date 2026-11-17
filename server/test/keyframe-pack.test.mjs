import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { inspectKeyframePack, extractKeyframePack, MIN_PACK_FRAMES } from '../src/keyframe-pack.mjs';
import { packageFrames, arkitPosePriors, posePriorCSV, runDualWorkerOnce } from '../src/dual-reconstruction-worker.mjs';
import { arkitFrames, buildPack, framesJSONL, pad } from './keyframe-fixtures.mjs';

// SYNTHETIC packs and frame tables only: no real capture, pose or reconstruction is represented.
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const id = randomUUID();
const records = arkitFrames(30);
const chosen = records.filter((_, i) => i % 3 === 0); // 10 keyframes
const inspect = (bytes, extra = {}) => inspectKeyframePack(bytes, { captureId: id, framesJSONL: framesJSONL(records), ...extra });
const code = expected => error => error.code === expected;

test('a pack of frames the capture already lists is accepted and summarized', () => {
  const bytes = buildPack(id, chosen, { masks: true });
  const { summary } = inspect(bytes);
  assert.equal(summary.sha256, sha(bytes));
  assert.equal(summary.frameCount, 10);
  assert.equal(summary.masks, true);
  assert.equal(summary.mode, 'person');
  assert.equal(summary.frames[1].file, 'image_000002.jpg');
  assert.equal(summary.frames[1].mask, 'image_000002.png');
  assert.equal(summary.frames[1].sourceFrameIndex, 3, 'mapped to the capture frame with the same ARKit timestamp');
  assert.equal(summary.frames[1].videoPTSSeconds, 3 / 30);
});

test('keyframes must be real, normally tracked frames of this capture with the same pose', () => {
  assert.throws(() => inspect(buildPack(id, chosen, { edit: t => { t.frames[4].transform_matrix[0][3] += 0.05; return t; } })),
    code('keyframe_not_in_capture'), 'a moved pose');
  assert.throws(() => inspect(buildPack(id, chosen, { edit: t => { t.frames[4].timestamp += 0.004; return t; } })),
    code('keyframe_not_in_capture'), 'a time between frames');
  const limited = arkitFrames(30, { tracking: i => i === 6 ? 'limited(excessiveMotion)' : 'normal' });
  assert.throws(() => inspectKeyframePack(buildPack(id, chosen), { captureId: id, framesJSONL: framesJSONL(limited) }),
    code('keyframe_not_in_capture'), 'limited tracking');
  // JSON writers may round the last digit of a timestamp differently.
  assert.doesNotThrow(() => inspect(buildPack(id, chosen, { edit: t => { t.frames[2].timestamp += 2e-7; return t; } })));
});

test('malformed packs are refused before anything is stored', () => {
  assert.throws(() => inspect(buildPack(randomUUID(), chosen)), code('invalid_keyframe_pack'), 'another capture');
  assert.throws(() => inspect(buildPack(id, chosen.slice(0, MIN_PACK_FRAMES - 1))), code('invalid_keyframe_pack'), 'too few');
  assert.throws(() => inspect(buildPack(id, chosen, { tamper: b => { const c = Buffer.from(b); c[c.length - 3] ^= 1; return c; } })),
    code('keyframe_hash_mismatch'));
  assert.throws(() => inspect(Buffer.concat([buildPack(id, chosen), Buffer.from('x')])), code('invalid_keyframe_pack'), 'trailing bytes');
  assert.throws(() => inspect(buildPack(id, chosen, { extraFiles: [['../escape.jpg', Buffer.from('x')]] })), code('invalid_keyframe_pack'));
  assert.throws(() => inspect(buildPack(id, chosen, { edit: t => { delete t.frames[3].mask_path; return t; }, masks: true })),
    code('invalid_keyframe_pack'), 'a mask not referenced by its frame');
  assert.throws(() => inspect(buildPack(id, chosen, { edit: t => { t.frames.reverse(); return t; } })), code('invalid_keyframe_pack'), 'out of order');
});

async function workspace(t) {
  const directory = await mkdtemp(path.join(tmpdir(), 'keyframe-pack-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

test('extraction, worker frames and pose priors line up with the capture frames', async t => {
  const directory = await workspace(t);
  const bytes = buildPack(id, chosen, { masks: true });
  const packFile = path.join(directory, 'pack.bin'), stored = path.join(directory, 'keyframes');
  await writeFile(packFile, bytes);
  const summary = await extractKeyframePack(packFile, stored, { captureId: id, framesJSONL: framesJSONL(records) });
  assert.deepEqual((await readdir(path.join(stored, 'images'))).length, 10);
  assert.deepEqual(JSON.parse(await readFile(path.join(stored, 'pack.json'), 'utf8')), summary);

  const envelope = Buffer.from(JSON.stringify({ manifest: {}, framesJSONL: framesJSONL(records) }));
  const metadata = path.join(directory, 'metadata.json'); await writeFile(metadata, envelope);
  const source = { sourceKind: 'native_arkit_capture', captureId: id, captureReceiptId: randomUUID(), sourceVideoSha256: 'a'.repeat(64),
    sourceByteSize: 1, sourceMetadataPath: metadata, sourceMetadataSha256: sha(envelope), sourceMetadataByteSize: envelope.length,
    keyframes: { ...summary, directory: stored } };
  const job = path.join(directory, 'job');
  const frames = await packageFrames({ directory: job, source });
  assert.equal(frames.selection, 'phone_keyframes');
  assert.equal(frames.keyframesSha256, summary.sha256);
  assert.deepEqual(await readdir(frames.directory), chosen.map((_, i) => `image_${pad(i + 1)}.jpg`));
  assert.deepEqual(await readdir(frames.maskDirectory), chosen.map((_, i) => `image_${pad(i + 1)}.png`));
  const sfm = await packageFrames({ directory: path.join(directory, 'sfm-job'), source, posePriorUsed: false });
  assert.equal(sfm.metadata.posePriorUsed, false);
  assert.equal(sfm.metadata.masks, true);
  await assert.rejects(packageFrames({ directory: path.join(directory, 'sfm-job'), source, posePriorUsed: true }), { code: 'frames_changed' });
  // Same manifest on resume; changed bytes are caught.
  assert.deepEqual((await packageFrames({ directory: job, source })).frames, frames.frames);
  await writeFile(path.join(frames.directory, 'image_000003.jpg'), 'changed');
  await assert.rejects(packageFrames({ directory: job, source }), { code: 'frames_changed' });

  // The existing prior builder works on pack frames: one row per image, poses from the verified table.
  const priors = await arkitPosePriors(source, frames);
  assert.deepEqual(priors.map(p => p.sourceFrameIndex), chosen.map(r => r.index));
  assert.deepEqual(priors[3].position, [chosen[3].cameraToWorldARKit[0][3], 1.4, 0]);
  assert.equal(posePriorCSV(priors).trim().split('\n').length, 11);
});

test('a pack bound to a task cannot be swapped underneath it', async t => {
  const directory = await workspace(t);
  const stored = path.join(directory, 'keyframes'); await mkdir(stored);
  const packFile = path.join(directory, 'pack.bin'); await writeFile(packFile, buildPack(id, chosen));
  const summary = await extractKeyframePack(packFile, stored, { captureId: id, framesJSONL: framesJSONL(records) });
  await writeFile(path.join(stored, 'images', 'image_000001.jpg'), 'replaced');
  const envelope = Buffer.from(JSON.stringify({ manifest: {}, framesJSONL: framesJSONL(records) }));
  const metadata = path.join(directory, 'metadata.json'); await writeFile(metadata, envelope);
  await assert.rejects(packageFrames({ directory: path.join(directory, 'job'), source: { sourceKind: 'native_arkit_capture',
    captureId: id, captureReceiptId: randomUUID(), sourceVideoSha256: 'a'.repeat(64), sourceByteSize: 1, sourceMetadataPath: metadata,
    sourceMetadataSha256: sha(envelope), sourceMetadataByteSize: envelope.length, keyframes: { ...summary, directory: stored } } }),
  { code: 'source_changed' });
});

test('the worker trains the ARKit branch from the bound pack, with its masks and prior, never from video frames', async t => {
  const directory = await workspace(t);
  const packFile = path.join(directory, 'pack.bin'), stored = path.join(directory, 'keyframes');
  await writeFile(packFile, buildPack(id, chosen, { masks: true }));
  const summary = await extractKeyframePack(packFile, stored, { captureId: id, framesJSONL: framesJSONL(records) });
  const envelope = Buffer.from(JSON.stringify({ manifest: {}, framesJSONL: framesJSONL(records) }));
  const metadata = path.join(directory, 'metadata.json'); await writeFile(metadata, envelope);
  const videoBytes = Buffer.from('SYNTHETIC CONTAINER; NOT A CAMERA VIDEO'), videoFile = path.join(directory, 'video.mov');
  await writeFile(videoFile, videoBytes);
  const job = { id: randomUUID(), reconstructionId: randomUUID(), algorithm: 'gs_mcmc_arkit_prior', role: 'arkit', status: 'queued' };
  const claimId = randomUUID(), phases = [];
  const repository = {
    pendingJobs: () => [job],
    claim: () => ({ ...job, status: 'processing', claimId }),
    source: () => ({ jobId: job.id, reconstructionId: job.reconstructionId, algorithm: job.algorithm, role: job.role,
      sourceVideoPath: videoFile, sourceVideoSha256: sha(videoBytes), sourceByteSize: videoBytes.length,
      sourceKind: 'native_arkit_capture', captureId: id, captureReceiptId: '11111111-1111-4111-8111-111111111111',
      sourceMetadataPath: metadata, sourceMetadataSha256: sha(envelope), sourceMetadataByteSize: envelope.length,
      keyframes: { ...summary, directory: stored } }),
    setPhase: (jobId, claim, status, phase, error) => phases.push({ status, phase, error }),
    publish: () => assert.fail('nothing is ready yet'),
  };
  let seen;
  const config = { dataDir: path.join(directory, 'data'), workDir: path.join(directory, 'work'), hubOrigin: 'http://127.0.0.1:1',
    successStatus: 'SUCCESS', plyProfile: 'worldmirror2-probability-v1' };
  const result = await runDualWorkerOnce(config, { repository, client: {}, materialize: () => assert.fail('not ready'),
    extractFrames: () => assert.fail('the keyframe branch must not cut video frames'),
    providerStep: async args => { seen = args; return { status: 'processing', phase: 'fixture_provider' }; } });
  assert.equal(result.jobs[0].status, 'processing', JSON.stringify(result));
  assert.equal(seen.algorithm, 'gs_mcmc_arkit_prior');
  assert.deepEqual((await readdir(seen.framesDirectory)).length, 10);
  assert.deepEqual(await readdir(seen.masksDirectory), chosen.map((_, i) => `image_${pad(i + 1)}.png`));
  assert.equal(seen.posePriorCSV.trim().split('\n').length, 11);
  const binding = JSON.parse(await readFile(path.join(config.workDir, job.id, 'source-binding.json'), 'utf8'));
  assert.equal(binding.keyframesSha256, summary.sha256);
  assert.deepEqual(phases.map(p => p.status), ['processing', 'processing']);
});
