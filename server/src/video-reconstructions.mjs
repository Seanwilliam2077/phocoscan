import { validateSPZ } from './spz.mjs';
import { DatabaseSync } from 'node:sqlite';
import { createReadStream, mkdirSync, renameSync } from 'node:fs';
import { copyFile, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { requireThat, uuid, nonempty, validateGaussian, validateVideo } from './validation.mjs';
import { validateStudyCameras } from './reconstruction-studies.mjs';
import { validateCaptureMetadata } from './capture-v2.mjs';
import { packPublic } from './keyframe-pack.mjs';

export const VIDEO_DUAL_CONSENT = '2026-11-03-video-dual-v1';
export const NATIVE_DUAL_CONSENT = '2026-11-03-native-dual-v1';
/** Separate consent for the optional cloud branch that trains from the phone's own ARKit poses. */
export const NATIVE_ARKIT_PRIOR_CONSENT = '2026-11-05-native-arkit-prior-v1';
export const ARKIT_PRIOR_ALGORITHM = 'gs_mcmc_arkit_prior';
/** The two versions started from the verified video itself; the ARKit branch has its own route. */
const ROLE_ALGORITHMS = { preview: 'gs_worldmirror2', refined: 'gs_mcmc' };
const MAX_VIDEO = 500 * 1024 * 1024, MAX_MODEL = 150 * 1024 * 1024, MAX_CAMERA = 4 * 1024 * 1024;
const SHA = /^[a-f0-9]{64}$/;
const now = () => new Date().toISOString();
const parse = value => value ? JSON.parse(value) : null;
const digest = async file => { const hash = createHash('sha256'); for await (const chunk of createReadStream(file)) hash.update(chunk); return hash.digest('hex'); };
const canonical = value => JSON.stringify(value, (_, item) => item && typeof item === 'object' && !Array.isArray(item)
  ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);

export function initializeVideoReconstructions(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS video_reconstructions_v2 (id TEXT PRIMARY KEY, userId TEXT NOT NULL, title TEXT NOT NULL,
      consentVersion TEXT NOT NULL, expectedSha256 TEXT NOT NULL, expectedByteSize INTEGER NOT NULL,
      videoPath TEXT, videoMime TEXT, uploadedAt TEXT, createdAt TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS video_reconstruction_owner ON video_reconstructions_v2(userId);
    CREATE TABLE IF NOT EXISTS video_reconstruction_tasks_v2 (id TEXT PRIMARY KEY, reconstructionId TEXT NOT NULL,
      algorithm TEXT NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL, phase TEXT NOT NULL, claimId TEXT, workerId TEXT,
      errorJson TEXT, resultJson TEXT, resultDirectory TEXT, resultFingerprint TEXT, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL,
      UNIQUE(reconstructionId, algorithm));
    CREATE TABLE IF NOT EXISTS video_reconstruction_tombstones_v2 (id TEXT PRIMARY KEY,userId TEXT NOT NULL,deletedAt TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS video_reconstruction_attempts_v2 (id TEXT PRIMARY KEY,reconstructionId TEXT NOT NULL,
      replacementId TEXT NOT NULL UNIQUE,taskJson TEXT NOT NULL,archivedAt TEXT NOT NULL);
  `);
  db.exec('BEGIN IMMEDIATE');
  try {
    const columns=new Set(db.prepare('PRAGMA table_info(video_reconstructions_v2)').all().map(c=>c.name));
    for(const [name,type] of Object.entries({sourceKind:"TEXT NOT NULL DEFAULT 'external_rgb_video'",captureId:'TEXT',captureReceiptId:'TEXT',
      sourceMetadataPath:'TEXT',sourceMetadataSha256:'TEXT',sourceMetadataByteSize:'INTEGER',sourceValidationJson:'TEXT'})) {
      if(!columns.has(name))db.exec(`ALTER TABLE video_reconstructions_v2 ADD COLUMN ${name} ${type}`);
    }
    db.exec('CREATE UNIQUE INDEX IF NOT EXISTS video_reconstruction_capture ON video_reconstructions_v2(captureId) WHERE captureId IS NOT NULL');
    // Optional task inputs (2026-11-09): the ARKit branch may be bound to the phone's keyframe pack.
    if(!new Set(db.prepare('PRAGMA table_info(video_reconstruction_tasks_v2)').all().map(c=>c.name)).has('inputJson'))
      db.exec('ALTER TABLE video_reconstruction_tasks_v2 ADD COLUMN inputJson TEXT');
    db.exec('COMMIT');
  }catch(error){db.exec('ROLLBACK');throw error;}
}

export function videoReconstructionStore(db, { dataDir }) {
  const root = path.resolve(dataDir);
  initializeVideoReconstructions(db);
  const file = relative => { const result=path.resolve(root,relative); requireThat(result.startsWith(root+path.sep),500,'invalid_storage_path','Invalid storage path.');return result; };
  const transaction = action => { db.exec('BEGIN IMMEDIATE');try { const out=action();db.exec('COMMIT');return out; }catch(error){db.exec('ROLLBACK');throw error;} };
  const nativeCapture=(captureId,userId)=>{
    requireThat(uuid(captureId),400,'invalid_id','Invalid capture ID.');
    const capture=db.prepare('SELECT * FROM captures_v2 WHERE id = ?').get(captureId);
    requireThat(capture&&(!userId||capture.userId===userId),404,'capture_not_found','Capture not found.');return capture;
  };
  const sourceLineage=row=>{
    if(row.sourceKind!=='native_arkit_capture')return {sourceKind:'external_rgb_video'};
    const capture=nativeCapture(row.captureId,row.userId);
    requireThat(capture.verifiedAt&&capture.receiptId===row.captureReceiptId&&capture.rgbPath===row.videoPath&&capture.rgbHash===row.expectedSha256
      &&capture.rgbSize===row.expectedByteSize&&capture.metadataPath===row.sourceMetadataPath&&capture.metadataHash===row.sourceMetadataSha256
      &&capture.metadataSize===row.sourceMetadataByteSize&&capture.validationJson===row.sourceValidationJson,
      409,'native_source_changed','Native capture lineage changed.');
    return {sourceKind:'native_arkit_capture',captureId:row.captureId,captureReceiptId:row.captureReceiptId,
      sourceMetadataSha256:row.sourceMetadataSha256,sourceMetadataByteSize:row.sourceMetadataByteSize,
      nativeCaptureValidation:parse(row.sourceValidationJson)};
  };
  const verifyNativeBytes=async row=>{
    const lineage=sourceLineage(row);
    requireThat(row.sourceKind==='native_arkit_capture',409,'native_source_required','Expected native capture lineage.');
    try {
      requireThat((await stat(file(row.videoPath))).size===row.expectedByteSize&&await digest(file(row.videoPath))===row.expectedSha256
        &&(await stat(file(row.sourceMetadataPath))).size===row.sourceMetadataByteSize&&await digest(file(row.sourceMetadataPath))===row.sourceMetadataSha256,
        409,'native_source_changed','Native source video or metadata bytes changed.');
      const validation=validateCaptureMetadata(JSON.parse(await readFile(file(row.sourceMetadataPath),'utf8')),row.captureId,row.expectedSha256);
      requireThat(canonical(validation)===canonical(lineage.nativeCaptureValidation),409,'native_source_changed','Native metadata validation changed.');
    }catch(error){if(error.code==='ENOENT')requireThat(false,409,'native_source_changed','Native source bytes are unavailable.');throw error;}
    return lineage;
  };
  const own = (id,userId) => {
    requireThat(uuid(id),400,'invalid_id','Invalid reconstruction ID.');
    const row=db.prepare('SELECT * FROM video_reconstructions_v2 WHERE id = ?').get(id);
    requireThat(row && (!userId || row.userId===userId),404,'video_reconstruction_not_found','Video reconstruction not found.');sourceLineage(row);return row;
  };
  const job = (id,claimId) => {
    requireThat(uuid(id),400,'invalid_id','Invalid task ID.');
    const row=db.prepare('SELECT * FROM video_reconstruction_tasks_v2 WHERE id = ?').get(id);
    requireThat(row,404,'video_reconstruction_task_not_found','Task not found.');own(row.reconstructionId);
    if(claimId!==undefined)requireThat(uuid(claimId)&&row.claimId===claimId,409,'claim_conflict','Task belongs to a different worker claim.');
    return row;
  };
  const taskInput = row => { const input=parse(row.inputJson);return input?.keyframes?{keyframes:packPublic(input.keyframes)}:null; };
  const taskPublic = row => ({id:row.id,algorithm:row.algorithm,role:row.role,status:row.status,phase:row.phase,
    ...(row.errorJson?{error:parse(row.errorJson)}:{}),...(row.resultJson?{result:parse(row.resultJson)}:{}),
    ...(taskInput(row)?{input:taskInput(row)}:{}),createdAt:row.createdAt,updatedAt:row.updatedAt});
  const summary = row => {
    const tasks=db.prepare('SELECT * FROM video_reconstruction_tasks_v2 WHERE reconstructionId = ? ORDER BY role').all(row.id).map(taskPublic);
    // No tasks: an external video still waits for its bytes; a verified native capture whose
    // owner has not picked a version yet is idle.
    let status=row.videoPath?'idle':'awaiting_upload';
    if(tasks.length){status=tasks.every(t=>t.status==='ready')?'ready':tasks.some(t=>t.status==='ready')?'partial':tasks.some(t=>t.status==='processing')?'processing':tasks.some(t=>t.status==='queued')?'queued':tasks.some(t=>t.status==='blocked')?'blocked':'failed';}
    const lineage=sourceLineage(row);delete lineage.nativeCaptureValidation;
    return {id:row.id,title:row.title,...lineage,sourceVideoSha256:row.expectedSha256,sourceByteSize:row.expectedByteSize,
      status,uploadedAt:row.uploadedAt,createdAt:row.createdAt,tasks,
      previousAttempts:db.prepare('SELECT taskJson,replacementId,archivedAt FROM video_reconstruction_attempts_v2 WHERE reconstructionId = ? ORDER BY archivedAt').all(row.id)
        .map(a=>({...parse(a.taskJson),replacementId:a.replacementId,archivedAt:a.archivedAt}))};
  };
  const internalTask = row => ({id:row.id,reconstructionId:row.reconstructionId,algorithm:row.algorithm,role:row.role,status:row.status,phase:row.phase,claimId:row.claimId,workerId:row.workerId});
  const boundSubjectPack=(captureId,userId,sha)=>{
    const capture=nativeCapture(captureId,userId);
    requireThat(SHA.test(sha??'')&&capture.keyframesHash===sha&&capture.keyframesPath,
      409,'keyframes_required','Upload and verify the selected subject keyframes first.');
    const pack=parse(capture.keyframesJson);
    requireThat(pack?.sha256===sha&&pack.masks===true,409,'subject_masks_required','High-quality subject training requires a mask for every keyframe.');
    return {keyframes:{...pack,path:capture.keyframesPath}};
  };
  const enqueue=(id,roles=Object.keys(ROLE_ALGORITHMS),subjectInput=null)=>{
    let added=false;
    for(const role of roles) {
      // One task per algorithm (retries replace the row), so a repeated request adds nothing.
      const existing=db.prepare('SELECT * FROM video_reconstruction_tasks_v2 WHERE reconstructionId = ? AND algorithm = ?').get(id,ROLE_ALGORITHMS[role]);
      if(existing){
        if(role==='refined'&&subjectInput)requireThat(parse(existing.inputJson)?.keyframes?.sha256===subjectInput.keyframes.sha256,
          409,'task_input_conflict','An existing task cannot change inputs; explicitly retry a failed attempt.');
        continue;
      }
      const date=now();db.prepare('INSERT INTO video_reconstruction_tasks_v2 (id,reconstructionId,algorithm,role,status,phase,createdAt,updatedAt,inputJson) VALUES (?,?,?,?,?,?,?,?,?)')
        .run(randomUUID(),id,ROLE_ALGORITHMS[role],role,'queued','awaiting_worker',date,date,role==='refined'&&subjectInput?JSON.stringify(subjectInput):null);
      added=true;
    }
    return added;
  };
  return {
    getForCapture(captureId,userId) {
      nativeCapture(captureId,userId);
      const row=db.prepare('SELECT * FROM video_reconstructions_v2 WHERE captureId = ? AND userId = ?').get(captureId,userId);
      return row?summary(row):null;
    },
    async enqueueNative(captureId,userId,body) {
      requireThat(body?.consentVersion===NATIVE_DUAL_CONSENT,422,'native_dual_consent_required','Native dual reconstruction consent is required.');
      // Version selection (2026-11-10): `roles` lists the versions to start now. Omitted keeps
      // the original behaviour (both, and an existing reconstruction is returned untouched);
      // an empty list only opens the reconstruction, e.g. for the ARKit branch on its own.
      const roles=body.roles;
      if(roles!==undefined)requireThat(Array.isArray(roles)&&roles.length<=2&&new Set(roles).size===roles.length
        &&roles.every(role=>typeof role==='string'&&Object.hasOwn(ROLE_ALGORITHMS,role)),422,'invalid_reconstruction_roles','roles may list preview and refined, each once.');
      const capture=nativeCapture(captureId,userId);
      if(body.keyframesSha256!==undefined)requireThat(roles?.includes('refined'),422,'invalid_keyframe_role','Subject keyframes belong only to the requested high-quality task.');
      const subjectInput=body.keyframesSha256===undefined?null:boundSubjectPack(captureId,userId,body.keyframesSha256);
      const prior=db.prepare('SELECT * FROM video_reconstructions_v2 WHERE captureId = ?').get(captureId);
      if(prior){
        requireThat(prior.userId===userId,404,'capture_not_found','Capture not found.');
        if(!roles?.length)return {created:false,reconstruction:summary(prior)};
        // Adds only the requested versions that do not exist yet; never touches existing tasks.
        return transaction(()=>{
          const row=db.prepare('SELECT * FROM video_reconstructions_v2 WHERE captureId = ? AND userId = ?').get(captureId,userId);
          requireThat(row,404,'capture_not_found','Capture not found.');sourceLineage(row);
          return {created:enqueue(row.id,roles,subjectInput),reconstruction:summary(row)};
        });
      }
      requireThat(capture.verifiedAt&&capture.receiptId&&capture.rgbPath&&capture.metadataPath,409,'capture_incomplete','Complete and verify native RGB and metadata before reconstruction.');
      const validation=parse(capture.validationJson);
      requireThat(validation?.frameCount>=2&&Number.isFinite(validation.timestampSpanSeconds)&&validation.timestampSpanSeconds>0&&validation.timestampSpanSeconds<=600,
        409,'native_source_too_short','Dual reconstruction needs at least two timed source frames.');
      const row={id:randomUUID(),userId,title:'原生扫描双重建',consentVersion:NATIVE_DUAL_CONSENT,sourceKind:'native_arkit_capture',captureId,
        captureReceiptId:capture.receiptId,expectedSha256:capture.rgbHash,expectedByteSize:capture.rgbSize,videoPath:capture.rgbPath,videoMime:capture.rgbMime,
        sourceMetadataPath:capture.metadataPath,sourceMetadataSha256:capture.metadataHash,sourceMetadataByteSize:capture.metadataSize,sourceValidationJson:capture.validationJson};
      await verifyNativeBytes(row);
      await mkdir(file(path.join('video-reconstructions',row.id)),{recursive:true});
      return transaction(()=>{
        sourceLineage(row);
        const existing=db.prepare('SELECT * FROM video_reconstructions_v2 WHERE captureId = ?').get(captureId);
        if(existing)return {created:roles?.length?enqueue(existing.id,roles,subjectInput):false,reconstruction:summary(existing)};
        const date=now();
        db.prepare(`INSERT INTO video_reconstructions_v2 (id,userId,title,consentVersion,expectedSha256,expectedByteSize,videoPath,videoMime,uploadedAt,createdAt,
          sourceKind,captureId,captureReceiptId,sourceMetadataPath,sourceMetadataSha256,sourceMetadataByteSize,sourceValidationJson) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
          .run(row.id,userId,row.title,row.consentVersion,row.expectedSha256,row.expectedByteSize,row.videoPath,row.videoMime,date,date,row.sourceKind,captureId,
            row.captureReceiptId,row.sourceMetadataPath,row.sourceMetadataSha256,row.sourceMetadataByteSize,row.sourceValidationJson);
        enqueue(row.id,roles,subjectInput);return {created:true,reconstruction:summary(own(row.id,userId))};
      });
    },
    /** Adds the optional ARKit pose-prior cloud task to an existing native reconstruction.
     * Idempotent per reconstruction; its retries reuse the generic failed-branch retry. */
    enqueueArkitPrior(captureId,userId,body) {
      requireThat(body?.consentVersion===NATIVE_ARKIT_PRIOR_CONSENT,422,'arkit_prior_consent_required','ARKit pose cloud training consent is required.');
      requireThat(uuid(body.id),422,'invalid_arkit_prior','Provide a stable task ID.');
      nativeCapture(captureId,userId);
      return transaction(()=>{
        const row=db.prepare('SELECT * FROM video_reconstructions_v2 WHERE captureId = ? AND userId = ?').get(captureId,userId);
        requireThat(row,409,'native_reconstruction_required','Start the native reconstruction before ARKit pose training.');
        const lineage=sourceLineage(row);
        requireThat(lineage.nativeCaptureValidation?.poseSource==='arkit_device_reported',409,'arkit_poses_required','This capture has no device-reported ARKit poses.');
        if(db.prepare('SELECT id FROM video_reconstruction_tasks_v2 WHERE reconstructionId = ? AND algorithm = ?').get(row.id,ARKIT_PRIOR_ALGORITHM))
          return {created:false,reconstruction:summary(row)};
        requireThat(!db.prepare('SELECT id FROM video_reconstruction_tasks_v2 WHERE id = ?').get(body.id)
          &&!db.prepare('SELECT id FROM video_reconstruction_attempts_v2 WHERE id = ?').get(body.id),409,'arkit_prior_conflict','Task identity is already used.');
        // Optional: train from the phone's keyframe pack, bound by its SHA-256 for the task's lifetime.
        let input=null;
        if(body.keyframesSha256!==undefined) {
          const capture=nativeCapture(captureId,userId);
          requireThat(SHA.test(body.keyframesSha256??'')&&capture.keyframesHash===body.keyframesSha256&&capture.keyframesPath,
            409,'keyframes_required','Upload this keyframe pack before starting training from it.');
          input={keyframes:{...parse(capture.keyframesJson),path:capture.keyframesPath}};
          requireThat(input.keyframes.sha256===body.keyframesSha256,409,'keyframes_changed','Stored keyframe pack summary differs.');
        }
        const date=now();
        db.prepare('INSERT INTO video_reconstruction_tasks_v2 (id,reconstructionId,algorithm,role,status,phase,createdAt,updatedAt,inputJson) VALUES (?,?,?,?,?,?,?,?,?)')
          .run(body.id,row.id,ARKIT_PRIOR_ALGORITHM,'arkit','queued','awaiting_worker',date,date,input?JSON.stringify(input):null);
        return {created:true,reconstruction:summary(row)};
      });
    },
    create(userId,body) {
      requireThat(uuid(body.id)&&nonempty(body.title,120)&&body.consentVersion===VIDEO_DUAL_CONSENT&&SHA.test(body.expectedSha256)&&Number.isSafeInteger(body.expectedByteSize)&&body.expectedByteSize>0&&body.expectedByteSize<=MAX_VIDEO,
        422,'invalid_video_reconstruction','Provide an ID, title, consent and bounded expected video hash/size.');
      return transaction(()=>{
        requireThat(!db.prepare('SELECT id FROM video_reconstruction_tombstones_v2 WHERE id = ?').get(body.id),409,'video_reconstruction_deleted','This reconstruction was deleted.');
        const prior=db.prepare('SELECT * FROM video_reconstructions_v2 WHERE id = ?').get(body.id);
        if(prior){requireThat(prior.userId===userId&&prior.title===body.title&&prior.expectedSha256===body.expectedSha256&&prior.expectedByteSize===body.expectedByteSize&&prior.consentVersion===body.consentVersion,409,'video_reconstruction_conflict','Reconstruction identity is immutable.');return {created:false,reconstruction:summary(prior)};}
        db.prepare('INSERT INTO video_reconstructions_v2 (id,userId,title,consentVersion,expectedSha256,expectedByteSize,createdAt) VALUES (?,?,?,?,?,?,?)').run(body.id,userId,body.title,body.consentVersion,body.expectedSha256,body.expectedByteSize,now());
        return {created:true,reconstruction:summary(own(body.id,userId))};
      });
    },
    get(id,userId){return summary(own(id,userId));},
    list(userId){return db.prepare('SELECT * FROM video_reconstructions_v2 WHERE userId = ? ORDER BY rowid DESC').all(userId).map(summary);},
    retry(id,userId,{failedTaskId,id:replacementId,keyframesSha256}={}) {
      requireThat(uuid(failedTaskId)&&uuid(replacementId)&&failedTaskId!==replacementId,422,'invalid_retry','Provide the failed task ID and a new stable retry ID.');
      return transaction(()=>{
        const source=own(id,userId);
        const prior=db.prepare('SELECT * FROM video_reconstruction_attempts_v2 WHERE id = ?').get(failedTaskId);
        if(prior){requireThat(prior.reconstructionId===id&&prior.replacementId===replacementId,409,'retry_conflict','This failed attempt already has a different retry.');if(keyframesSha256!==undefined)requireThat(parse(job(replacementId).inputJson)?.keyframes?.sha256===keyframesSha256,409,'retry_conflict','Retry inputs differ.');return summary(source);}
        const task=job(failedTaskId);
        requireThat(task.reconstructionId===id,404,'video_reconstruction_task_not_found','Task not found.');
        // Unknown remote writes require reconciliation, never an automatic replacement.
        requireThat(task.status==='failed',409,'retry_requires_failure','Only a confirmed failed task can be retried.');
        requireThat(!db.prepare('SELECT id FROM video_reconstruction_tasks_v2 WHERE id = ?').get(replacementId)
          &&!db.prepare('SELECT id FROM video_reconstruction_attempts_v2 WHERE id = ?').get(replacementId),409,'retry_conflict','Retry identity is already used.');
        let inputJson=task.inputJson??null;
        if(keyframesSha256!==undefined){
          requireThat(task.role==='refined'&&source.sourceKind==='native_arkit_capture',422,'invalid_keyframe_role','Only a failed native high-quality task can bind subject keyframes.');
          const input=boundSubjectPack(source.captureId,userId,keyframesSha256);
          requireThat(!inputJson||parse(inputJson)?.keyframes?.sha256===keyframesSha256,409,'task_input_conflict','A bound pack is immutable.');
          inputJson=JSON.stringify(input);
        }
        const date=now();
        db.prepare('INSERT INTO video_reconstruction_attempts_v2 (id,reconstructionId,replacementId,taskJson,archivedAt) VALUES (?,?,?,?,?)')
          .run(failedTaskId,id,replacementId,JSON.stringify(taskPublic(task)),date);
        db.prepare('DELETE FROM video_reconstruction_tasks_v2 WHERE id = ?').run(failedTaskId);
        // Preserve prior inputs; an explicit first subject-pack binding upgrades only this failed attempt.
        db.prepare('INSERT INTO video_reconstruction_tasks_v2 (id,reconstructionId,algorithm,role,status,phase,createdAt,updatedAt,inputJson) VALUES (?,?,?,?,?,?,?,?,?)')
          .run(replacementId,id,task.algorithm,task.role,'queued','awaiting_worker',date,date,inputJson);
        return summary(source);
      });
    },
    async acceptVideo(id,userId,upload) {
      const initial=own(id,userId);
      requireThat(initial.sourceKind==='external_rgb_video',409,'native_source_immutable','Native reconstruction uses the already verified capture original.');
      requireThat(['video/mp4','video/quicktime'].includes(upload.mime),415,'content_type','Upload MP4 or MOV video.');
      requireThat(upload.hash===initial.expectedSha256&&upload.size===initial.expectedByteSize,422,'video_hash_mismatch','Uploaded video does not match expected bytes/hash.');
      await validateVideo(upload.temporary);
      const relative=path.join('video-reconstructions',id,upload.mime==='video/quicktime'?'source.mov':'source.mp4');
      await mkdir(path.dirname(file(relative)),{recursive:true});
      let moved=false;
      try {
        return transaction(()=>{
          const row=own(id,userId);
          if(row.videoPath){requireThat(row.videoMime===upload.mime,409,'video_reconstruction_conflict','Existing video media type is immutable.');return summary(row);}
          renameSync(upload.temporary,file(relative));moved=true;
          db.prepare('UPDATE video_reconstructions_v2 SET videoPath = ?, videoMime = ?, uploadedAt = ? WHERE id = ?').run(relative,upload.mime,now(),id);
          enqueue(id);
          return summary(own(id,userId));
        });
      }catch(error){if(moved)await rm(file(relative),{force:true});throw error;}
    },
    resultFile(id,taskId,userId,cameras=false,mobile=false) {
      own(id,userId);const task=job(taskId);requireThat(task.reconstructionId===id&&task.status==='ready'&&task.resultJson,404,'reconstruction_result_not_found','Result is not available.');
      const result=parse(task.resultJson);if(mobile){requireThat(result.mobile,404,'derivative_unavailable','No mobile derivative.');return {relative:path.join(task.resultDirectory,'scene.spz'),hash:result.mobile.sha256,mime:'application/octet-stream'};}return {relative:path.join(task.resultDirectory,cameras?'cameras.json':`scene.${result.format}`),hash:cameras?result.cameraSha256:result.sha256,mime:cameras?'application/json':'application/octet-stream'};
    },
    async delete(id,userId) {
      requireThat(uuid(id),400,'invalid_id','Invalid reconstruction ID.');
      transaction(()=>{
        const gone=db.prepare('SELECT userId FROM video_reconstruction_tombstones_v2 WHERE id = ?').get(id);
        if(gone){requireThat(gone.userId===userId,404,'video_reconstruction_not_found','Video reconstruction not found.');return;}
        const row=own(id,userId);requireThat(row.sourceKind!=='native_arkit_capture',409,'native_capture_delete_required','Delete the native capture to remove its linked results.');
        db.prepare('INSERT INTO video_reconstruction_tombstones_v2 (id,userId,deletedAt) VALUES (?,?,?)').run(id,userId,now());
        db.prepare('DELETE FROM video_reconstruction_tasks_v2 WHERE reconstructionId = ?').run(id);
        db.prepare('DELETE FROM video_reconstruction_attempts_v2 WHERE reconstructionId = ?').run(id);
        db.prepare('DELETE FROM video_reconstructions_v2 WHERE id = ?').run(id);
      });
      await rm(file(path.join('video-reconstructions',id)),{recursive:true,force:true});
    },
    retireForCapture(captureId,userId) {
      // The API retires the native capture, legacy FF link and dual tasks in
      // one SQLite transaction, before asynchronous physical file cleanup.
      requireThat(db.isTransaction,500,'transaction_required','Retire native reconstruction inside its capture deletion transaction.');
      nativeCapture(captureId,userId);
      const row=db.prepare('SELECT * FROM video_reconstructions_v2 WHERE captureId = ? AND userId = ?').get(captureId,userId);
      if(!row)return null;
      sourceLineage(row);
      db.prepare('INSERT INTO video_reconstruction_tombstones_v2 (id,userId,deletedAt) VALUES (?,?,?)').run(row.id,userId,now());
      db.prepare('DELETE FROM video_reconstruction_tasks_v2 WHERE reconstructionId = ?').run(row.id);
      db.prepare('DELETE FROM video_reconstruction_attempts_v2 WHERE reconstructionId = ?').run(row.id);
      db.prepare('DELETE FROM video_reconstructions_v2 WHERE id = ?').run(row.id);
      return path.join('video-reconstructions',row.id);
    },
    pendingJobs(){return db.prepare("SELECT * FROM video_reconstruction_tasks_v2 WHERE status IN ('queued','processing') ORDER BY createdAt,role").all().map(internalTask);},
    claim(jobId,workerId) {
      requireThat(nonempty(workerId,160),422,'invalid_worker','A persistent worker ID is required.');
      return transaction(()=>{
        let task=job(jobId);
        if(task.status==='processing'){requireThat(task.workerId===workerId,409,'claim_conflict','Another worker owns this task.');return internalTask(task);}
        requireThat(task.status==='queued',409,'task_inactive','Only queued tasks can be claimed.');
        db.prepare("UPDATE video_reconstruction_tasks_v2 SET status = 'processing',phase = 'starting',claimId = ?,workerId = ?,updatedAt = ? WHERE id = ?").run(randomUUID(),workerId,now(),jobId);
        return internalTask(job(jobId));
      });
    },
    source(jobId,claimId) {
      const task=job(jobId,claimId),row=own(task.reconstructionId);
      if(claimId!==undefined)requireThat(task.status==='processing',409,'task_inactive','This worker task is no longer active.');
      requireThat(row.videoPath,409,'source_not_uploaded','Source video has not been verified.');
      const input=parse(task.inputJson);let keyframes;
      if(input?.keyframes) {
        // The pack must still be the one bound at task creation.
        const capture=nativeCapture(row.captureId,row.userId);
        requireThat(capture.keyframesHash===input.keyframes.sha256&&capture.keyframesPath===input.keyframes.path,409,'keyframes_changed','The bound keyframe pack changed.');
        keyframes={...input.keyframes,directory:file(input.keyframes.path)};
      }
      return {jobId,reconstructionId:row.id,userId:row.userId,algorithm:task.algorithm,role:task.role,sourceVideoPath:file(row.videoPath),sourceVideoSha256:row.expectedSha256,sourceByteSize:row.expectedByteSize,
        ...sourceLineage(row),...(row.sourceMetadataPath?{sourceMetadataPath:file(row.sourceMetadataPath)}:{}),...(keyframes?{keyframes}:{})};
    },
    setPhase(jobId,claimId,status,phase,error) {
      requireThat(['processing','failed','blocked'].includes(status)&&nonempty(phase,120),422,'invalid_task_phase','Use processing, failed or blocked and a bounded phase.');
      if(error!==undefined)requireThat(error&&nonempty(error.code,100)&&nonempty(error.message,500),422,'invalid_task_error','Use a bounded error code and message.');
      return transaction(()=>{
        const task=job(jobId,claimId);requireThat(task.status==='processing',409,'task_inactive','Only an active worker task may change phase.');
        db.prepare('UPDATE video_reconstruction_tasks_v2 SET status = ?,phase = ?,errorJson = ?,updatedAt = ? WHERE id = ?').run(status,phase,error?JSON.stringify({code:error.code,message:error.message}):null,now(),jobId);
        return internalTask(job(jobId));
      });
    },
    async publish(jobId,claimId,{modelFile,cameraFile,mobileFile,provenance}) {
      const initialTask=job(jobId,claimId),source=own(initialTask.reconstructionId);
      requireThat(['processing','ready'].includes(initialTask.status),409,'task_inactive','Task cannot publish a result.');
      requireThat(provenance&&provenance.sourceVideoSha256===source.expectedSha256&&nonempty(provenance.projectId,128)&&nonempty(provenance.stepId,128),422,'result_provenance_mismatch','Result must identify this video and exact provider project/step.');
      const lineage=source.sourceKind==='native_arkit_capture'?await verifyNativeBytes(source):sourceLineage(source);
      for(const key of ['sourceKind','captureId','captureReceiptId','sourceMetadataSha256','sourceMetadataByteSize','nativeCaptureValidation']) {
        if(provenance[key]!==undefined)requireThat(canonical(provenance[key])===canonical(lineage[key]),422,'result_provenance_mismatch','Result source lineage differs from the verified capture.');
      }
      provenance={...provenance,...lineage};
      requireThat(nonempty(modelFile,4096)&&nonempty(cameraFile,4096),422,'invalid_result_files','Model and camera files are required.');
      const format=initialTask.role==='preview'?'splat':'ply',shDegree=initialTask.role==='preview'?0:3;
      requireThat((await stat(modelFile)).size<=MAX_MODEL&&(await stat(cameraFile)).size<=MAX_CAMERA,413,'result_too_large','Result exceeds phone limits.');
      const stage=file(path.join('.tmp',`video-result-${randomUUID()}`));await mkdir(stage,{recursive:true});
      let finalDirectory,committed=false;
      try {
        const stagedModel=path.join(stage,`scene.${format}`),stagedCameras=path.join(stage,'cameras.json');
        await copyFile(modelFile,stagedModel);await copyFile(cameraFile,stagedCameras);
        const modelStat=await stat(stagedModel),cameraStat=await stat(stagedCameras);
        requireThat(modelStat.size<=MAX_MODEL&&cameraStat.size<=MAX_CAMERA,413,'result_too_large','Staged result exceeds phone limits.');
        let actualSH=0;
        const validation=await validateGaussian(stagedModel,format,{onHeader(h){actualSH=h.properties?.some(p=>p.name==='f_rest_44')?3:0;}});
        requireThat(actualSH===shDegree,422,'result_sh_mismatch','Result does not preserve the required SH degree.');
        validateStudyCameras(JSON.parse(await readFile(stagedCameras,'utf8')));
        const sha256=await digest(stagedModel),cameraSha256=await digest(stagedCameras);
        const base=`/v2/video-reconstructions/${source.id}/results/${jobId}`;
        const result={id:jobId,role:initialTask.role,algorithm:initialTask.algorithm,status:'ready',format,shDegree,pointCount:validation.gaussianCount,byteSize:modelStat.size,sha256,filePath:base+'/file',cameraPath:base+'/cameras',cameraSha256,cameraByteSize:cameraStat.size};
        if(mobileFile) {
          const derivative=path.join(stage,'scene.spz');await copyFile(mobileFile,derivative);
          const checked=await validateSPZ(derivative,{pointCount:validation.gaussianCount,shDegree});
          result.mobile={format:'spz',shDegree,pointCount:validation.gaussianCount,byteSize:checked.byteSize,sha256:await digest(derivative),filePath:base+'/mobile',originalSha256:sha256,lossy:true};
        }
        const provenanceJSON=canonical(provenance);requireThat(Buffer.byteLength(provenanceJSON)<=1024*1024,413,'provenance_too_large','Provenance exceeds 1 MiB.');
        const fingerprint=createHash('sha256').update(canonical({result,provenance})).digest('hex');
        await writeFile(path.join(stage,'provenance.json'),provenanceJSON+'\n');
        const published = transaction(()=>{
          const task=job(jobId,claimId);own(source.id);
          if(task.status==='ready'){requireThat(task.resultFingerprint===fingerprint,409,'result_conflict','An immutable different result already exists.');return parse(task.resultJson);}
          requireThat(task.status==='processing',409,'task_inactive','Task is no longer active.');
          const relative=path.join('video-reconstructions',source.id,`result-${jobId}-${randomUUID()}`);
          finalDirectory=file(relative);renameSync(stage,finalDirectory);
          db.prepare("UPDATE video_reconstruction_tasks_v2 SET status = 'ready', phase = 'ready', resultJson = ?,resultDirectory = ?,resultFingerprint = ?,errorJson = NULL,updatedAt = ? WHERE id = ?")
            .run(JSON.stringify(result),relative,fingerprint,now(),jobId);
          return result;
        });
        committed=true;return published;
      }finally{await rm(stage,{recursive:true,force:true});if(finalDirectory&&!committed)await rm(finalDirectory,{recursive:true,force:true});}
    },
  };
}

export function openVideoReconstructionRepository({dataDir}) {
  requireThat(nonempty(dataDir,4096),500,'configuration','dataDir is required.');
  mkdirSync(path.resolve(dataDir),{recursive:true});
  const db=new DatabaseSync(path.join(path.resolve(dataDir),'pocketworld.sqlite'));
  db.exec('PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;');
  return {...videoReconstructionStore(db,{dataDir}),close:()=>db.close()};
}
