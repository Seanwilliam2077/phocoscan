import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { APIError, requireThat } from './validation.mjs';

/**
 * Keyframe pack: the phone's own training keyframes for one native capture, used by the ARKit
 * pose cloud branch instead of frames cut from the compressed video. Layout (all little-endian):
 *
 *   "PWPACK01" | uint32 index length | index JSON | file bytes, in index order
 *
 * index: { version: 1, captureId, files: [{ path, byteSize, sha256 }] }
 * files: transforms.json (nerfstudio subset), meta.json (optional), images/image_NNNNNN.jpg,
 *        masks/image_NNNNNN.png (person scans; either every image has one or none does).
 *
 * Every keyframe must be a frame the verified capture metadata already lists: same ARKit timestamp,
 * same camera-to-world pose and normal tracking. The pack adds pixels, never new poses.
 */
export const KEYFRAME_PACK_MIME = 'application/x-pocketworld-keyframes';
export const MAX_KEYFRAME_PACK = 160 * 1024 * 1024;
export const MAX_PACK_FRAMES = 64;
export const MIN_PACK_FRAMES = 8;
const MAGIC = Buffer.from('PWPACK01', 'ascii');
const SHA = /^[a-f0-9]{64}$/;
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = (code, message) => { throw new APIError(422, code, message); };
const finite = value => typeof value === 'number' && Number.isFinite(value);
const imageName = i => `image_${String(i).padStart(6, '0')}`;

function parseIndex(bytes, captureId) {
  requireThat(bytes.length > 12 && bytes.subarray(0, 8).equals(MAGIC), 422, 'invalid_keyframe_pack', 'Not a keyframe pack.');
  const indexLength = bytes.readUInt32LE(8);
  requireThat(indexLength > 0 && indexLength <= 1024 * 1024 && 12 + indexLength <= bytes.length, 422, 'invalid_keyframe_pack', 'Invalid pack index.');
  let index;
  try { index = JSON.parse(bytes.subarray(12, 12 + indexLength).toString('utf8')); }
  catch { fail('invalid_keyframe_pack', 'Pack index is not JSON.'); }
  requireThat(index?.version === 1 && index.captureId === captureId && Array.isArray(index.files) && index.files.length <= 2 * MAX_PACK_FRAMES + 2,
    422, 'invalid_keyframe_pack', 'Pack index belongs to another capture or version.');
  let offset = 12 + indexLength;
  const files = new Map();
  for (const entry of index.files) {
    requireThat(typeof entry?.path === 'string' && Number.isSafeInteger(entry.byteSize) && entry.byteSize > 0 && entry.byteSize <= 20 * 1024 * 1024
      && SHA.test(entry.sha256 ?? ''), 422, 'invalid_keyframe_pack', 'Invalid pack entry.');
    requireThat(/^(transforms\.json|meta\.json|images\/image_\d{6}\.jpg|masks\/image_\d{6}\.png)$/.test(entry.path) && !files.has(entry.path),
      422, 'invalid_keyframe_pack', 'Unexpected or repeated file in the pack.');
    requireThat(offset + entry.byteSize <= bytes.length, 422, 'invalid_keyframe_pack', 'Pack is shorter than its index.');
    const content = bytes.subarray(offset, offset + entry.byteSize);
    requireThat(sha(content) === entry.sha256, 422, 'keyframe_hash_mismatch', 'A pack file does not match its SHA-256.');
    files.set(entry.path, content); offset += entry.byteSize;
  }
  requireThat(offset === bytes.length, 422, 'invalid_keyframe_pack', 'Pack has bytes beyond its index.');
  return files;
}

/** ARKit records of the verified capture, found by ARKit timestamp (within a microsecond;
 * frames are ≥ 16 ms apart, and JSON writers may round the last digit differently). */
function recordsByTimestamp(framesJSONL) {
  requireThat(typeof framesJSONL === 'string', 409, 'metadata_missing', 'Verified capture metadata is unavailable.');
  const records = [];
  for (const line of framesJSONL.split('\n')) {
    if (!line) continue;
    const record = JSON.parse(line);
    if (finite(record.arTimestampSeconds)) records.push(record);
  }
  records.sort((a, b) => a.arTimestampSeconds - b.arTimestampSeconds);
  return { get(time) {
    let low = 0, high = records.length - 1;
    while (low <= high) {
      const middle = (low + high) >> 1, value = records[middle].arTimestampSeconds;
      if (Math.abs(value - time) <= 1e-6) return records[middle];
      if (value < time) low = middle + 1; else high = middle - 1;
    }
    return undefined;
  } };
}

function matrix(value) {
  return Array.isArray(value) && value.length === 4 && value.every(row => Array.isArray(row) && row.length === 4 && row.every(finite))
    && Math.abs(value[3][0]) < 1e-6 && Math.abs(value[3][1]) < 1e-6 && Math.abs(value[3][2]) < 1e-6 && Math.abs(value[3][3] - 1) < 1e-6;
}

/** Verifies a pack against the capture's verified metadata and returns its summary (no I/O). */
export function inspectKeyframePack(bytes, { captureId, framesJSONL }) {
  requireThat(Buffer.isBuffer(bytes) && bytes.length <= MAX_KEYFRAME_PACK, 413, 'file_too_large', 'Keyframe pack exceeds the allowed size.');
  const files = parseIndex(bytes, captureId);
  let transforms;
  try { transforms = JSON.parse(files.get('transforms.json')?.toString('utf8') ?? ''); }
  catch { fail('invalid_keyframe_pack', 'transforms.json is missing or not JSON.'); }
  const frames = transforms?.frames;
  requireThat(Array.isArray(frames) && frames.length >= MIN_PACK_FRAMES && frames.length <= MAX_PACK_FRAMES, 422, 'invalid_keyframe_pack',
    `A pack holds ${MIN_PACK_FRAMES}–${MAX_PACK_FRAMES} keyframes.`);
  const imageCount = [...files.keys()].filter(name => name.startsWith('images/')).length;
  const maskCount = [...files.keys()].filter(name => name.startsWith('masks/')).length;
  requireThat(imageCount === frames.length && (maskCount === 0 || maskCount === frames.length), 422, 'invalid_keyframe_pack',
    'Every keyframe needs one image, and masks must cover all keyframes or none.');
  const records = recordsByTimestamp(framesJSONL);
  const summary = [];
  let previousTime = -Infinity;
  frames.forEach((frame, i) => {
    const name = imageName(i + 1), image = files.get(`images/${name}.jpg`);
    requireThat(frame?.file_path === `images/${name}.jpg` && image, 422, 'invalid_keyframe_pack', 'Keyframes must be numbered images in order.');
    requireThat(image.length >= 4 && image[0] === 0xff && image[1] === 0xd8 && image[image.length - 2] === 0xff && image[image.length - 1] === 0xd9,
      422, 'invalid_keyframe_pack', 'Keyframe images must be JPEG.');
    const mask = maskCount ? files.get(`masks/${name}.png`) : null;
    if (maskCount) {
      requireThat(frame.mask_path === `masks/${name}.png` && mask && mask.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
        422, 'invalid_keyframe_pack', 'Masks must be PNG files named after their keyframe.');
    }
    requireThat(finite(frame.timestamp) && frame.timestamp > previousTime && matrix(frame.transform_matrix)
      && [frame.fl_x, frame.fl_y, frame.cx, frame.cy].every(v => finite(v) && v > 0) && Number.isInteger(frame.w) && Number.isInteger(frame.h)
      && frame.w > 0 && frame.h > 0, 422, 'invalid_keyframe_pack', 'Keyframe camera data is incomplete.');
    previousTime = frame.timestamp;
    const record = records.get(frame.timestamp);
    requireThat(record && record.trackingState === 'normal' && matrix(record.cameraToWorldARKit) && finite(record.videoPTSSeconds),
      422, 'keyframe_not_in_capture', 'A keyframe is not a normally tracked frame of this capture.');
    const drift = Math.max(...record.cameraToWorldARKit.flatMap((row, r) => row.map((v, c) => Math.abs(v - frame.transform_matrix[r][c]))));
    requireThat(drift < 1e-3, 422, 'keyframe_not_in_capture', 'A keyframe pose differs from the verified capture.');
    summary.push({ file: `${name}.jpg`, sha256: sha(image), byteSize: image.length, ...(mask ? { mask: `${name}.png`, maskSha256: sha(mask) } : {}),
      arTimestampSeconds: frame.timestamp, videoPTSSeconds: record.videoPTSSeconds, sourceFrameIndex: record.index,
      cameraToWorldARKit: record.cameraToWorldARKit, width: frame.w, height: frame.h, subjectMoving: frame.subject_moving === true });
  });
  let mode = null;
  if (files.has('meta.json')) {
    try { mode = JSON.parse(files.get('meta.json').toString('utf8'))?.mode ?? null; } catch { fail('invalid_keyframe_pack', 'meta.json is not JSON.'); }
    requireThat(mode === null || ['object', 'room', 'person'].includes(mode), 422, 'invalid_keyframe_pack', 'Unknown capture mode.');
  }
  return { files, summary: { version: 1, sha256: sha(bytes), byteSize: bytes.length, frameCount: frames.length,
    masks: maskCount > 0, mode, frames: summary } };
}

/** Verifies a pack file and extracts it into `destination` (created atomically). */
export async function extractKeyframePack(packFile, destination, { captureId, framesJSONL }) {
  const { files, summary } = inspectKeyframePack(await readFile(packFile), { captureId, framesJSONL });
  const staging = destination + '.' + randomUUID() + '.tmp';
  try {
    await mkdir(path.join(staging, 'images'), { recursive: true });
    if (summary.masks) await mkdir(path.join(staging, 'masks'), { recursive: true });
    for (const [name, content] of files) await writeFile(path.join(staging, name), content, { mode: 0o600, flag: 'wx' });
    await writeFile(path.join(staging, 'pack.json'), JSON.stringify(summary, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
    await rm(destination, { recursive: true, force: true });
    await rename(staging, destination);
  } finally { await rm(staging, { recursive: true, force: true }); }
  return summary;
}

/** The public part of a pack summary (capture status, task inputs). */
export const packPublic = summary => summary ? { sha256: summary.sha256, byteSize: summary.byteSize, frameCount: summary.frameCount,
  masks: summary.masks, mode: summary.mode } : null;

export function assertPackSummary(summary) {
  if (!(summary?.version === 1 && SHA.test(summary.sha256 ?? '') && Array.isArray(summary.frames))) {
    throw new APIError(409, 'keyframes_changed', 'Stored keyframe pack summary is invalid.');
  }
  return summary;
}
