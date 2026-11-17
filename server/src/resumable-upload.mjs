import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, open, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { APIError, requireThat } from './validation.mjs';

const SHA = /^[0-9a-f]{64}$/;
const VIDEO_TYPES = new Set(['video/mp4', 'video/quicktime']);
export const OFFSET_CONTENT_TYPE = 'application/offset+octet-stream';

/**
 * Resumable single-file upload, in the spirit of tus: the client declares the file's
 * SHA-256, size and type, then appends bytes at the offset the server reports. Bytes received
 * before a dropped connection (or a request timeout) are kept, so the client continues from
 * there instead of starting over. Integrity is decided only by the SHA-256 of the complete file.
 *
 * One upload directory holds `session.json` and `data.part`; the offset is the data file's size.
 * A newer append for the same directory aborts an older, stalled one before writing.
 */
export function resumableUploads({ limit, types = VIDEO_TYPES }) {
  const active = new Map(); // directory → { req, done }
  const paths = directory => ({ session: path.join(directory, 'session.json'), data: path.join(directory, 'data.part') });

  async function readSession(directory) {
    try { return JSON.parse(await readFile(paths(directory).session, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  }
  async function offsetOf(directory) {
    try { return (await stat(paths(directory).data)).size; }
    catch (error) { if (error.code === 'ENOENT') return 0; throw error; }
  }
  async function describe(directory, session) {
    return { sha256: session.sha256, byteSize: session.byteSize, mime: session.mime,
      offset: await offsetOf(directory), complete: false };
  }
  async function preempt(directory) {
    const prior = active.get(directory);
    if (!prior) return;
    prior.req.destroy();
    await prior.done;
  }

  return {
    /** Starts an upload, or returns the existing one for the same file and its current offset. */
    async begin(directory, body) {
      requireThat(SHA.test(body?.sha256 ?? '') && Number.isSafeInteger(body.byteSize) && body.byteSize > 0
        && types.has(body.mime), 422, 'invalid_upload', `Provide the file SHA-256, byte size and type (${[...types].join(', ')}).`);
      requireThat(body.byteSize <= limit, 413, 'file_too_large', 'Uploaded file exceeds the allowed limit.');
      const existing = await readSession(directory);
      if (existing && existing.sha256 === body.sha256 && existing.byteSize === body.byteSize && existing.mime === body.mime) {
        return describe(directory, existing);
      }
      // A different file for the same capture replaces any earlier partial bytes.
      await preempt(directory);
      await rm(directory, { recursive: true, force: true });
      await mkdir(directory, { recursive: true });
      const session = { version: 1, sha256: body.sha256, byteSize: body.byteSize, mime: body.mime, createdAt: new Date().toISOString() };
      await writeFile(paths(directory).session, JSON.stringify(session), { mode: 0o600, flag: 'wx' });
      return describe(directory, session);
    },

    async status(directory) {
      const session = await readSession(directory);
      return session ? describe(directory, session) : null;
    },

    /** Appends the request body at `Upload-Offset`. A dropped connection keeps what arrived. */
    async append(directory, req) {
      const session = await readSession(directory);
      requireThat(session, 404, 'upload_not_found', 'Start the upload before sending bytes.');
      requireThat((req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() === OFFSET_CONTENT_TYPE,
        415, 'content_type', `Send upload bytes as ${OFFSET_CONTENT_TYPE}.`);
      await preempt(directory);
      const offset = await offsetOf(directory);
      const claimed = Number(req.headers['upload-offset']);
      requireThat(Number.isSafeInteger(claimed) && claimed === offset, 409, 'offset_mismatch',
        'The upload offset changed; ask for the current offset and continue from there.');
      const declared = req.headers['content-length'];
      requireThat(declared === undefined || (Number.isSafeInteger(Number(declared)) && Number(declared) <= session.byteSize - offset),
        413, 'file_too_large', 'The bytes exceed the declared file size.');

      let release;
      const done = new Promise(resolve => { release = resolve; });
      active.set(directory, { req, done });
      let written = 0, interrupted = false;
      const cap = new Transform({ transform(chunk, encoding, callback) {
        if (offset + written + chunk.length > session.byteSize) {
          callback(new APIError(413, 'file_too_large', 'The bytes exceed the declared file size.'));
          return;
        }
        written += chunk.length;
        callback(null, chunk);
      } });
      try {
        await pipeline(req, cap, createWriteStream(paths(directory).data, { flags: 'a', mode: 0o600 }));
      } catch (error) {
        if (error instanceof APIError) throw error;
        // Dropped connection, timeout or preemption: the bytes already written stay.
        interrupted = true;
      } finally {
        try {
          const handle = await open(paths(directory).data, 'a');
          try { await handle.sync(); } finally { await handle.close(); }
        } catch (error) { if (error.code !== 'ENOENT') throw error; }
        if (active.get(directory)?.req === req) active.delete(directory);
        release();
      }
      return { ...(await describe(directory, session)), interrupted };
    },

    /** Verifies the complete file. A wrong hash discards the upload so it restarts cleanly. */
    async finalize(directory) {
      const session = await readSession(directory);
      requireThat(session, 404, 'upload_not_found', 'No upload to finish.');
      const file = paths(directory).data;
      const size = await offsetOf(directory);
      requireThat(size === session.byteSize, 409, 'upload_incomplete', 'The upload is not complete yet.');
      const hash = createHash('sha256');
      for await (const chunk of createReadStream(file)) hash.update(chunk);
      const digest = hash.digest('hex');
      if (digest !== session.sha256) {
        await rm(directory, { recursive: true, force: true });
        throw new APIError(422, 'hash_mismatch', 'Uploaded bytes do not match the declared SHA-256; the upload was discarded.');
      }
      return { temporary: file, size, hash: digest, mime: session.mime };
    },

    async discard(directory) {
      await preempt(directory);
      await rm(directory, { recursive: true, force: true });
    },
  };
}
