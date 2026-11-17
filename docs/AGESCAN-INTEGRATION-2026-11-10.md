# AgeScan integration into phocoscan

Latest user request: implement all comparison items in priority order. Main cloud choices: feedforward quick reconstruction, this app's SfM high-quality reconstruction, AgeScan TripoSplat single-image generation. Preserve historical ARKit/on-device results under more options. All creation remains explicit; no automatic jobs or silent algorithm fallback. One native app, minimal UI.

Implementation checklist:
- [x] P0 saved-keyframe coverage, mode-specific guidance; keep live pose warnings separate.
- [x] P0 stage-specific recovery actions, download-only retry, retained results.
- [x] P0 interactive result first (previous turn, installed).
- [x] P1 SPZ derivative + verified offline caching, original PLY/SH retained.
- [x] P1 SfM registration/alignment quality gates and explicit fallback suggestion.
- [x] P1 per-file resumable keyframe uploads with immutable manifest, pause/resume.
- [x] P2 TripoSplat service adapter, explicit AI provenance, source image selection, results in existing viewer/gallery.
- [x] Main three generation choices; advanced/historical options preserved.
- [x] Server tests, app tests/build, server deploy, health and idempotency checks.
- [x] Install newest build on the iPhone (reconnected/unlocked; devicectl installation and launch succeeded on 2026-11-10).
- [ ] Real object/person/space captures and real single-image generation acceptance.

The existing AgeScan services are shared and must not be replaced or restarted. The original TripoSplat service remains on 127.0.0.1:18082. phocoscan now uses its dedicated dynamic executor on 127.0.0.1:18782, with the same installed runtime/weights and svckit jobs/COS contract but separate state/key/work directory. Service credentials remain on server. No real user media was uploaded or real GPU job submitted during implementation; actual generation remains an explicit per-image action.

The shared alignment task ended; the idle/hash-guarded FF patch was applied on 2026-11-10 after both PocketWorld and Hub became idle. Only `rshub-worker` was restarted for that narrow scheduling change; original files/config are backed up under `pw-release/hub-auto-gpu/backup-1794305949`. Native quick and high-quality select eligible free GPUs. The subsequent dedicated single-image executor also selects dynamically with a 7,000 MiB minimum; its former API affinity is removed. Shared AgeScan units have not been changed or restarted. Full deployment/rollback is in `deploy/a10/image-dynamic/README.md`.


Implementation notes:
- Scan coverage and live LiDAR observation quality update after JPEG persistence; offline review uses the same saved, still keyframes. Pose-only speed/aim hints remain live. Blank/textureless candidates are rejected; saved face checks are bounded and drained before analysis.
- Ready result download failures expose download-only retry; a quality-gate failure preserves its method identity and requires a new explicit choice. No automatic algorithm fallback.
- Keyframe files retain exact immutable PWPACK bytes and capture lineage at commit. The app can pause/resume and skips completed files; the server also verifies ownership and SHA-256.
- Single-image selection is available from the home gallery, from the three-method card and directly from a local scan before uploading its video. Photos are normalized, metadata stripped, then uploaded only on confirmation. Ready cards enter the native interactive viewer; AI provenance and nonmetric scale remain visible.
- Native SfM/ARKit results get optional SPZ v3 derivatives; FF keeps its existing full-count splat derivative. Original PLY remains available. Eight-bit SH quantization is used, with a maximum 0.02 coefficient round-trip error; an incompatible derivative falls back to the original. The original file is not modified.
- Dedicated Python runtime: `/opt/pocketworld/python`, official SPZ 1.1.0 pinned revision `affd0ecea7fbb4c265ee119475af7ee5b2997482`, numpy 2.4.6, cos-python-sdk-v5 1.9.44. Private adapter configuration stays in `/etc/pocketworld/agescan.json`, mode 0600, and is never sent to the app.

Verification: 157 Node tests pass locally and on the A10; ownership, immutable inputs, partial uploads, busy refusal without a task, repeated starts, lost responses, cancellation and invalid results are covered. The adapter's authenticated API and private storage read probe passed as the PocketWorld service user. A four-point synthetic SH3 PLY converted on Linux has maximum position error 0.000118 and SH error 0.003438; its bytes are exercised by the actual iOS SPZ reader test. These are synthetic checks, not a real reconstructed scan or single-image quality claim.

Pending device acceptance: real capture guidance, local/cloud material sufficiency, single-image end-to-end output and cancellation, SPZ visual quality/file size/first-frame/peak-memory comparisons, offline reopening and portrait mask behavior. No real image was submitted or GPU job started for this integration verification. The Mac was locked during UI automation. The first iPhone installation disconnected; after the user reconnected/unlocked it, the latest integration build was installed and launched successfully. Real interactive use has not yet been verified.


Latest server release: `20261110-a10-e2d0aab11b1e` (archive SHA-256 `e2d0aab11b1e56703e95f6a40e45cc347164168908f266a49a951597cd89df3d`), 160/160 tests on the A10 plus four installed-runtime checks. Authenticated dynamic capacity and private-storage probes pass. App simulator: 131 total / 127 passed / 4 conditional skips / 0 failures; actual SPZ reader fixture included. The newest home layout (发现 / ＋ / 我的, creation mode cards, actual counts, source/status filters and date-grouped library) retains phocoscan branding/colors and is installed and launched on the iPhone 16 Pro Max. UI automation cannot access Simulator, so appearance and interaction still need real-device acceptance. No model/GPU job was started by verification.

For the latest dynamic-image change, use the rollback in `deploy/a10/image-dynamic/README.md` (previous release `20261110-a10-dd9692bfde34`, private config backup `/etc/pocketworld/pre-image-dynamic-1794312009`). A deeper rollback of the original AgeScan integration, only when PocketWorld has no active work, uses `20261110-a10-cbd60a900081` with `/etc/pocketworld/api.json.pre-agescan-integration` and `worker.json.pre-agescan-integration`. Keep the independently applied dynamic Hub scheduler unless a separate rollback is required. Added DB tables/columns are additive and need no destructive rollback.
