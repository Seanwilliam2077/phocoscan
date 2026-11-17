import { createReadStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { validateGaussian, requireThat } from './validation.mjs';

export const VIEWER_VERSION = 'splat-sh0-v2';
export const VIEWER_BUDGETS = [10000, 30000, 60000, 100000];
const SH_C0 = 0.28209479177387814;
const byte = value => Math.round(Math.max(0, Math.min(255, value)));

// A renderer derivative only: SH0 color, 8-bit opacity/quaternion, optional
// uniform deterministic subsampling. It adds no geometry/calibration evidence.
export async function makeViewerDerivative(sourcePath, asset, maxPoints = 60000) {
  const plyProfile = asset.plyProfile ?? 'gaussian-ply-logit-v1';
  requireThat(['gaussian-ply-logit-v1', 'worldmirror2-probability-v1'].includes(plyProfile), 422, 'unsupported_ply_profile', 'Unknown source PLY profile.');
  requireThat(plyProfile !== 'worldmirror2-probability-v1' || asset.reconstructionTool === 'WorldMirror2', 422, 'invalid_ply_profile', 'Probability opacity requires an explicitly identified WorldMirror2 exporter.');
  requireThat(VIEWER_BUDGETS.includes(maxPoints), 400, 'invalid_point_budget', 'maxPoints must be 10000, 30000, 60000 or 100000.');
  const sourceHash = createHash('sha256');
  for await (const chunk of createReadStream(sourcePath)) sourceHash.update(chunk);
  requireThat(sourceHash.digest('hex') === asset.sha256, 409, 'source_hash_mismatch', 'The stored source hash no longer matches its imported asset.');
  let output, originalPointCount, pointCount, properties, written = 0;
  await validateGaussian(sourcePath, asset.format, {
    onHeader(header) {
      originalPointCount = header.gaussianCount;
      pointCount = Math.min(originalPointCount, maxPoints);
      output = Buffer.alloc(pointCount * 32);
      if (header.properties) properties = new Map(header.properties.map((property, index) => [property.name, index]));
    },
    onRecord(record, index) {
      if (asset.format === 'ply' && plyProfile === 'worldmirror2-probability-v1') {
        const opacity = record[properties.get('opacity')];
        requireThat(opacity >= 0 && opacity <= 1, 422, 'invalid_probability_opacity', 'WorldMirror probability opacity must be in [0, 1].');
      }
      if (written >= pointCount || index !== Math.floor(written * originalPointCount / pointCount)) return;
      const offset = written++ * 32;
      if (asset.format === 'splat') { record.copy(output, offset); return; }
      const get = name => record[properties.get(name)];
      ['x', 'y', 'z'].forEach((name, i) => output.writeFloatLE(get(name), offset + i * 4));
      for (let i = 0; i < 3; i++) {
        output.writeFloatLE(Math.exp(get(`scale_${i}`)), offset + 12 + i * 4);
        output[offset + 24 + i] = byte((0.5 + SH_C0 * get(`f_dc_${i}`)) * 255);
      }
      output[offset + 27] = byte(255 * (plyProfile === 'worldmirror2-probability-v1' ? get('opacity') : 1 / (1 + Math.exp(-get('opacity')))));
      const quaternion = [0, 1, 2, 3].map(i => get(`rot_${i}`));
      const norm = Math.hypot(...quaternion);
      quaternion.forEach((value, i) => { output[offset + 28 + i] = byte(128 + 128 * value / norm); });
    },
  });
  requireThat(written === pointCount, 422, 'invalid_derivative', 'Source did not produce the declared Gaussian record count.');
  const info = {
    format: 'splat', derivativeVersion: VIEWER_VERSION, recordBytes: 32,
    sourceAssetId: asset.id, sourceFormat: asset.format, sourceSha256: asset.sha256,
    sourcePlyProfile: asset.format === 'ply' ? plyProfile : null,
    pointCount, originalPointCount, maxPoints, decimated: pointCount < originalPointCount,
    lossy: true, rendererOnly: true, byteSize: output.length,
    sha256: createHash('sha256').update(output).digest('hex'),
    sampling: 'uniform_source_order_floor', colorModel: 'SH0',
    quaternionOrder: 'wxyz', quaternionEncoding: '(byte-128)/128 then normalize',
    limitations: ['Display derivative only; original source is retained.', 'Higher-order view-dependent color is omitted; quantization and decimation may lose detail.', 'No inferred camera poses, metric scale, collision geometry, lineage or training acceptance.'],
  };
  return { bytes: output, info };
}
