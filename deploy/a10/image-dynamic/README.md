# phocoscan dynamic single-image executor

Live 2026-11-10: `20261110-a10-e2d0aab11b1e`, archive SHA-256 `e2d0aab11b1e56703e95f6a40e45cc347164168908f266a49a951597cd89df3d`.

This service imports the installed TripoSplat/svckit runtime and uses the existing weights. It does not patch or restart AgeScan. The service account remains yulingji because that account owns the runtime. PocketWorld's adapter authenticates with a separate key; only the phocoscan object prefix is accepted.

- Service: `pocketworld-triposplat`, localhost:18782.
- Code: `/opt/pocketworld/image-executor/{triposplat_service,dynamic_gpu}.py` copied from the tested release.
- Private overrides: `/etc/pocketworld/triposplat-dynamic.env`, root 0600. Inherits model/COS settings from the existing private environment file. Never print these files.
- Own state: `/mnt/data2/pocketworld-triposplat`; work: `/dev/shm/phocoscan-triposplat/jobs`. A tmpfiles rule recreates the private shared-memory directory after reboot.
- API configuration: `imageGeneration.dynamicGPU=true`, image threshold 7000 MiB, no image GPU UUID affinity. `/etc/pocketworld/agescan.json` points at 18782 with the new dedicated key; private object-storage configuration is preserved.

Deployment: stage the immutable release archive and these scripts/unit. Check PocketWorld native and image jobs are idle, verify archive hash, run the existing `install-release.sh` (tests before selecting the symlink). Run `setup-executor.py STAGE RELEASE_DIRECTORY` as root. Verify health and authenticated capacity before running `activate.py`. Activation stops new API admissions, checks idle again, switches only PocketWorld configuration, and starts its API/worker. AgeScan and Hub units are not restarted. Setup is safe to repeat but intentionally does not restart an already-running executor; changes to its Python code require an explicit idle-guarded executor restart.

Validation: 160/160 Node tests on A10, including five Python selector checks; four tests against the installed TripoSplat runtime (startup wiring, admission/idempotency, dynamic child environment, cleanup/failure). A missing `local_root` bootstrap argument was found during startup, fixed, and covered by the new bootstrap test before activation. Authenticated adapter API, private storage and capacity probes pass. Read-only telemetry found non-default GPU 3 with 22,549 MiB free; dedicated jobs DB count is zero. These checks did not submit an image or initialize the model; actual image quality, cold load time and peak VRAM remain unverified.

Rollback, only while PocketWorld and the dedicated executor are idle:

1. Stop the PocketWorld API, recheck native/image pending tasks, then stop its worker. If work is active, restore API availability and defer rollback.
2. Restore `api.json` and `agescan.json` from `/etc/pocketworld/pre-image-dynamic-1794312009`, preserving their private owners/modes. This restores the old image affinity and origin 18082.
3. Repoint `/opt/pocketworld/current` to `/mnt/data2/pocketworld/releases/20261110-a10-dd9692bfde34`; start the two PocketWorld services and verify health.
4. Stop/disable only the idle `pocketworld-triposplat` service. Retain its DB and private configuration for recovery. Do not roll back the independent FF/SfM dynamic scheduler or touch shared AgeScan services.

The selector locks coordinate this executor, not every application on the shared server. It rechecks after locking and immediately before loading CUDA. A resource change becomes explicit busy/failure, never a silent wait or a different reconstruction method.
