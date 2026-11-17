# Scan 15 boundary refinement — accepted, 2026-11-13

The reviewed subject derivative is published, the normal phocoscan build is installed, and real-phone viewer acceptance passed. The full model and camera bytes are unchanged; all previous results and original materials are retained. No new training or cloud work was run.

## Actual baseline and lineage

The phone had a newer user-completed result at2026-11-13T06:27:51Z before this check:134,363 full-scene points and43,764 subject points,113 frames768×576. It supersedes the earlier v5 model as the paired baseline.

- Full scene SHA: `4be935361672f3b1d675298e1f2e7339057ee4718df1586b2a36abf69aa380b2` (unchanged).
- Old subject SHA: `ad249387c8bc9206ae8dc145f4b9dea989a4735ef351a84eac645b01bcb5fadb`.
- New subject SHA: `832daedd14b8c50566c7f9823eb3982614acafaf31530fe2e44650878e9690d9`.
- Source digest: `0ddb60b9a90e06a911cff9f5f41ecb01279e4fd1351178b1bd3c40a1a1c9ecb0`.
- Mask digest: `dd618fdafdd53d0aa23d381cbf14e982185f95e2d9a7f3f21470235c330102b6`.
- The entire immediate prior result is byte-identically archived at `ondevice.previous.52EA4395-860D-45D5-B6F6-FC744A41AEFE`.
- Earlier v5 remains in `ondevice.previous.DF89423A-7908-4F73-9F62-33B61218757B`; v4/v3/v2 archives remain too.
- Accepted comparison: `ondevice.boundary.08710B36-293D-4314-B893-242057497EAF`. Explicitly named rejected experiments and matching test temporary caches were removed.

## Implementation

`TrainingSubjectSurface.version=4`. Preserve the conservative shape candidate and prior25% visible-foreground rule. Accumulate read-only evidence in up to32 training views; the14 evaluation views never vote.

1. Directional support: under the same EWA projection, compute each local Gaussian axis's conditional second moment, E[z²|pixel] = 1−aᵀC⁻¹a+(aᵀC⁻¹d)². Weight by actual visible alpha mass inside/outside the soft silhouette, respecting depth order/occlusion and a one-source-pixel margin. Narrow an axis only if foreground variance<.8, background variance>1.1, difference>.4, and both masses>=2; scale factor=max(.85,sqrt(foreground variance)). Supported long axes of fur, unobserved axes and uncertain points stay unchanged.
2. Harmful-tail evidence: reverse-composite the colour behind each point and estimate the foreground L1 change if that point alone disappeared. Require background mass>40%, both masses>=2, and removal cost<−.001 per foreground mass before pruning. No hue/white/yellow/brightness rule. This estimate holds the current contribution list and cutoffs fixed; it is not a promise of identical visibility after simultaneous pruning. The independently exported paired renders remain mandatory.
3. Changes apply only to the separate `subject.ply`. Full model/colours/poses remain intact. Scratch evidence is never checkpointed, trainer buffers/Adam/density/RNG are untouched, resolution restored and target cache invalidated after evidence collection. Pause checks remain active. Fresh training exports get the same refinement; saved checkpoint layout/configuration are unchanged.

## Paired result

Same full model,113 original inputs,14 matching camera views. Actual front/side/rear renders inspected. Colour-based yellow-fur regions are evaluation-only, never extraction inputs. These are automatic-mask metrics on one tuned scan, not manual3D truth or a blind generalization test.

| Metric | Before | Accepted |
| --- | ---: | ---: |
| Subject points | 43,764 | 42,347 |
| Outside-mask visible pixels | 219,883 | 194,053 (-11.75%) |
| Subject recall | .97135716 | .96896819 |
| Subject MAE | .08897540 | .09105188 (+2.33%) |
| Subject PSNR | 16.12081 | 15.92137 |
| Fur recall | .97965833 | .97919831 |
| Fur fine-edge recall | .98153612 | .97856626 (-.297pp) |
| Fur MAE | .06986492 | .07105456 (+1.70%) |

703 shape candidates narrowed;1,628 harmful-tail candidates removed before the opacity cutoff. Extraction/export3.27s, excluding input/mask preparation/evaluation. This is cleaner presentation with a small photo-error/detail tradeoff, not higher PSNR. Some strap/foot white residue remains. An inspected original frame confirms proximity to the white desk; the temporary original-frame copy was deleted immediately afterwards.

All original publication gates stayed unchanged: >10% outside-pixel reduction, subject recall decrease<=2pp, hair/fine-edge recall decrease<=.5pp, subject/hair MAE increase<=3%, source/candidate SHA checks. Directional-only A improved just.59%; B7.7%, C8.7%, D8.8% also failed the original improvement gate and were never published. E passes every gate plus visual review.

## Verification

- iPhone GPU tests:21pass/1 unrelated opt-in skip on complete B/C/D runs. New posterior moments match CPU; strand length and unobserved axes preserved. Counterfactual agrees with actual removal/re-render in a controlled fixture. Evidence leaves checkpoint buffers byte-identical; lifecycle resume/restore/archive checks pass. E combined run was interrupted by CoreDevice, not counted as a clean suite pass; its separate real comparison subsequently passed.
- Mac forward/gradient/SSIM and legacy/growing checkpoint restoration pass. Final simulator220 total:181pass39 gated skips0 failures. No new physical lock-cycle claim.
- Gated publication1/1 passed, verifying prior model/subject/cameras/meta byte identity and unchanged full scene/cameras.
- Normal signed E build installed, no XCTest plug-ins, no production Swift/Metal source newer than the binary.
- Actual normal-app UI1/1 passed in45.7s after a first attempt was interrupted by foreground switching: exact `subject.ply -> scene.ply -> subject.ply`, first/repeated opening, previous archived result -> exact current result, enabled retrain -> confirmation -> cancel. No training confirmed. Screenshot shows the correct penguin with42,335 anchor-cropped visible points.
- Preservation audit:26 selected original source/current/archive files match their preserved locations exactly by SHA+size;10,149 pre-existing non-current-file metadata records unchanged. After UI, all30 selected source/current/archive hashes still match. Original raw-photo/video contents were not copied/rehashed as a whole; file metadata covers those, selected hashes are stronger checks for the critical26/30.
- Temporary UI runner uninstalled. Temporary original image, verification render copies, test attachments/diagnostic bundles and opt-in specs cleaned; text logs/numeric audits retained. User comparison and actual phone screenshot retained intentionally.

## Device-test infrastructure finding

Xcode repeatedly hung/faulted reinstalling test artifacts despite direct devicectl install succeeding. Official local `man xcodebuild.xctestrun` documents `UseDestinationArtifacts`: set true, omit TestHostPath/TestBundlePath/UITargetAppPath, provide installed TestHostBundleIdentifier and TestBundleDestinationRelativePath (`__TESTHOST__/PlugIns/...`), plus UITargetAppBundleIdentifier for UI tests. Manual install then this mode completed publication and UI acceptance, avoiding redundant Xcode installation. It does not bypass lock/passcode/automation authorization.

## Artifacts

`~/Downloads/phocoscan-training-comparison-20261113-v6/` contains `scan15-before-after.png` (actual three-view renders, identical rotation/crops), `report.json`, `preservation.json`, and `scan15-on-iphone.png`. Logs `/private/tmp/pw-v6-*.log`; pre-edit source snapshot `/private/tmp/pw-v6-before/`. No server changes or new GPU reconstruction.
