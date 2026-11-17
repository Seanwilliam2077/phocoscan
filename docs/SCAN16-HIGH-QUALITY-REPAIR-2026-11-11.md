# Scan 16: high-quality export range investigation

Status: repaired production retry succeeded; real iPhone rendered both results and verified quick preservation. Production viewer switching and final normal install passed.

## Preserved baseline

Capture `cb1630fe-59f5-41d4-96b9-4d03a9ac1118`; failed high-quality attempt `77ca7a32-a4c1-407c-86ab-f88592bc3e5d`, Hub step `dbe679537271`. Ready quick task `334c9736-38dc-436c-aa55-3f1c300e7322` was not rerun or replaced. Its file SHA-256 was independently checked against the stored manifest before work: `c9f04a87c302554fd85f25e6a7711b6c5738d5aefd71772f58113b8fc9ebf2dc`.

## Diagnosis

47/64 cameras registered with 5,660 sparse points; median stored reprojection error 0.864 px. Camera alignment against the independently recorded phone poses had 7.3 mm residual and 0.47° rotation error (a consistency check, not metric accuracy certification). The normalization transform round-trip error was 2.36e-7.

The original 128,320 Gaussians had a characteristic 1–99 percentile extent ratio of 7.0846 relative to COLMAP points, outside the unchanged 0.5–2.0 gate. Filtering low opacity did not resolve it (even opacity >=0.5 remained oversized). This was genuine optimized geometry expansion, not simply a unit conversion error.

Isolated same-capture controls preserved original files and used a checked idle GPU:

- Scaling densification timing to 7,000 steps: still failed; extent ratio 22.51.
- Disabling MCMC noise: still failed; extent ratio 2.77.
- Adding sparse SfM depth loss: still failed.
- Selecting the recorded anchored foreground in every registered image with Apple Vision, retaining the same images, camera model, 7,000-step MCMC preset and export gate: all original checks passed; extent ratio 0.54976, 128,320 Gaussians. No output clipping or threshold relaxation. Visual inspection of an actual held-out render confirmed the selected plush is reconstructed; masked image metrics include zeroed background and must not be directly compared to the unmasked whole-image scores.

This isolates full-frame optimization of the weakly textured white background as the dominant cause for this subject capture. It does not establish that every unmasked scene will fail or that a range pass proves geometry accuracy.

## Production change

Anchored object/person high-quality requests can upload a full-size, sensor-oriented subject-mask keyframe pack. The phone projects the recorded user-selected anchor to choose an instance; it never silently chooses another instance. An unavailable subject fails preparation. Input pixels/intrinsics are not cropped or rotated. Cache verified pack bytes for replay. Server binds the exact pack hash only to high quality; independent SfM still estimates cameras with no phone pose prior. Quick inputs remain unchanged.

An explicit retry can upgrade a failed unmasked native high-quality attempt with its first verified subject pack. Preserve the archived failed attempt and its original inputs; a task with an existing pack cannot change it. Verify hashes/ownership/role and preserve ready results. This is a new training attempt, not promotion of a diagnostic output.

The exporter also had an unrelated invalid heuristic: normalized coordinates had to fail the world-space extent heuristic before inverse normalization was accepted. App-owned `PocketWorld-SfM-*` exports now read the actual written PLY and compare transformed means, scales, rotations, opacity and SH attributes against the checkpoint. Original bbox gate remains mandatory. Other Hub projects retain their previous decision path; no Hub service was restarted.

## Checks and deployment

- Node: 167 passed locally and in the deployed release as `pocketworld`.
- Simulator: 190 executed; 174 passed, 16 explicit/real-device gates skipped, zero failures.
- Export verification: six CPU tests passed, including corrupted geometry/appearance, identity scale, quaternion-sign equivalence and scope isolation.
- Renewed profile trusted on the iPhone. Real-phone subject preparation passed: 64 masked keyframes, 24,773,641 bytes, pack SHA-256 `3790c4b54ffa5267cde5f8e7dc43a70ab683eb747496cfb4d022d4198f8fb1f5`. The app submitted replacement `ccbf6b97-7bb9-4a85-8be7-7e4cac40600a`, Hub project `cdca2150a61b`, step `4c8bbd6b97f7`. Hub confirms 64/64 masks and `use_pose_prior:false`. Viewing acceptance completed below.
- Release `20261111-a10-8c74beee3e88` installed and API/worker restarted after confirming no queued/running reconstruction. `/health` advertises `sfm-subject-keyframes`.
- Rollback app release: `20261110-a10-cdd41ad00193`. Export script backup: `100_gs_mcmc_ckpt_to_3dgs_ply.py.before-phocoscan-20261111-a10-8c74beee3e88`. No GPU pinning added.

Text evidence: `/private/tmp/pw-scan16-fix/` (server/simulator/export logs, diagnostic parameter scripts). Temporary private inspection media must be removed after acceptance; originals stay untouched.

## Additional phone-side input bug found during acceptance

`ScanSubjectPhoto.candidates` conditionally cast JSON pose numbers directly to `[[Float]]`. Foundation rejects decimal values not exactly representable by Float, silently excluding 44 of this scan's 107 valid keyframes. Decode `Double`, validate, then explicitly convert for SIMD. The real phone now reads all 107. Training mask selection also uses the visible anchor seed rather than the single-image picker's whole-object framing rule, so legitimate close detail views remain eligible. Two synthetic regressions cover non-exact decimal poses and close-up/offscreen seeds; the targeted capture/pack suite passed 12/12. Neither fix fabricates missing poses or changes recorded source files.

## Production retry acceptance

New high-quality task `ccbf6b97-7bb9-4a85-8be7-7e4cac40600a` finished and was published as ready. Fresh independent SfM registered 61/64 images with 10,995 points and median reprojection error 0.741 px. It trained 249,464 Gaussians for 7,000 steps; original export extent ratio **1.07697** (allowed 0.5–2.0), all original gates passed. Direct written/checkpoint mean error <=2.11e-6; all scale/rotation/opacity/SH checks passed. No points clipped to force range acceptance.

Real iPhone `testScan16HighQualityRepairPreservesQuick` passed: new high-quality renderer produced 46,580 non-background pixels and original quick produced 48,627 at the test viewport. Both were loaded through production preparation and Metal rendering. Original quick ID, file hash and camera hash remained unchanged; only preview/refined tasks exist. This proves delivery/rendering/identity, not metrology or universal visual quality. Log: `/private/tmp/pw-scan16-fix/phone-repair.log`.

## Viewer framing issue discovered by visual inspection

The first real-screen check showed correct result IDs but an over-close, sideways initial view. The legacy orbit used half the **camera travel** bounding-box diagonal as a subject-distance limit and assumed the SfM model's Y-axis was gravity; neither holds for short-arc arbitrary-coordinate reconstruction. The viewer now uses the already-validated scan/model alignment for gravity and the recorded anchored region for a conservative fitted orbit sphere. Only the view matrix changes; no result coordinates, cameras or SH attributes are rewritten. Angular guidance is computed in that aligned view frame; legacy numerical orbit-limit calculations remain unchanged for other inputs. The Metal viewport reserves the actual bottom-sheet height. A mathematical regression covers upright gravity and fitting all subject-box corners in portrait/landscape viewports. Final actual-screen check passed: subject is upright and fully visible above the sheet. Surrounding haze/floaters remain; delivery/rendering success is not a claim of clean reconstruction quality.


Final iPhone check: production quick→high→quick→high selection reported each exact result ID after its Metal first frame; the final screenshot was visually inspected. The app was then built normally (no XCTest plug-ins), installed and launched successfully, with no newer Swift/Metal source. Final real-phone UI plus orbit-math tests: 2/2; focused simulator viewer/crop/orbit/Live Photo checks: 17/17. Final model SHA-256 `5eb3eebb36adac7d8a0c4391da5bc1337691f9d87328bb3c7517241263784f84`; quick on-disk SHA remained the baseline. Logs: `phone-viewer-framing.log`, `normal-build.log`, `normal-install.log`, `normal-launch.log` in the evidence directory. Temporary screenshots, input copies and private test-result bundles were deleted. User scan files and both production results remain.
