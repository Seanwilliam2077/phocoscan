import { createHash } from 'node:crypto';
import { APIError, dateString, nonempty, requireThat, uuid } from './validation.mjs';

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const digest = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const count = (value, max) => Number.isInteger(value) && value >= 0 && value <= max;
const positiveSize = value => Number.isInteger(value) && value > 0 && value <= 8192;
const finite = value => typeof value === 'number' && Number.isFinite(value);
const matrix = (value, rows, columns) => Array.isArray(value) && value.length === rows &&
  value.every(row => Array.isArray(row) && row.length === columns && row.every(finite));

// The metadata upload is a JSON envelope of the device's original manifest and
// the exact UTF-8 contents of frames.jsonl. Keeping the raw JSONL string lets us
// verify manifest.framesSHA256 without silently changing its serialization.
export function validateCaptureMetadata(envelope, captureId, rgbHash) {
  requireThat(envelope && typeof envelope === 'object' && !Array.isArray(envelope), 422, 'invalid_metadata', 'Metadata must be a JSON object.');
  const { manifest, framesJSONL } = envelope;
  requireThat(manifest && typeof manifest === 'object' && !Array.isArray(manifest) && typeof framesJSONL === 'string', 422, 'invalid_metadata', 'Provide manifest and exact framesJSONL text.');
  requireThat(manifest.schemaVersion === 1 && manifest.captureID === captureId && uuid(manifest.captureID), 422, 'invalid_manifest', 'Manifest version or capture ID does not match.');
  requireThat(manifest.videoFile === 'video.mov' || manifest.videoFile === 'video.mp4', 422, 'invalid_manifest', 'Manifest must name the recorded video.');
  requireThat(manifest.framesFile === 'frames.jsonl' && digest(manifest.videoSHA256) && digest(manifest.framesSHA256), 422, 'invalid_manifest', 'Manifest file names and hashes are required.');
  requireThat(manifest.videoSHA256 === rgbHash, 422, 'video_hash_mismatch', 'Manifest video hash does not match the uploaded original.');
  requireThat(sha256(Buffer.from(framesJSONL, 'utf8')) === manifest.framesSHA256, 422, 'frames_hash_mismatch', 'Frame table hash does not match its manifest.');
  requireThat(count(manifest.frameCount, 10000) && manifest.frameCount > 0 && count(manifest.skippedFrameCount, 10000) && count(manifest.depthFrameCount, manifest.frameCount), 422, 'invalid_manifest', 'Manifest frame counts are invalid.');
  requireThat(positiveSize(manifest.rgbWidth) && positiveSize(manifest.rgbHeight) && typeof manifest.depthSupported === 'boolean', 422, 'invalid_manifest', 'Manifest dimensions or depth capability are invalid.');
  requireThat(dateString(manifest.createdAtUTC) && dateString(manifest.completedAtUTC) && Date.parse(manifest.completedAtUTC) >= Date.parse(manifest.createdAtUTC), 422, 'invalid_manifest', 'Manifest capture times are invalid.');
  requireThat(nonempty(manifest.coordinateConvention, 500) && nonempty(manifest.videoOrientation, 250) && nonempty(manifest.audioPolicy, 100), 422, 'invalid_manifest', 'Manifest coordinate, orientation and audio declarations are required.');
  requireThat(framesJSONL.length <= 12 * 1024 * 1024, 413, 'metadata_too_large', 'Frame table exceeds the supported size.');
  const lines = framesJSONL.split('\n');
  if (lines.at(-1) === '') lines.pop();
  requireThat(lines.length === manifest.frameCount, 422, 'frame_count_mismatch', 'Frame table and manifest counts differ.');
  let lastTimestamp = -Infinity, lastPTS = -Infinity, depthCount = 0;
  for (let index = 0; index < lines.length; index++) {
    requireThat(lines[index].length > 0 && lines[index].length <= 16384, 422, 'invalid_frame', 'Frame record is empty or too large.');
    let frame;
    try { frame = JSON.parse(lines[index]); }
    catch { throw new APIError(422, 'invalid_frame', `Frame ${index} is not valid JSON.`); }
    requireThat(frame && typeof frame === 'object' && !Array.isArray(frame) && frame.index === index, 422, 'invalid_frame', 'Frame indices must be contiguous.');
    requireThat(finite(frame.arTimestampSeconds) && frame.arTimestampSeconds > lastTimestamp && finite(frame.videoPTSSeconds) && frame.videoPTSSeconds >= 0 && frame.videoPTSSeconds > lastPTS, 422, 'invalid_frame_time', 'Frame times must increase strictly.');
    requireThat(frame.rgbWidth === manifest.rgbWidth && frame.rgbHeight === manifest.rgbHeight && positiveSize(frame.cameraImageWidth) && positiveSize(frame.cameraImageHeight), 422, 'invalid_frame', 'Frame dimensions do not match the manifest.');
    requireThat(matrix(frame.cameraToWorldARKit, 4, 4) && matrix(frame.intrinsicsPixels, 3, 3) && frame.intrinsicsPixels[0][0] > 0 && frame.intrinsicsPixels[1][1] > 0, 422, 'invalid_camera', 'Each frame needs finite ARKit pose and intrinsics.');
    requireThat(nonempty(frame.trackingState, 200), 422, 'invalid_camera', 'Each frame needs a tracking state.');
    const hasDepth = frame.depth != null, hasConfidence = frame.confidence != null;
    requireThat(!hasConfidence || hasDepth, 422, 'invalid_depth_metadata', 'Confidence cannot be present without a depth frame.');
    if (hasDepth) {
      depthCount++;
      for (const item of [frame.depth, ...(hasConfidence ? [frame.confidence] : [])]) {
        requireThat(item && typeof item === 'object' && /^[a-z]+\/frame-\d{6}\.[a-z0-9]+$/.test(item.file) && positiveSize(item.width) && positiveSize(item.height) && digest(item.sha256) && nonempty(item.pixelFormat, 100), 422, 'invalid_depth_metadata', 'Depth references need safe paths, dimensions and hashes.');
      }
    }
    lastTimestamp = frame.arTimestampSeconds;
    lastPTS = frame.videoPTSSeconds;
  }
  requireThat(depthCount === manifest.depthFrameCount && (!depthCount || manifest.depthSupported), 422, 'depth_count_mismatch', 'Depth references and manifest counts differ.');
  return { frameCount: lines.length, skippedFrameCount: manifest.skippedFrameCount,
    depthFrameCount: depthCount, depthStatus: depthCount ? 'pending_upload' : 'not_captured',
    timestampSpanSeconds: lastPTS, poseSource: 'arkit_device_reported',
    validationLevel: 'rgb_container_and_metadata_integrity', decodeVerified: false };
}
