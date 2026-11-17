import { open } from 'node:fs/promises';

export class APIError extends Error {
  constructor(status, code, message) { super(message); Object.assign(this, { status, code }); }
}
export const requireThat = (condition, status, code, message) => {
  if (!condition) throw new APIError(status, code, message);
};
export const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export const nonempty = (value, max = 200) => typeof value === 'string' && value.trim().length > 0 && value.length <= max;
export const dateString = value => typeof value === 'string' && value.length <= 40 && Number.isFinite(Date.parse(value));

const scalarTypes = {
  char: ['readInt8', 1], int8: ['readInt8', 1], uchar: ['readUInt8', 1], uint8: ['readUInt8', 1],
  short: ['readInt16LE', 2], int16: ['readInt16LE', 2], ushort: ['readUInt16LE', 2], uint16: ['readUInt16LE', 2],
  int: ['readInt32LE', 4], int32: ['readInt32LE', 4], uint: ['readUInt32LE', 4], uint32: ['readUInt32LE', 4],
  float: ['readFloatLE', 4], float32: ['readFloatLE', 4], double: ['readDoubleLE', 8], float64: ['readDoubleLE', 8],
};
const requiredGaussian = ['x', 'y', 'z', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3'];

// Read every declared Gaussian record, not only a file extension or PLY magic.
// This proves basic structure/readability, never reconstruction quality.
export async function validateGaussian(path, format, { onHeader, onRecord } = {}) {
  requireThat(['ply', 'splat'].includes(format), 415, 'unsupported_model', 'Only Gaussian .ply and .splat are supported in this MVP.');
  const file = await open(path, 'r');
  try {
    const { size } = await file.stat();
    if (format === 'splat') {
      requireThat(size > 0 && size % 32 === 0, 422, 'invalid_splat', 'A .splat file must contain complete 32-byte Gaussian records.');
      requireThat(size / 32 <= 1_000_000, 413, 'too_many_gaussians', 'Use a smaller export (at most 1 million Gaussians for the phone viewer).');
      onHeader?.({ gaussianCount: size / 32, format });
      const chunk = Buffer.alloc(32 * 4096);
      for (let position = 0; position < size;) {
        const { bytesRead } = await file.read(chunk, 0, Math.min(chunk.length, size - position), position);
        requireThat(bytesRead > 0 && bytesRead % 32 === 0, 422, 'invalid_splat', 'Truncated Gaussian records.');
        for (let offset = 0; offset < bytesRead; offset += 32) {
          for (let j = 0; j < 6; j++) {
            const value = chunk.readFloatLE(offset + j * 4);
            requireThat(Number.isFinite(value) && (j < 3 || value >= 0), 422, 'invalid_splat', 'Gaussian coordinates/scales must be finite and scales nonnegative.');
          }
          requireThat([28, 29, 30, 31].some(j => chunk[offset + j] !== 128), 422, 'invalid_splat', 'Gaussian quaternion cannot be zero.');
          onRecord?.(chunk.subarray(offset, offset + 32), (position + offset) / 32);
        }
        position += bytesRead;
      }
      return { gaussianCount: size / 32, format };
    }
    const head = Buffer.alloc(Math.min(size, 65536));
    await file.read(head, 0, head.length, 0);
    const terminator = /(?:^|\n)end_header\r?\n/.exec(head.toString('ascii'));
    requireThat(terminator && head.subarray(0, 4).toString('ascii').startsWith('ply\n') || terminator && head.subarray(0, 5).toString('ascii') === 'ply\r\n', 422, 'invalid_ply', 'Missing PLY header or header exceeds 64 KiB.');
    const bodyOffset = terminator.index + terminator[0].length;
    const lines = head.subarray(0, bodyOffset).toString('ascii').split(/\r?\n/);
    const encoding = lines.find(line => line.startsWith('format '))?.split(/\s+/)[1];
    requireThat(['ascii', 'binary_little_endian'].includes(encoding), 422, 'unsupported_ply_encoding', 'Export ASCII or binary little-endian Gaussian PLY.');
    let vertexCount = 0, inVertex = false;
    const properties = [];
    for (const line of lines) {
      const parts = line.trim().split(/\s+/);
      if (parts[0] === 'element') {
        requireThat(parts[1] === 'vertex' || parts[2] === '0', 422, 'unsupported_ply_elements', 'This importer accepts Gaussian vertex records, without mesh/other nonempty elements.');
        inVertex = parts[1] === 'vertex';
        if (inVertex) {
          requireThat(vertexCount === 0, 422, 'invalid_ply', 'Duplicate vertex element.');
          vertexCount = Number(parts[2]);
        }
      } else if (parts[0] === 'property' && inVertex) {
        requireThat(parts.length === 3 && scalarTypes[parts[1]], 422, 'unsupported_ply_property', 'Only scalar PLY vertex properties are supported.');
        requireThat(!properties.some(p => p.name === parts[2]), 422, 'invalid_ply', 'Duplicate PLY property.');
        properties.push({ type: parts[1], name: parts[2] });
      }
    }
    requireThat(Number.isInteger(vertexCount) && vertexCount > 0 && vertexCount <= 1_000_000, 422, 'invalid_ply_count', 'Export 1 to 1 million Gaussian vertices for the phone viewer.');
    requireThat(requiredGaussian.every(name => properties.some(p => p.name === name)), 422, 'not_gaussian_ply', 'This is not Gaussian PLY: position, color SH DC, opacity, scale and rotation properties are required.');
    requireThat(requiredGaussian.every(name => ['float', 'float32'].includes(properties.find(p => p.name === name).type)), 422, 'unsupported_ply_type', 'The native viewer requires float32 position/color/opacity/scale/rotation properties.');
    const higherSH = properties.filter(p => p.name.startsWith('f_rest_'));
    requireThat(higherSH.length === 0 || (higherSH.length === 45 && Array.from({ length: 45 }, (_, index) => `f_rest_${index}`).every(name => higherSH.some(p => p.name === name && ['float', 'float32'].includes(p.type)))), 422, 'unsupported_sh_degree', 'The current native viewer supports no higher SH coefficients or all 45 float32 SH3 coefficients; partial SH1/SH2 needs conversion.');
    requireThat(properties.length <= 256, 422, 'invalid_ply', 'Too many vertex properties.');
    onHeader?.({ gaussianCount: vertexCount, format, encoding, properties });
    const rotationIndices = ['rot_0', 'rot_1', 'rot_2', 'rot_3'].map(name => properties.findIndex(p => p.name === name));
    const scaleIndices = ['scale_0', 'scale_1', 'scale_2'].map(name => properties.findIndex(p => p.name === name));
    function validateRow(values) {
      requireThat(values.length === properties.length && values.every(Number.isFinite), 422, 'invalid_ply_record', 'Every Gaussian property must be present and finite.');
      requireThat(values.every((value, index) => !['float', 'float32'].includes(properties[index].type) || Math.abs(value) <= 3.4028234663852886e38), 422, 'invalid_ply_record', 'A property exceeds finite float32 range.');
      requireThat(rotationIndices.some(i => Math.abs(values[i]) > 1e-12), 422, 'invalid_ply_record', 'Gaussian quaternion cannot be zero.');
      requireThat(scaleIndices.every(i => values[i] <= 80), 422, 'invalid_ply_record', 'Log scale would overflow the native float32 renderer.');
    }
    if (encoding === 'binary_little_endian') {
      const stride = properties.reduce((total, p) => total + scalarTypes[p.type][1], 0);
      requireThat(size === bodyOffset + stride * vertexCount, 422, 'invalid_ply_length', 'Binary PLY byte length does not match its vertex count/properties.');
      const chunk = Buffer.alloc(stride * Math.min(vertexCount, 4096));
      for (let position = bodyOffset; position < size;) {
        const { bytesRead } = await file.read(chunk, 0, Math.min(chunk.length, size - position), position);
        requireThat(bytesRead > 0 && bytesRead % stride === 0, 422, 'invalid_ply_length', 'Truncated PLY vertex records.');
        for (let offset = 0; offset < bytesRead; offset += stride) {
          let cursor = offset;
          const values = properties.map(p => {
            const [method, width] = scalarTypes[p.type];
            const value = chunk[method](cursor); cursor += width; return value;
          });
          validateRow(values);
          onRecord?.(values, (position - bodyOffset + offset) / stride);
        }
        position += bytesRead;
      }
    } else {
      // Streaming UTF-8 lines bounds peak memory for large ASCII exports.
      const stream = file.createReadStream({ start: bodyOffset, autoClose: false, encoding: 'utf8' });
      let pending = '', rows = 0;
      for await (const chunk of stream) {
        pending += chunk;
        requireThat(pending.length <= 4 * 1024 * 1024, 422, 'invalid_ply_record', 'Unreasonably long ASCII PLY row.');
        let end;
        while ((end = pending.indexOf('\n')) >= 0) {
          const row = pending.slice(0, end).trim(); pending = pending.slice(end + 1);
          if (!row) continue;
          const values = row.split(/\s+/).map(Number);
          validateRow(values); onRecord?.(values, rows); rows++;
          requireThat(rows <= vertexCount, 422, 'invalid_ply_count', 'More rows than declared vertices.');
        }
      }
      if (pending.trim()) { const values = pending.trim().split(/\s+/).map(Number); validateRow(values); onRecord?.(values, rows); rows++; }
      requireThat(rows === vertexCount, 422, 'invalid_ply_count', 'ASCII PLY row count does not match header.');
    }
    return { gaussianCount: vertexCount, format, encoding };
  } finally { await file.close(); }
}

// Validate ISO BMFF/QuickTime box boundaries and essential media boxes.
// Decoding frames and checking scene coverage are separate operator/device QA.
export async function validateVideo(path) {
  const file = await open(path, 'r');
  try {
    const { size } = await file.stat();
    let cursor = 0, boxes = 0;
    const seen = new Set();
    while (cursor < size) {
      requireThat(size - cursor >= 8 && boxes++ < 20000, 422, 'invalid_video', 'Truncated or excessive QuickTime/MP4 boxes.');
      const header = Buffer.alloc(16);
      await file.read(header, 0, Math.min(16, size - cursor), cursor);
      let length = header.readUInt32BE(0), minHeader = 8;
      const type = header.subarray(4, 8).toString('ascii');
      if (length === 1) {
        requireThat(size - cursor >= 16, 422, 'invalid_video', 'Truncated extended box.');
        length = Number(header.readBigUInt64BE(8)); minHeader = 16;
      } else if (length === 0) length = size - cursor;
      requireThat(Number.isSafeInteger(length) && length >= minHeader && cursor + length <= size, 422, 'invalid_video', 'Invalid QuickTime/MP4 box length.');
      if (['ftyp', 'moov', 'mdat'].includes(type) && length > minHeader) seen.add(type);
      cursor += length;
    }
    requireThat(seen.has('moov') && seen.has('mdat'), 422, 'invalid_video', 'Video must have nonempty movie metadata and media data boxes.');
    return { containerCheck: 'box_structure_only', hasFtyp: seen.has('ftyp') };
  } finally { await file.close(); }
}

export async function validateJPEG(path) {
  const file = await open(path, 'r');
  try {
    const { size } = await file.stat();
    const start = Buffer.alloc(3), end = Buffer.alloc(2);
    await file.read(start, 0, 3, 0); await file.read(end, 0, 2, Math.max(0, size - 2));
    requireThat(size >= 4 && start[0] === 255 && start[1] === 216 && start[2] === 255 && end[0] === 255 && end[1] === 217, 422, 'invalid_preview', 'Preview must be JPEG.');
  } finally { await file.close(); }
}
