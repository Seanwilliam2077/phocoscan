# A10 standalone PocketWorld services

This installs a business API and an outbound dual-reconstruction worker on the
existing A10 host. They are separate from RealityScan Hub. It does not modify
or restart `rshub-api`, `rshub-worker`, nginx, or GPU assignments.

The initial endpoint is **http://9.135.79.113:8787** on the existing internal
network. There is no invented HTTPS/domain configuration. Internet access and
iPhone installation still require their own verification.

## Layout and identity

| Location | Purpose |
| --- | --- |
| `/mnt/data2/pocketworld/releases/` | Immutable root-owned application releases |
| `/mnt/data2/pocketworld/runtime/` | Separate Node 24 runtime; system Node stays unchanged |
| `/mnt/data2/pocketworld/data/` | Persistent uploads, database and published models |
| `/mnt/data2/pocketworld/work/` | Durable task journals, selected frames and reconstruction downloads |
| `/etc/pocketworld/api.json` | Private API configuration and random admin token, mode 0600 |
| `/etc/pocketworld/worker.json` | Private worker configuration, mode 0600 |
| `/opt/pocketworld/artifact-helper/` | Root-owned bounded read-only Hub artifact helper |

Services run as the dedicated `pocketworld` account with a nologin shell. The API
cannot gain privileges. The worker can invoke only the exact root-owned Python
artifact reader specified by `pocketworld-artifact.sudoers`; its request is
bounded JSON on stdin. No SSH private key or general Hub filesystem ACL is
installed. Changing the privileged reader is a root-only release operation.

The host's shared ffmpeg/ffprobe binaries were root-only. The base installer
creates private executable copies under `runtime/media`; the worker gets
read-only bind mounts at its configured tool paths. This preserves shared tool
permissions and existing durable worker identity. Its startup health gate waits
for the API to finish opening the database before starting the queue loop.

## Install and activate

1. Transfer this deployment directory to an operator staging directory, then run
   `sudo bash install-base.sh`. It creates the isolated runtime, account,
   configuration and service definitions. It starts nothing. Node v24.22.2 is
   pinned to the SHA-256 published by the official Node release site:
   [release checksums](https://nodejs.org/dist/v24.22.2/SHASUMS256.txt).
2. Build a source-only archive containing `server/src`, `server/tools`,
   `server/test`, package files, `index.mjs`, `admin.mjs` and `README.md`.
   Never include `.local-config.json`, `data`, `work`, private media, credentials,
   or Windows `node_modules`. Run
   `sudo bash install-release.sh /absolute/source.tar.gz RELEASE_ID`.
   The installer verifies the archive allowlist, installs locked dependencies
   without lifecycle scripts, and runs the server test suite as the service user.
3. Once the release and helper have passed review, activate the API with
   `sudo systemctl enable --now pocketworld-api.service`.
   Check `/health` from the Windows computer and iPhone's network.
4. Start the worker only when automatic processing is intended:
   `sudo systemctl enable --now pocketworld-dual-worker.service`.
   It resumes durable tasks and processes newly uploaded videos without the
   Windows computer remaining on. `Restart=on-failure` restarts crashed services;
   systemd starts enabled services after a host reboot.

The worker must be stopped before activating a release containing incompatible
job configuration. Switching `current` does not update an already-running Node
process. Use an explicit maintenance restart of only the PocketWorld services
after release validation. Ambiguous provider writes remain blocked for operator
reconciliation; service restart does not blindly duplicate GPU work.

## Operations

- Inspect `systemctl status pocketworld-api pocketworld-dual-worker` and
  `journalctl -u pocketworld-api -u pocketworld-dual-worker`. Do not print private
  configuration files in shared logs or chat.
- Back up `/mnt/data2/pocketworld/data`, `/mnt/data2/pocketworld/work` and private
  configuration with a consistent SQLite backup or while both services are
  stopped. Preserve original video and source hashes together with result data.
- Monitor disk space. The audited host had about 472 GB free on `/mnt/data2` and
  only 4.5 GB free on `/`; model retention is not automatically purged.
- A future domain, TLS termination and externally reachable network policy are
  separate deployment changes. The present endpoint is an internal HTTP demo.

Rollback selects a previously validated release and restarts only PocketWorld
services. Restore its matching root-owned artifact helper as well; never replace
the durable data directory with an older snapshot casually.

## Verified deployment — 2026-11-03

The A10 deployment runs Node v24.22.2 while the system Node remains v18.20.8.
All 125 server tests passed under the dedicated Linux service account. The API
and worker are both enabled and active. Windows reached the internal health
endpoint successfully. The same service sandbox successfully probed an uploaded
real H.264 video and extracted a frame; bounded artifact reads returned the
matching 16-camera FF and 64-camera SfM evidence without installing an SSH key.

An actual in-flight reconstruction survived a restart of both PocketWorld
services after provider mutations were confirmed: task IDs, claim IDs, worker
identity, provider project/step IDs and provider step counts were unchanged.
The FF result stayed available while SfM continued. RealityScan Hub process IDs
were unchanged. Deployment and restart evidence is retained under the ignored
`work/a10-deployment-20261103/` directory and the server's private staging folder.

This confirms service restart recovery and boot enablement; the host itself was
not rebooted. It does not claim an iPhone native installation or a public HTTPS
endpoint.
