import Busboy from 'busboy';
import { createWriteStream } from 'node:fs';
import { rm } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { APIError, requireThat } from './validation.mjs';

// wx.uploadFile sends multipart; existing clients continue to send raw PUT.
// Both paths stream to disk and hash only file bytes, never MIME boundaries.
export async function receiveUpload(req, tmpRoot, limit) {
  const multipart = req.method === 'POST';
  const contentType = req.headers['content-type'] ?? '';
  if (multipart) requireThat(/^multipart\/form-data\s*;/i.test(contentType), 415, 'content_type', 'POST uploads require multipart/form-data with one file field named file.');
  const declaredLength = Number(req.headers['content-length']);
  requireThat(!Number.isFinite(declaredLength) || declaredLength <= limit + (multipart ? 65536 : 0), 413, 'file_too_large', 'Uploaded file exceeds the allowed limit.');
  const temporary = path.join(tmpRoot, randomUUID());
  const hash = createHash('sha256');
  let size = 0, mime = contentType.split(';')[0].toLowerCase(), filename = '';
  const counter = new Transform({ transform(chunk, encoding, callback) {
    size += chunk.length;
    // Drain a multipart file after its limit so Busboy can finish parsing and
    // the caller receives a JSON 413 rather than a reset socket or hung parser.
    if (size > limit && multipart) callback();
    else if (size > limit) callback(new APIError(413, 'file_too_large', 'Uploaded file exceeds the allowed limit.'));
    else { hash.update(chunk); callback(null, chunk); }
  } });
  try {
    if (!multipart) await pipeline(req, counter, createWriteStream(temporary, { flags: 'wx' }));
    else {
      let parser;
      try { parser = Busboy({ headers: req.headers, limits: { fileSize: limit + 1, files: 1, fields: 0, parts: 2, headerPairs: 64 } }); }
      catch { throw new APIError(400, 'invalid_multipart', 'Missing or invalid multipart boundary.'); }
      let failure, fileTask, fileStream, wireSize = 0;
      const fail = error => { failure ??= error instanceof APIError ? error : new APIError(400, 'invalid_multipart', 'Malformed or incomplete multipart upload.'); };
      const tooMany = () => fail(new APIError(400, 'invalid_multipart', 'Send exactly one file field named file and no other form fields.'));
      parser.on('file', (name, stream, info) => {
        if (name !== 'file' || fileTask) { tooMany(); stream.resume(); return; }
        mime = info.mimeType.toLowerCase(); filename = info.filename ?? '';
        fileStream = stream;
        stream.on('limit', () => fail(new APIError(413, 'file_too_large', 'Uploaded file exceeds the allowed limit.')));
        fileTask = pipeline(stream, counter, createWriteStream(temporary, { flags: 'wx' })).catch(fail);
      });
      parser.on('filesLimit', tooMany);
      parser.on('fieldsLimit', tooMany);
      parser.on('partsLimit', tooMany);
      // Busboy emits partsLimit after the first permitted part. Limit to two
      // and reject the second explicitly, avoiding rejecting every valid file.
      parser.on('field', tooMany);
      await new Promise(resolve => {
        let finished = false;
        const finish = () => {
          if (finished) return;
          finished = true;
          req.off('data', countWire); req.off('aborted', aborted); req.off('error', broken);
          resolve();
        };
        const broken = error => { fail(error); fileStream?.destroy(error); req.unpipe(parser); req.resume(); finish(); };
        const aborted = () => broken(new APIError(400, 'invalid_multipart', 'Upload was interrupted.'));
        const countWire = chunk => {
          wireSize += chunk.length;
          if (wireSize > limit + 65536) {
            const error = new APIError(413, 'file_too_large', 'Multipart request exceeds the allowed size.');
            fail(error); parser.destroy(error);
          }
        };
        parser.once('error', broken);
        parser.once('close', finish);
        req.once('error', broken); req.once('aborted', aborted); req.on('data', countWire);
        req.pipe(parser);
      });
      await fileTask;
      if (failure) throw failure;
      requireThat(fileTask, 400, 'invalid_multipart', 'A file field named file is required.');
      requireThat(size <= limit, 413, 'file_too_large', 'Uploaded file exceeds the allowed limit.');
    }
    requireThat(size > 0, 422, 'empty_file', 'Uploaded file is empty.');
    return { temporary, size, hash: hash.digest('hex'), mime, filename };
  } catch (error) { await rm(temporary, { force: true }); throw error; }
}

export function uploadMime(file) {
  if (file.mime !== 'application/octet-stream') return file.mime;
  const ext = path.extname(file.filename).toLowerCase();
  return ({ '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg' })[ext] ?? file.mime;
}
