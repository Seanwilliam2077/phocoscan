# PocketWorld MVP implementation contract

> 2026-11-02: This is the existing v1 video/game contract, retained for compatibility. The active native iPhone validation plan is `docs/NATIVE-IOS-VALIDATION-PLAN.md`. v1 has no endpoint for synchronized ARKit frame metadata or depth; those require an additive, versioned capture-package API and server verification before any robot/video data claim. The old game quest and grid requirements below are historical scope.

Native SwiftUI iOS app (iOS 18+, due to pinned MetalSplatter requirement); Windows Node 24 backend, no player HTML. All times ISO8601 strings, IDs UUID strings. JSON UTF-8. JSON errors `{error:{code,message}}`. Bearer user tokens, separate bearer admin token. Max video 500 MiB, model 150 MiB; no external URL imports.

## API v1 (frozen between implementers)

- `GET /health` → `{ok:true,version:"0.1.0"}`
- `POST /v1/auth/anonymous` body `{}` → `{userId,token}`. Store token in iOS Keychain. No credentials in source.
- `GET /v1/sessions` → `{sessions:[SessionEnvelope]}`.
- `POST /v1/sessions` → SessionEnvelope. Body `{id,questId,environment,captureMode,consentVersion,parentSessionId?,sceneId?}`. ID created once on client; retries identical data idempotent, conflicts rejected. Mode `in_app_rgb|external_app`, environment `indoor|outdoor|unknown`. Consent version `2026-10-22-v1`.
- `GET /v1/sessions/:id` → SessionEnvelope.
- `PUT /v1/sessions/:id/video` raw bytes, Content-Type `video/quicktime` or `video/mp4` → SessionEnvelope. Validate file container basics, not a quality guarantee; original immutable after submission. Retry same bytes permitted, conflicting contents rejected.
- `PUT /v1/sessions/:id/preview` raw JPEG → `{ok:true}` optional.
- `POST /v1/sessions/:id/submit` JSON `{capturedAt,durationSeconds,width,height,fps}` → SessionEnvelope. Require video, create exactly one manual queued job; no simulated processing.
- `PUT /v1/sessions/:id/asset?format=ply&tool=Scaniverse` raw bytes → SessionEnvelope. Only external_app sessions. Support gaussian PLY (binary little endian and ASCII) and 32-byte .splat. SPZ can be added only with proper validation. Imported readable asset creates ready job; source external_asset_only, quality needs_review, dualUse not_evaluated. Reject generic point clouds and malformed assets. File-derived IDs/hash assigned by server.
- `POST /v1/sessions/:id/reward` body `{}` → `{reward:Reward}`. Submitted native or parsed imported external only. One reward per session (and quest strategy handled by client), idempotent. Reward `{id,sessionId,questId,cardKind,grantedAt}`. Quest mapping below. Never revoke awarded card on processing failure.
- `GET /v1/assets/:id/file` authenticated raw bytes.
- `GET /v1/sessions/:id/preview` authenticated JPEG, 404 if missing.
- `DELETE /v1/sessions/:id` → `{ok:true}` delete video, preview, assets, jobs, lineage references and session events; keep minimal reward ledger for idempotency, no asset references. Existing game card becomes generic virtual card.
- `POST /v1/events` `{events:[{id,name,occurredAt,questId?,sessionId?,assetId?,properties?}]}` → `{accepted: n}` idempotent IDs, authenticated own references. Do not include raw video in logs.
- `GET /v1/game` → `{state:object|null}`; `PUT /v1/game` `{state:object}` → `{ok:true}`. Client persists offline first. This is backup not a rewards authority.

SessionEnvelope: `{session:CaptureSession,job:ReconstructionJob|null,asset:SceneAsset|null,reward:Reward|null}`. CaptureSession: `{id,userId,questId,sceneId,parentSessionId?,environment,captureMode,provenance,captureStatus,capturedAt?,submittedAt?,originalVideoId?,videoDurationSeconds?,width?,height?,fps?,poseSource:"none",calibrationAvailable:false,rawDataAvailable:boolean,consentVersion,createdAt}`. captureStatus: draft/saved/submitted/awaiting_asset_import/asset_imported. ReconstructionJob: `{id,sessionId,provider:"manual",status:"queued"|"processing"|"ready"|"failed"|"cancelled",resultAssetId?,errorMessage?}`. SceneAsset: `{id,sourceSessionIds:[id],kind:"gaussian_splat",format:"ply"|"splat",sha256,provenance,reconstructionTool,reconstructionVersion?,lineageStatus:"declared"|"verified",qualityStatus:"needs_review"|"accepted"|"rejected",dualUseStatus:"not_evaluated"|"partial"|"accepted"|"rejected"}`. No fabricated camera poses, collision geometry or dual-use claims.

## Quest IDs / rewards

`first_light` → lobby; `rest_stop` → rest; `connecting_paths` → road; `green_corner` → green; `reading_nook` → reading; `market_stall` → stall; `repair_view` → road (requires own parent session). Pure building/celebration quests entirely local; six scan quests optional according to progression. App can grant free starter entrance, post, roads and pure-building rewards separately, marked virtual.

## Native modular boundaries

- Root owns Xcode project/config, scripts/docs, final integration. Source target recursively includes `ios/PocketWorld/`.
- UI/game agent owns app entry, models, API client, game rules/store, UI except Camera/Viewer modules. API client exposes native file uploads, retries, Keychain auth, offline saves, events. All Swift source Swift 5 mode to avoid new concurrency migration errors; deployment iOS18.
- Capture/viewer agent owns `ios/PocketWorld/Capture/*` and `ios/PocketWorld/Viewer/*` only, plus its integration doc and upstream attribution.
- Capture API: `NativeCaptureView(onSaved: @escaping (CapturedVideo) -> Void, onCancel: @escaping () -> Void)`; `CapturedVideo` with `url: URL`, `previewURL: URL?`, `capturedAt: Date`, `durationSeconds: Double`, `width: Int`, `height: Int`, `fps: Double`. Raw video stored in Application Support/Captures, no audio. Caller persists URL and presents preview using VideoPlayer. Three guide steps user-confirmed; no fictitious AR/quality detection.
- Viewer API: `GaussianSceneView(url: URL)` SwiftUI View, own loading/error, orbit/pinch/reset. Local authenticated-downloaded file, PLY/.splat, MetalSplatter pinned exact upstream revision determined by viewer agent. No WebView or fake renderer fallback. Release GPU on dismissal.
- App name 口袋世界; colors warm cream, forest green, apricot. Native small-town cards, grid and NPC wishes. Not data annotation UI. Display processing/source/quality honestly on detail screen.

## Admin

Backend implementer defines authenticated admin endpoints and CLI in `server/` plus README. Must list jobs, export source bundle into folder (manifest, video if any, preview, events, processing), start/fail/requeue job, import parsed model with tool/version, separately record quality/lineage review, export events/metrics. No fabricated ready based on timer. Real data export only, generated tests explicitly fixtures. Admin CLI reads local config, never print secret in normal output.

2026-10-26 worker concurrency clarification: `PUT /v1/admin/jobs/:id/status` accepts optional `expectedStatus`; a mismatch returns 409 `job_status_conflict` inside the session lock. A cancelled job can only remain cancelled or be explicitly requeued. Asset import into a cancelled job returns 409 `job_cancelled`. Deletion, status updates and imports share the session lock, so a late worker cannot revive a cancelled/deleted record. A ready result still requires an actual validated asset. The existing `provider:manual` job field remains compatible; the imported asset records the actual reconstruction tool/version separately.

## Additive v2 notes (2026-11-06)

All additive; v1 and the existing v2 routes are unchanged.

- `GET /health` may include `features: [string]`. Clients treat a missing field as no optional features. Current values: `resumable-rgb-upload`, `arkit-prior-training`, `arkit-keyframes` (2026-11-09), `reconstruction-selection`, `gpu-admission` (2026-11-10, deployed).
- Resumable original video for a native capture (single-request `PUT /v2/captures/:id/rgb` remains supported):
  - `POST /v2/captures/:id/rgb-upload` `{sha256, byteSize, mime: video/quicktime|video/mp4}` → `{upload:{sha256,byteSize,mime,offset,complete:false}}`, or `{upload:{…,complete:true}, capture}` when the video is already stored. Re-declaring the same file returns the current offset; a different file replaces partial bytes. Must match the manifest's `videoSHA256` when metadata is already uploaded.
  - `PATCH /v2/captures/:id/rgb-upload`, `Content-Type: application/offset+octet-stream`, `Upload-Offset: <server offset>` → `{upload}`; bytes received before a dropped connection or request timeout are kept. A wrong offset is 409 `offset_mismatch`; bytes beyond the declared size 413. When the last byte arrives the server verifies the complete file's SHA-256 (422 `hash_mismatch` discards the upload), applies the same container and manifest checks as the PUT, and returns `{upload:{…,complete:true}, capture}`.
  - `GET /v2/captures/:id/rgb-upload` → `{upload|null}` (and `capture` once stored). Deleting the capture stops and removes an in-flight upload.
- Keyframe pack for the ARKit branch (2026-11-09, feature `arkit-keyframes`): `/v2/captures/:id/keyframes-upload` uses the same resumable protocol as `rgb-upload` (GET status, POST `{sha256, byteSize, mime:"application/x-pocketworld-keyframes"}`, PATCH with `Upload-Offset`), allowed only after the capture is verified, stored once (a different pack → 409 `keyframes_conflict`) and deleted with the capture. Format: `PWPACK01`, uint32 LE index length, index JSON `{version:1, captureId, files:[{path, byteSize, sha256}]}`, then the files in index order: `transforms.json` (nerfstudio subset, 8–64 frames, `images/image_NNNNNN.jpg` in time order), optional `meta.json`, the JPEG keyframes and, for person scans, `masks/image_NNNNNN.png` for all keyframes or none (white = person). Every keyframe must match a normally tracked frame of the verified `framesJSONL` (ARKit timestamp within 1 µs, camera-to-world within 1e-3), otherwise 422 `keyframe_not_in_capture`; no depth is uploaded (the Hub has no depth input). Capture status gains `keyframes:{sha256, byteSize, frameCount, masks, mode}`. `POST …/reconstructions/arkit-prior` accepts optional `keyframesSha256` (must equal the stored pack, else 409 `keyframes_required`); the task then carries `input:{keyframes:{…}}`, a retry keeps it, and the worker uploads those keyframes to the Hub instead of video frames, with the same per-image ARKit pose prior and, when present, a `white_keep` mask asset (`POST /api/3dgs/assets/masks`, attached via `masks_asset_id`; the Hub applies masks in COLMAP preparation and gsplat training). Result provenance adds `inputFrames:"phone_keyframes"`, `keyframesSha256`, `masksAssetId`. Not yet run against the real Hub.
- Cloud training from the capture's own ARKit poses: `POST /v2/captures/:id/reconstructions/arkit-prior` `{consentVersion:"2026-11-05-native-arkit-prior-v1", id:<client UUID>}` → `{reconstruction}` with an optional third task `{role:"arkit", algorithm:"gs_mcmc_arkit_prior"}` (PLY, SH3). Requires an existing native reconstruction (it may have zero other tasks) and device-reported ARKit poses; idempotent per reconstruction; retried through the generic `/v2/video-reconstructions/:id/retry`. The worker runs the Hub's own `gs_mcmc` with an uploaded camera-position prior (COLMAP `pose_prior_mapper`: soft priors + BA, not fixed poses) and publishes only if the Hub reports `use_pose_prior: true`. Prior file (verified against the Hub's own `pose_priors.py` parser on the A10): CSV header `image_name,camera_id,timestamp_ns,center_x,center_y,center_z,qw,qx,qy,qz,position_std_m`, exactly one row per project photo (`image_000001.jpg`…), world-from-OpenCV-camera quaternion, `position_std_m` 0.1 for normal tracking and 1.0 for limited tracking. Deployed to the A10 on 2026-11-06 (release `20261106-a10-b8ad2e41c1c2`, Hub-path helper fix `20261106-a10-9ed5d0ec04fe`). The first real ARKit-prior Hub run reported `use_pose_prior: true`; delivery of its result to the app is pending a retry after the helper fix.


## Native version selection (2026-11-10; deployed)

`POST /v2/captures/:id/reconstructions` still requires `consentVersion: "2026-11-03-native-dual-v1"`. Optional `roles` lists `preview` and/or `refined`, each once. An omitted field keeps the old dual-start behavior for new reconstructions; an existing reconstruction is returned unchanged. With an explicit list, only missing requested roles are added. Existing ready/failed tasks are never replaced or automatically retried. A repeated choice is idempotent. Invalid lists return 422 `invalid_reconstruction_roles`; the response is 201 when a reconstruction/task was created, otherwise 200.

`roles: []` creates an empty native reconstruction with `status: "idle"` and `tasks: []`. This allows `/reconstructions/arkit-prior` to run as the sole version. External video dual reconstruction is unchanged. Clients must check `reconstruction-selection` before sending a subset or empty list to an older server, which would otherwise ignore it and run both algorithms.

The app uploads/verifies without starting reconstruction. Each generation choice is persisted before POST, replayed after a lost response and cleared only after all requested roles are returned. Unselected cloud generation is disabled when the feature is absent. Historical previously consented dual requests remain recoverable. Failed-branch retry remains explicit.

Terminal provider reports may map to safe public error codes `gpu_memory_unavailable` or `provider_cancelled`. Only fixed messages cross to the app; private provider reports and credentials are not exposed. These remain terminal failed attempts and require an explicit retry; historical failure rows are not rewritten by deployment.


## GPU admission (2026-11-10)

With `gpuAdmission` configured, native version generation, ARKit generation and failed-task retries check fresh hardware telemetry before creating any GPU task. Not enough eligible free memory (current deployed threshold 20,000 MiB), missing/stale telemetry, or insufficient capacity after queued requests returns HTTP 503 `{error:{code:"server_busy",message:"服务器繁忙中，请稍后重试。"}}`. Idempotent requests for already-created versions return their existing state even while busy. `roles: []` does not consume GPU capacity. Existing source files and failed attempts remain unchanged on refusal. Clients discard the rejected submission intent and require another explicit user action; unknown network outcomes retain their prior idempotent recovery behavior.

Telemetry is produced every ~2 seconds by `pocketworld-gpu-snapshot.timer` with read-only nvidia-smi queries into `/run/pocketworld-gpu/status.json`. The API keeps PrivateDevices isolation. This is an admission check, not an exclusive GPU reservation; the executor rechecks and acquires its own GPU lease. The reviewed dynamic-FF update is active, and the temporary preview affinity has been removed. The dedicated single-image executor is also dynamic; its threshold is 7,000 MiB (see below).

## AgeScan integration additions (2026-11-10)

All jobs remain opt-in. The main cloud entries are quick FF, this application's independent SfM, and single-image TripoSplat. ARKit-prior and on-device results remain separate. Selecting an image or uploading a scan never creates a GPU job.

### Keyframe files (`keyframe-files`)

For a verified native capture, `POST /v2/captures/:id/keyframe-files` declares `{sha256,byteSize,indexBase64}`. `indexBase64` preserves the exact PWPACK01 index JSON bytes. The immutable per-capture manifest permits only the paths, counts and bounds accepted by the existing keyframe-pack contract. The response lists completed file hashes. Each `/v2/captures/:id/keyframe-files/files/:sha256` supports GET status, POST declaration and PATCH at `Upload-Offset` (same resumable protocol, MIME `application/octet-stream`). Identical completed files are not retransmitted; partial files resume. `POST .../keyframe-files/commit` reconstructs the original PWPACK01 bytes, verifies the pack hash and every photo/pose against the verified frame table, then publishes the capture's keyframe metadata. Repeated commit is idempotent. Capture deletion removes its files and upload state. The iOS app uses this route when advertised and falls back to the existing single-pack upload otherwise. Pause stops transfer; only an explicit generation choice starts training.

### Mobile derivatives and SfM verification

A native result may add `mobile:{format:"spz",shDegree,pointCount,byteSize,sha256,filePath,originalSha256,lossy:true}`. It is authenticated through the matching result's `/mobile` route. The original format/hash and cameras are unchanged. The app validates the derivative binding, hash and size, then uses the existing SplatIO reader; verified cached bytes can be reopened offline. Original PLY remains separately downloadable and exportable. Current conversion applies to new SfM/ARKit-prior and single-image results; FF retains its existing full-count `.splat` derivative, and older results are not rewritten.

SPZ v3 is bounded and parsed before publication; point count and SH degree must match. The converter uses RDF readback so the existing iOS reader preserves the original coordinates. It retains SH3 bands but is explicitly lossy; source PLY is never overwritten. Eight-bit SH quantization bounds coefficient error at 0.02; default 5/4-bit truncation is not used. A CPU round trip and a synthetic Linux-to-iOS reader fixture check coordinates, color, rotation, opacity and all SH bands. Compression performance and visual quality on a real scan remain device acceptance work.

Before native SfM/ARKit publication: registered camera ratio >= 60%, >= 4 normally tracked matches, adequate baseline (RMS >= 2.5 cm), similarity-fit center disagreement <= 0.5, residual <= 15 cm, median orientation disagreement <= 25 degrees. Failure yields `sfm_quality_insufficient`, with an explicit user choice to try a different method; it does not silently become another algorithm. These checks compare device-reported poses and do not certify metric accuracy. External videos have no fabricated ARKit reference.

### Single-image generation (`single-image-generation`)

Separate authenticated lineage and storage; no native capture receipt or growth grant:

- `POST /v2/image-generations` `{id,sha256,byteSize,consentVersion:"2026-11-10-single-image-v1"}` registers an immutable JPEG (<=20 MiB), creates no GPU job. Repeated identical requests return the same item.
- `GET /v2/image-generations` and `GET /v2/image-generations/:id` return only the caller's items.
- `/:id/image-upload` supports GET/POST/PATCH resumable JPEG upload with whole-file SHA-256 verification.
- `POST /:id/start` `{id:<attempt UUID>,consentVersion}` performs GPU admission first, then persists the explicit attempt. Lost provider responses reuse the same upstream idempotency key. Busy (503/server_busy) leaves the uploaded image without a queued job. Retrying a failed/cancelled attempt is explicit and preserves the prior attempt record.
- `POST /:id/cancel` stops the exact requested job; cancellation before provider submission never submits it. Intermediate state `cancelling` persists until confirmed.
- `DELETE /:id` requires a terminal item and removes its private source/results, including only its own COS prefix. Active items must be cancelled first.
- `/:id/result/ply` and `/spz` require ownership and ready state; no public object URLs or credentials reach the phone.

States: draft/uploaded/queued/processing/cancelling/cancelled/failed/ready. Ready requires a validated real PLY and SPZ, matched point count and hash manifests. Result provenance is always `ai_single_image`, algorithm `triposplat`, source image hash, `metricScaleVerified:false`. A bounded optional predicted `viewHint` only initializes presentation; it is never recorded calibration or an observed camera path. iOS strips EXIF/GPS and normalizes orientation before explicit upload. The result opens the interactive native viewer; video export remains optional.

Deployment uses a dedicated PocketWorld helper and Python environment. Since release `20261110-a10-e2d0aab11b1e`, single-image requests go to the private `pocketworld-triposplat` executor at localhost:18782, with its own key, job database and work directory, using the installed TripoSplat runtime/weights. Shared AgeScan processes/source/config remain unchanged. Native FF, SfM and single-image all select eligible free GPUs; the temporary image affinity is removed.

With `imageGeneration.dynamicGPU:true`, image start checks the API telemetry and the executor's authenticated `/capacity` before persisting a new attempt. The executor independently checks all GPUs at job creation, selects the highest-free eligible GPU (>=7,000 MiB), acquires a per-job lock, and rechecks immediately before model load. Missing/invalid telemetry or inadequate memory returns busy, without waiting for resources or automatically retrying. API refusal is HTTP 503 `server_busy`; a later resource race becomes an explicit failed/busy attempt. Existing attempt idempotency remains valid even while busy. Model subprocesses are stopped after each job to release memory. Admission and private locks do not reserve resources against unrelated services. Real image generation through this executor still needs end-to-end acceptance; verification used synthetic tests and read-only probes, with zero GPU jobs submitted.


## Single-image result recovery (2026-11-10, deployed)

Feature `single-image-result-recovery` adds authenticated `POST /v2/image-generations/:id/retry-delivery` with `{}`. A failed `invalid_result` having a saved provider ID/attempt may return to processing, retaining both IDs. Ready and pending responses are idempotent; other states return 409 `delivery_unavailable`. Ownership remains mandatory. No admission or new GPU job is invoked; the adapter fetches the existing provider job. Other failures still require explicit generation retry.

TripoSplat's binary float PLY sometimes contains +/-Infinity ONLY in opacity logits (sigmoid endpoints 1/0). The image-specific adapter saturates these to +/-20 (alpha error < 2.1e-9), preserving all geometry, color and other finite values. NaNs and nonfinite geometry/scales/rotation remain rejected. The untouched provider PLY is retained privately as `model.ply.provider-original`; publication hashes the finite derivative. Optional result `normalization` records kind, changed count, bound, max alpha error and provider SHA-256. Strict Gaussian/SPZ validation still runs before ready. This policy is isolated to single-image outputs; native reconstruction validation is unchanged.

Deployed as `20261110-a10-cdd41ad00193` with 163 server tests passing. The existing failed image was recovered through its same provider/attempt, with no new GPU job, and now has validated ready PLY/SPZ. API-only restart; shared services unchanged. End-to-end visual inspection on the phone remains pending.

## Subject-keyframe SfM extension (2026-11-11, deployed 8c74beee3e88)

Feature `sfm-subject-keyframes` allows `keyframesSha256` on a native reconstruction POST whose explicit `roles` includes `refined`. The pack must already be verified, have one white-keep mask per image and belong to this capture. Only the refined task stores the pack binding; preview retains its original video source. SfM estimates cameras independently (`use_pose_prior:false`), with no ARKit pose-prior upload. The recorded poses only verify input lineage and locate the user-selected subject for phone-side segmentation.

A user-approved retry of a failed native refined task may explicitly supply `keyframesSha256` to bind its first subject pack. The previous attempt is archived unchanged; the replacement gets a new ID, algorithm remains `gs_mcmc`, and existing ready results are immutable. A task that already has a pack cannot change it. Replays with conflicting input hashes fail. Missing/invalid masks do not silently revert to full-frame training. Other existing routes and unmasked requests retain their behavior.
