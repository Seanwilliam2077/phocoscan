# WeChat miniprogram migration · active contract

2026-10-26 user-approved override: the active home is a single-plant farm demo. Three distinct accepted native RGB session receipts unlock plant, water and harvest; only the corresponding explicit user interaction advances the persisted farm stage (0/1/2/3). `lib/farm.js` derives eligibility from actual matching receipts and maintains `state.farm` within the existing schema-2 save. External model receipts and local drafts do not qualify. Plant/harvest support drag plus accessible tap; watering requires a deliberate hold, cancelled on hide/unload/touchcancel. Deleted source sessions retain already-earned virtual progress but never deleted footage. The prior `companion.js` 0/1/3/6 derivation remains historical and is no longer the active home progression. See FARM-DEMO.md.

2026-10-26 capture clarification: collect overlapping sequential views of the same static corner without requiring a complete orbit. Player-driven guide steps are instruction events only, not coverage/pose/quality measurements. Persist native video bytes before metadata inspection. Pending metadata stays locally playable and recoverable; it blocks submission until real duration and dimensions are available. No guesses from timer or camera resolution settings. The original source video remains the future common input to video and reconstruction pipelines, each requiring its own acceptance checks.

2026-10-23 local-first capture: native preflight calls `startLocalSession(...)` without connecting to the backend. A device-only envelope is explicitly marked `localOnly:true` and carries its fixed `creationRequest`, profile binding and optional `registrationAttemptedAt`. It has no invented user/scene/asset/reward. Real files persist with the same ID; explicit submission first connects, registers the same request, uploads and then applies the actual server reward. Local drafts survive refresh/cloud restore but are excluded from remote backups and server event references until registered. Pure local deletion needs no network; ambiguous registration requires confirmation. App resume does not automatically contact the backend. External model import retains the server-backed creation path.

Latest user clarification: scanning remains the data objective and a simple casual companion game is the motivation carrier. Active home now has 小芽, one unlocked wish, one scan action. lib/companion.js derives 0/1/3/6 growth from deduplicated grantedRewardIds; drafts and petting grant no growth; deletion retains virtual receipt progress. Session acknowledgement requires a matching real server reward. No map/grid/shop/currencies reintroduced. See docs/COMPANION-MVP.md.

Latest UX override: minimal capture UI, no tabBar/onboarding/town-building in active player flow. Home routes with navigateTo; return-home uses reLaunch. Preflight creates a real first_light-compatible session only after explicit consent; camera returns to that same session preview. Backend game/reward storage remains compatible but is not shown as a required player step. Old visual contracts below are historical where they conflict with this override.

2026-10-22 user explicitly selected Windows development + iPhone WeChat QR testing. This supersedes the initial SwiftUI-only platform decision. Preserve ios/ and old reports as historical; active player is miniprogram/ (WXML, WXSS, JS), no HTML/web-view.

## Shared interfaces / ownership

- Root owns project.config.json at project root, tool installation/configuration, scripts/docs, final integration/DevTools QA.
- Game agent owns miniprogram/** except lib/splat-renderer.js and pages/viewer/**; owns miniprogram-tests/game.test.cjs and API/store tests. Runtime CommonJS, native WeChat APIs, Chinese warm cream/forest/apricot UI. No frameworks/npm player bundles required.
- Viewer agent owns lib/splat-renderer.js, pages/viewer/viewer.{js,wxml,wxss,json}, miniprogram-tests/viewer.test.cjs. Native `canvas type="webgl"`, actual projected anisotropic Gaussian ellipses, touch orbit/zoom/reset, lifecycle cleanup. No fake/sample model as own capture. Backend derivative default60k cap100k for first-device profiling, not raw data quality.
- Backend agent owns server/** and tests; preserve old raw PUT API. Only same user's assets downloadable. Independent admin auth. No automated reconstruction.

## JS API for viewer and game

`require('../../lib/api')` path varies by module. Exports:

- `get(path)`, `post(path,body)`, `put(path,body)` return decoded JSON.
- `upload(path,filePath,options?)` sends wx.uploadFile POST multipart with one file field named `file`; parses JSON/error, no whole-video ArrayBuffer.
- `download(path,destFile)` resolves actual local file path string; authorized request, status checked.
- `getConnection()` returns `{baseURL,token,userId}` or not-connected equivalent, never admin token.

Store exports `log(name,{sessionId?,assetId?,questId?,properties?})`, optional `flushEvents()`. Viewer page query `assetId` and `sessionId`, validates identifiers, downloads `/v1/assets/:id/viewer` and removes transient viewer file on unload. Log `result_viewed` only after real GL draw succeeds, with device validation still separate.

## Backend extensions

- POST multipart aliases `/v1/sessions/:id/video`, `/preview`, `/asset?format=ply&tool=ActualTool` → same response as PUT. One part named file; limits/auth/idempotency unchanged.
- Submit accepts `fps:null,fpsSource:"unknown"` when WeChat exposes no trustworthy fps, and `audioPolicy:"may_contain_audio"` by default for WeChat recording. Do not fabricate fps/poses/silent audio. Capture duration/width/height via actual video metadata; tutorial instructions are not quality scores.
- `GET /v1/assets/:id/viewer-info` → `{format:"splat",sourceAssetId,sourceSha256,pointCount,originalPointCount,lossy:true,rendererOnly:true,sha256,...}`.
- `GET /v1/assets/:id/viewer` → standard32byte .splat derivative, deterministic bounded subsampling/SH0 colors; optional point budget as documented by backend. Original asset remains immutable and separately downloadable. Derivatives removed on session deletion.

## Local data and preview

Keep drafts with exact session IDs in wx.env.USER_DATA_PATH before uploading; use file upload streams. Record upload-attempt lock before sending bytes, preserve original on failure. Durable game state/backup decision, same-server token isolation, idempotent rewards. Use a conservative short capture budget and readable error on filesystem quota/oversize; no unbounded recording/cache accumulation.

WeChat file picker selects conversation files (`wx.chooseMessageFile`), not a universal iOS Files picker. External Scaniverse result can be transferred by the user to their own chat and selected, or imported by operator CLI into the correct session. Never send messages automatically.

Updated 2026-10-22: official DevTools account lookup confirmed mini-program test AppID wx5a552b67412cb448 (isGameType:false), now configured. User's initial wx0e4b7e4f26503e04 was the separate mini-game test account and is not used. Login and official CLI preview succeeded at 18:05 Asia/Shanghai; fresh QR is in runtime/wechat-preview.png. A preview QR does not prove phone camera/GPU/network validation. Local Wi-Fi debug may need phone's development debug setting; a production build needs authorized HTTPS domains and platform privacy declarations. No unrequested cloud provisioning or public raw-data tunnel. No AppSecret is used or stored in this project.
