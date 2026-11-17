#!/usr/bin/env node
// Prepare an externally recorded MOV/MP4 for an explicit WorldMirror T0 run.
// This tool never uploads, changes the original, or invents ARKit measurements.
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { access, mkdir, readFile, realpath, readdir, rename, stat, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const runFile = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const workRoot = path.join(root, 'work');
const maxBytes = 4 * 1024 ** 3;

const help = `Prepare external iPhone Camera video for a T0 RGB-only reconstruction test.

node server/tools/t0-video.mjs --video <original.mov|mp4> [--frames 8|16] [--out work/t0/<name>] [--ffmpeg <executable>] [--ffprobe <executable>]

Writes only under ignored work/. The original is read twice and never copied or changed.
The output frames/ directory may be passed explicitly to worldmirror.mjs upload.
Review the selected viewpoints before submitting them. No pose, intrinsics or
LiDAR depth are inferred from an ordinary Camera video.
`;

function parse(argv) {
  if (argv.length === 0 || argv.includes('--help')) return null;
  const allowed = new Set(['--video', '--frames', '--out', '--ffmpeg', '--ffprobe']);
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index], value = argv[index + 1];
    if (!allowed.has(key) || !value || value.startsWith('--') || Object.hasOwn(options, key)) {
      throw new Error('Each known option needs exactly one value. Use --help.');
    }
    options[key] = value;
  }
  if (!options['--video']) throw new Error('--video is required.');
  const frameCount = Number(options['--frames'] ?? 16);
  if (![8, 16].includes(frameCount)) throw new Error('--frames must be 8 or 16.');
  return { video: path.resolve(options['--video']), frameCount, out: options['--out'],
    ffmpeg: options['--ffmpeg'] ?? 'ffmpeg', ffprobe: options['--ffprobe'] ?? 'ffprobe' };
}

function within(parent, child) {
  const relative = path.relative(parent, child);
  return !!relative && relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
}

async function sha256(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

async function execute(program, args, maxBuffer = 64 * 1024 * 1024) {
  try { return await runFile(program, args, { windowsHide: true, maxBuffer }); }
  catch (error) {
    if (error.code === 'ENOENT') throw new Error(`${path.basename(program)} was not found. Pass --ffmpeg and --ffprobe with absolute executable paths.`);
    throw new Error(`${path.basename(program)} failed (${error.code ?? error.exitCode ?? 'unknown'}). ${String(error.stderr ?? '').slice(-600)}`);
  }
}

function chooseFrames(frames, wanted) {
  if (frames.length < wanted) throw new Error(`Video has only ${frames.length} timestamped frames; need ${wanted}.`);
  const start = frames[0].timestampSeconds, end = frames.at(-1).timestampSeconds;
  if (!(end > start)) throw new Error('Frame timestamps do not span a positive interval.');
  const selected = [];
  let lastIndex = -1;
  for (let index = 0; index < wanted; index++) {
    const target = start + (end - start) * (0.05 + 0.9 * index / Math.max(1, wanted - 1));
    const minimum = lastIndex + 1;
    const maximum = frames.length - (wanted - index);
    let best = minimum;
    for (let candidate = minimum + 1; candidate <= maximum; candidate++) {
      if (Math.abs(frames[candidate].timestampSeconds - target) < Math.abs(frames[best].timestampSeconds - target)) best = candidate;
      if (frames[candidate].timestampSeconds > target && candidate > best) break;
    }
    selected.push(frames[best]);
    lastIndex = best;
  }
  return selected;
}

async function inspectVideo(video, ffprobe) {
  const probe = await execute(ffprobe, ['-v', 'error', '-show_entries',
    'format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,duration,nb_frames:stream_tags=rotate:stream_side_data=rotation',
    '-of', 'json', video]);
  const info = JSON.parse(probe.stdout);
  const videoStream = info.streams?.find(stream => stream.codec_type === 'video');
  if (!videoStream || !Number.isInteger(videoStream.width) || !Number.isInteger(videoStream.height)) {
    throw new Error('No probeable video stream was found.');
  }
  const frameProbe = await execute(ffprobe, ['-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', video]);
  const rawFrames = JSON.parse(frameProbe.stdout).frames ?? [];
  const frames = rawFrames.map((frame, index) => ({
    sourceFrameIndex: index, timestampSeconds: Number(frame.best_effort_timestamp_time),
  }));
  if (frames.some(frame => !Number.isFinite(frame.timestampSeconds)) ||
      frames.some((frame, index) => index > 0 && frame.timestampSeconds <= frames[index - 1].timestampSeconds)) {
    throw new Error('Video frame timestamps are missing or not strictly increasing. Keep the original and inspect its timing.');
  }
  const duration = Number(info.format?.duration ?? videoStream.duration);
  return { frames, video: {
    codec: videoStream.codec_name ?? null,
    width: videoStream.width, height: videoStream.height,
    averageFrameRate: videoStream.avg_frame_rate ?? null,
    reportedFrameCount: videoStream.nb_frames ? Number(videoStream.nb_frames) : null,
    probedFrameCount: frames.length,
    durationSeconds: Number.isFinite(duration) && duration > 0 ? duration : null,
    audioPresent: info.streams.some(stream => stream.codec_type === 'audio'),
    rotationDegrees: Number.isFinite(Number(videoStream.tags?.rotate)) ? Number(videoStream.tags.rotate)
      : Number.isFinite(Number(videoStream.side_data_list?.find(data => data.rotation != null)?.rotation))
        ? Number(videoStream.side_data_list.find(data => data.rotation != null).rotation) : null,
  } };
}

async function existingOutput(out, sourcePath, sourceHash, frameCount) {
  let data;
  try { data = JSON.parse(await readFile(path.join(out, 'manifest.json'), 'utf8')); }
  catch { throw new Error('Output directory already exists without a readable manifest; choose a new --out.'); }
  if (data.schemaVersion !== 1 || data.provenance !== 'external_rgb_video' ||
      data.source?.path !== sourcePath || data.source?.sha256 !== sourceHash ||
      data.selection?.requestedFrameCount !== frameCount ||
      !Array.isArray(data.frames) || data.frames.length !== frameCount) {
    throw new Error('Output directory belongs to different input or settings; choose a new --out.');
  }
  for (const frame of data.frames) {
    if (!/^image_\d{4}\.jpg$/.test(frame.file) ||
        await sha256(path.join(out, 'frames', frame.file)) !== frame.sha256) {
      throw new Error('Existing extracted frame is missing or modified; preserve it and choose a new --out.');
    }
  }
  if (data.selection.contactSheet?.file !== 'contact-sheet.jpg' ||
      await sha256(path.join(out, 'contact-sheet.jpg')) !== data.selection.contactSheet.sha256) {
    throw new Error('Existing contact sheet is missing or modified; preserve it and choose a new --out.');
  }
  return data;
}

async function main(argv) {
  const options = parse(argv);
  if (!options) { process.stdout.write(help); return; }
  if (!/\.(mov|mp4)$/i.test(options.video)) throw new Error('Input must have a .mov or .mp4 extension.');
  const original = await stat(options.video);
  if (!original.isFile() || original.size === 0 || original.size > maxBytes) {
    throw new Error('Input must be a non-empty file of at most 4 GiB.');
  }
  await mkdir(workRoot, { recursive: true });
  const workReal = await realpath(workRoot);
  const sourceHash = await sha256(options.video);
  const out = options.out ? path.resolve(root, options.out)
    : path.join(workRoot, 't0', sourceHash.slice(0, 16) + `-f${options.frameCount}`);
  if (!within(workRoot, out)) throw new Error('--out must be a dedicated directory inside this project\'s work/.');
  await mkdir(path.dirname(out), { recursive: true });
  const parentReal = await realpath(path.dirname(out));
  if (parentReal !== workReal && !within(workReal, parentReal)) {
    throw new Error('Resolved output parent leaves the project work/ directory.');
  }
  try {
    await access(out);
    const manifest = await existingOutput(out, options.video, sourceHash, options.frameCount);
    process.stdout.write(JSON.stringify({ reused: true, out, framesDirectory: path.join(out, 'frames'),
      contactSheet: path.join(out, 'contact-sheet.jpg'), sourceSHA256: sourceHash,
      frames: manifest.frames.length, reviewRequired: true }, null, 2) + '\n');
    return;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }

  // Verify the dependencies before creating any output.
  const ffmpegVersion = (await execute(options.ffmpeg, ['-version'], 1024 * 1024)).stdout.split(/\r?\n/)[0];
  const ffprobeVersion = (await execute(options.ffprobe, ['-version'], 1024 * 1024)).stdout.split(/\r?\n/)[0];
  const inspected = await inspectVideo(options.video, options.ffprobe);
  const selected = chooseFrames(inspected.frames, options.frameCount);
  const temporary = out + '.partial-' + randomUUID();
  const framesDir = path.join(temporary, 'frames');
  await mkdir(framesDir, { recursive: true });
  const filter = 'select=' + selected.map(frame => `eq(n\\,${frame.sourceFrameIndex})`).join('+');
  await execute(options.ffmpeg, ['-hide_banner', '-nostdin', '-loglevel', 'error', '-i', options.video,
    '-map', '0:v:0', '-vf', filter, '-fps_mode', 'passthrough', '-q:v', '2', path.join(framesDir, 'image_%04d.jpg')], 4 * 1024 * 1024);
  const names = (await readdir(framesDir)).filter(name => /^image_\d{4}\.jpg$/.test(name)).sort();
  if (names.length !== options.frameCount) {
    throw new Error(`FFmpeg produced ${names.length} frames, expected ${options.frameCount}. Partial output retained at ${temporary}.`);
  }
  if (await sha256(options.video) !== sourceHash) {
    throw new Error(`Original video changed during extraction. Partial output retained at ${temporary}.`);
  }
  let totalFrameBytes = 0;
  const frameRecords = [];
  for (let index = 0; index < names.length; index++) {
    const file = path.join(framesDir, names[index]), bytes = (await stat(file)).size;
    if (!bytes || bytes > 20 * 1024 * 1024) throw new Error(`Extracted frame exceeds Hub limit; partial output retained at ${temporary}.`);
    totalFrameBytes += bytes;
    frameRecords.push({ index, file: names[index], sourceFrameIndex: selected[index].sourceFrameIndex,
      sourceTimestampSeconds: selected[index].timestampSeconds, byteSize: bytes, sha256: await sha256(file) });
  }
  if (totalFrameBytes > 256 * 1024 * 1024) throw new Error(`Selected frames exceed Hub total size limit; partial output retained at ${temporary}.`);
  const sheet = path.join(temporary, 'contact-sheet.jpg');
  await execute(options.ffmpeg, ['-hide_banner', '-nostdin', '-loglevel', 'error', '-framerate', '1',
    '-i', path.join(framesDir, 'image_%04d.jpg'), '-frames:v', '1', '-vf',
    `scale=320:-2,tile=4x${options.frameCount / 4}:padding=6:margin=6`, '-q:v', '3', sheet], 4 * 1024 * 1024);
  const manifest = {
    schemaVersion: 1, provenance: 'external_rgb_video',
    createdAtUTC: new Date().toISOString(),
    source: { path: options.video, sha256: sourceHash, byteSize: original.size, containerExtension: path.extname(options.video).toLowerCase(),
      ...inspected.video },
    geometry: { arkitCameraPoseAvailable: false, synchronizedIntrinsicsAvailable: false,
      lidarSceneDepthAvailable: false, metricScaleVerified: false },
    selection: { strategy: 'time_quantiles_5_to_95_nearest_source_frame', requestedFrameCount: options.frameCount,
      sourceFrameCount: inspected.frames.length, qualitySelected: false, manualViewpointReviewRequired: true,
      contactSheet: { file: 'contact-sheet.jpg', sha256: await sha256(sheet) } },
    tools: { ffmpegVersion, ffprobeVersion },
    frames: frameRecords,
  };
  await writeFile(path.join(temporary, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx' });
  // A concurrent run must not replace a completed, different selection.
  try { await access(out); throw new Error('Output appeared during preparation; partial output retained.'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  await rename(temporary, out);
  process.stdout.write(JSON.stringify({ reused: false, out, framesDirectory: path.join(out, 'frames'),
    contactSheet: path.join(out, 'contact-sheet.jpg'), sourceSHA256: sourceHash,
    frames: frameRecords.length, reviewRequired: true }, null, 2) + '\n');
}

try { await main(process.argv.slice(2)); }
catch (error) { process.stderr.write(JSON.stringify({ error: String(error.message ?? error) }) + '\n'); process.exitCode = 1; }
