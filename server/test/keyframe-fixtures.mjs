import { createHash } from 'node:crypto';

// SYNTHETIC keyframe packs: tiny JPEG/PNG-shaped byte strings, not camera images.
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
export const pad = i => String(i).padStart(6, '0');
export const fakeJPEG = label => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from(`SYNTHETIC ${label}`), Buffer.from([0xff, 0xd9])]);
export const fakePNG = label => Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from(`SYNTHETIC ${label}`)]);

/** ARKit frame records like frames.jsonl: walking along +x at 30 fps, all normally tracked. */
export function arkitFrames(count, { tracking = () => 'normal' } = {}) {
  return Array.from({ length: count }, (_, index) => ({
    index, arTimestampSeconds: 100 + index / 30, videoPTSSeconds: index / 30, rgbWidth: 1920, rgbHeight: 1080,
    cameraImageWidth: 1920, cameraImageHeight: 1080,
    cameraToWorldARKit: [[1, 0, 0, index * 0.05], [0, 1, 0, 1.4], [0, 0, 1, 0], [0, 0, 0, 1]],
    intrinsicsPixels: [[1000, 0, 960], [0, 1000, 540], [0, 0, 1]], trackingState: tracking(index), depth: null, confidence: null,
  }));
}

/** A keyframe pack for `records` (each becomes one keyframe), as the phone writes it. */
export function buildPack(captureId, records, { masks = false, mode = masks ? 'person' : 'object', edit = transforms => transforms,
  extraFiles = [], tamper } = {}) {
  const frames = records.map((record, i) => ({
    file_path: `images/image_${pad(i + 1)}.jpg`, ...(masks ? { mask_path: `masks/image_${pad(i + 1)}.png` } : {}),
    transform_matrix: record.cameraToWorldARKit.map(row => [...row]), fl_x: 1000, fl_y: 1000, cx: 960, cy: 540, w: 1920, h: 1080,
    timestamp: record.arTimestampSeconds,
  }));
  const transforms = edit({ camera_model: 'OPENCV', fl_x: 1000, fl_y: 1000, cx: 960, cy: 540, w: 1920, h: 1080, frames });
  const files = [['transforms.json', Buffer.from(JSON.stringify(transforms))], ['meta.json', Buffer.from(JSON.stringify({ mode }))]];
  records.forEach((_, i) => {
    files.push([`images/image_${pad(i + 1)}.jpg`, fakeJPEG(`frame ${i + 1}`)]);
    if (masks) files.push([`masks/image_${pad(i + 1)}.png`, fakePNG(`mask ${i + 1}`)]);
  });
  files.push(...extraFiles);
  const index = Buffer.from(JSON.stringify({ version: 1, captureId,
    files: files.map(([path, bytes]) => ({ path, byteSize: bytes.length, sha256: sha(bytes) })) }));
  const length = Buffer.alloc(4); length.writeUInt32LE(index.length);
  let bytes = Buffer.concat([Buffer.from('PWPACK01'), length, index, ...files.map(([, b]) => b)]);
  if (tamper) bytes = tamper(bytes);
  return bytes;
}

export const framesJSONL = records => records.map(r => JSON.stringify(r)).join('\n') + '\n';
