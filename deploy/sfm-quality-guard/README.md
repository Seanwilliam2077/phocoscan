# Image-only SfM initialization guard

This deployment patch addresses a real COLMAP initialization failure encountered
while validating the automatic video → FF + SfM workflow on 2026-11-03.

`101_images_to_gs_mcmc.sh` is the patched Hub pipeline. Its companion
`104_sfm_quality_guard.py` uses only the Python standard library. Install them
together in the Hub's existing `backend/scripts/gs_mcmc/` directory, preserving
the original file ownership and keeping a backup. The patch applies only to the
image-only mapper branch; FF, pose-prior mapping and MCMC training parameters
are unchanged. The API does not need a restart because new jobs execute the
pipeline script from disk.

## What changed

- Supply a naturally sorted image list and use one feature-extraction thread
  so COLMAP image IDs are assigned consistently.
- Fix the default, two-view geometry and mapper random seeds; use one matching
  and mapper thread for the validation profile.
- Validate the actual binary sparse model before starting MCMC: at least 50%
  of input images must register (minimum three, or two for a two-image input),
  at least 100 finite 3D points must have valid tracks, and median stored
  reprojection error must be at most four pixels.
- Use the complete sorted input list as the registration denominator. Require
  the feature database to contain exactly those image names; dropped images
  fail explicitly instead of silently lowering the acceptance threshold.
- If default initialization fails, try at most two further pairs selected
  exclusively from the current task's verified two-view geometry. Exclude
  planar/panoramic, degenerate and watermark configurations; require at least
  100 inliers and a gap in sorted image sequence positions. Prefer strong pairs
  from different portions of the sequence. Sequence position is an ordering
  heuristic, not a measured timestamp or triangulation baseline.
- Preserve all attempted sparse models and quality decisions under
  `sfm_images/sfm_quality_guard/`. Only an accepted model is copied into
  `sfm_images/sparse/0`. No previous project's poses, sparse model or Gaussian
  output is reused.

## Evidence and validation

The failed and previously successful runs used byte-identical 64-frame inputs,
identical keypoints/descriptors and identical reconstruction parameters. The
failed mapper chose a planar-or-panoramic initial pair, registered three images,
and ended with zero points. The successful run registered 64 images and retained
6,308 sparse points. The actual failure was not a reported GPU memory error.

The installed COLMAP binary's help confirmed all added options. `bash -n` and
Python compilation passed. Read-only checks against the actual models rejected
the failed model and accepted the successful model; these checks did not run
reconstruction. Candidate selection uses the current database and contains no
video-specific filenames or IDs.

The corrected fresh reconstruction subsequently passed the default mapper
attempt with 64/64 registered images, 6,275 sparse points and median stored
reprojection error of 0.459 pixels. A read-only recheck confirmed its feature
database exactly matched the complete 64-image source list. Five synthetic
Python tests also cover bounded recovery, refusal to promote invalid models,
homography exclusion and missing-input rejection; run them with
`python test_sfm_quality_guard.py`. Synthetic fixtures never invoke COLMAP.

Quality gates reject unusable geometry; they do not establish geometric
accuracy, robot training suitability or iPhone rendering performance. A new
The root workflow separately verifies MCMC, result publication and rendering.

This guard is for fresh image-only reconstruction. The pre-existing manual
`SKIP_SFM=1` route remains outside this guard and must not be used as an automatic
reconstruction entry point.

Local diagnostic evidence and remote backup records are kept in the ignored
`work/diagnostics-sfm-20261103/` directory. The patch file records the exact
changes to the original 101 script. If the upstream script changes, review and
rebase that patch rather than overwriting a newer pipeline.

## 2026-11-11 scoped export verification (deployed 8c74beee3e88)

`100_gs_mcmc_ckpt_to_3dgs_ply.py` retains the original COLMAP percentile-extent gate (characteristic span ratio 0.5–2.0). For app-owned `PocketWorld-SfM-*` projects under the known Hub project root only, replace the invalid assumption that normalized coordinates must fail that gate with a direct read-back of the written PLY. Reapply the similarity and compare every serialized mean, log-scale, quaternion rotation matrix, opacity and SH coefficient to its checkpoint row. Quaternion sign equivalence is allowed. Other Hub projects retain their existing decision path; no shared service restart is required.

`test_export_verification.py` checks unit/nonunit similarities, missing inverse transforms, corrupted geometry/appearance, quaternion signs, scope isolation and unchanged rejection of oversized/undersized models. The scan-16 original still fails the original extent gate after this patch; this patch alone does not repair its training. Subject-masked training is a separate input/optimization fix.
