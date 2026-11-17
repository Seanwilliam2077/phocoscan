# phocoscan existing-scan acceptance — 2026-11-11

Device: paired iPhone 16 Pro Max. Scope: use existing scans to verify independent reconstruction choices, correct result viewing and source assessment; add convenient deletion. Real generation is explicitly authorized for this acceptance. Existing user material is not deleted.

## Existing source inventory

17 scan folders were inspected in place on the phone. Every present keyframe package's actual image count matches `analysis.keyframeCount`; all indexed JPEGs exist. Old scans without keyframe packages remain unknown rather than reporting zero frames or complete coverage.

| Scan | Keyframes | Recorded coverage reference | Outcome |
| --- | ---: | ---: | --- |
| 15 | 228 | 72% | Existing quick/high-quality results; new local and scan-linked single-image results |
| 16 | 107 | 63% | Selected for sequential, independently requested cloud generation |
| 18 | 1 | 2% | Local training now disabled with the actual insufficient-input reason |

Coverage is a pose-derived capture heuristic, not measured geometric completeness or reconstruction quality. A ready reconstruction does not upgrade the source assessment.

## Real phone results

- Production SwiftUI viewer: quick → high-quality → quick → high-quality. All four transitions reported the selected result's Metal first frame. This is an attended test host driving the same selection state as the production picker, not a physical-tap UI test.
- Scan 15 quick result `cd02a8f2-1ba1-47b3-958a-9eec3d0d36b9` and high-quality result `743254a1-ee38-4008-b7e5-aad6b482a542` have distinct identifiers/hashes and rendered on the phone.
- Scan 15 local generation completed 3,000 steps in 80 seconds, exported 66,818 Gaussians, and rendered through the production Metal renderer.
- Scan-linked single-image generation `68e7d6db-5121-45ca-9a9f-f372607a0fb9` completed and rendered through the production Metal renderer. It uses a subject image selected from the existing scan.
- Both original cloud task IDs remained unchanged after local/single-image generation. The new results remain available in the app.
- Scan 16: quick-only submission verified. Quick task `334c9736-38dc-436c-aa55-3f1c300e7322` completed and rendered before high-quality task `77ca7a32-a4c1-407c-86ab-f88592bc3e5d` was requested. No ARKit branch started, and the existing quick result was preserved. High-quality submission worked, but its new result did **not** complete delivery: see the failure below.

## Real high-quality failure — do not mark ready

The independent SfM task on scan 16 registered 47 images and completed 7,000 MCMC steps (128,320 Gaussians). Its provider then exited with code 1 during PLY export validation: `bbox_vs_colmap_points: FAIL`. Header, point count, transform round-trip and unnormalization checks passed. The percentile bounding-box spans of the exported Gaussians were approximately 4.6× / 15.0× / 5.2× those of the COLMAP point cloud along x/y/z. This establishes why the provider rejected the export; it does not by itself establish whether the capture, optimisation or validation threshold is the underlying cause.

The phone correctly retained the task as failed, separately from the ready quick result. No automatic retry, forced ready state, validation bypass or replacement with another algorithm was performed. Existing scan 15 high-quality viewing is verified; fresh high-quality generation on scan 16 remains an open reconstruction-quality/export issue.

Read-only server evidence: project `PocketWorld-SfM-57a46b3b691d4fb682e9`, step `dbe679537271`, `logs/dbe679537271.log` and `3DGS/dbe679537271/output/gs_mcmc/point_cloud/iteration_7000/export_check.json` under the Hub data project directory. These files remain on the server.

The render checks verify readable output, actual visible pixels and correct result identity. They do not certify visual quality, unseen surfaces or geometric accuracy.

## Deletion and fixes

- Library long-press → Delete, or Manage → select items/current list → confirmed Delete. Active work is excluded; state is checked again before deletion.
- Deleting a scan also handles its current-account linked single-image work and cloud copy before removing the original local folder. Remote failures preserve the original scan for retry. A multi-item operation can partially succeed; failed items stay available.
- Regression fixtures verify remote failure retains local image bytes/index, an already-deleted remote response is retryable as success, and a late response from another screen cannot resurrect a deleted entry. No real user scan was used for destructive verification.
- Local input preflight requires at least eight keyframes, present selected images and the point-cloud file. Scan 18's one-frame package no longer offers a training operation that cannot run.
- Renderer status publication is deferred out of SwiftUI view creation/update, eliminating the warnings observed during the real viewer check.

## Verification evidence

- Simulator: 187 tests executed, 173 passed, 14 opt-in/environment-dependent skips, zero failures.
- Phone production viewer switching: passed, 6.151 seconds.
- Phone four-result generation/render check: passed, 99.333 seconds (single-image generation had completed in the earlier foreground-interrupted attempt; the successful run reused that result).
- New cloud selection check: intentionally fails acceptance when the high-quality provider fails. Quick-only submission and later independent high-quality submission were observed; no claim that all four newly generated branches succeeded.
- Normal signed app build succeeded, installed successfully and launched on the paired iPhone. No Swift/Metal source is newer than the installed binary, and no XCTest plug-ins remain in the normal app. Install log: `/private/tmp/pw-acceptance-install.log`.

Local text logs: `/private/tmp/pw-phone-inventory-actual.log`, `/private/tmp/pw-real-switch-active.log`, `/private/tmp/pw-real-four-stable.log`, `/private/tmp/pw-real-cloud-selection.log`, `/private/tmp/pw-acceptance-final-simulator.log`.

No source footage was copied to the Mac for inspection; scan 16 was uploaded through the normal app flow for the explicitly requested cloud acceptance. Known temporary device diagnostic/result bundles and opt-in xctestrun files were removed after acceptance. No server code, service restart, Hub configuration or GPU assignment changed in this acceptance.


Follow-up: the explicitly requested scan-16 repair completed, including fresh masked independent SfM, unchanged export-range gate, real-phone viewing/switching and preservation of the original quick result. See [scan-16 repair evidence](SCAN16-HIGH-QUALITY-REPAIR-2026-11-11.md). The earlier failure above is retained as historical evidence.
