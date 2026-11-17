#!/usr/bin/env bash
# Run as root. Installs isolated runtime/configuration only; starts no services.
set -euo pipefail
umask 027
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'This pinned runtime is x86_64 only.' >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=/mnt/data2/pocketworld
NODE_VERSION=v24.22.2
NODE_ARCHIVE="node-${NODE_VERSION}-linux-x64.tar.xz"
NODE_SHA256=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
for tool in python3 curl tar xz systemctl useradd runuser visudo ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "Missing required executable: $tool" >&2; exit 1; }
done
if ! id pocketworld >/dev/null 2>&1; then
  useradd --system --user-group --no-create-home --home-dir "$BASE" --shell /sbin/nologin pocketworld
fi
[[ $(id -u pocketworld) -ne 0 ]] || { echo 'Invalid service account.' >&2; exit 1; }
install -d -o root -g pocketworld -m 0750 "$BASE" "$BASE/releases" "$BASE/runtime" "$BASE/staging"
install -d -o root -g root -m 0755 "$BASE/runtime/media"
# Existing shared tools may be root-only (0700). Give this service its own
# executable copies; the worker unit maps them over the unchanged configured
# paths inside its private mount namespace. Shared file permissions stay intact.
install -o root -g root -m 0755 /usr/local/bin/ffmpeg "$BASE/runtime/media/ffmpeg"
install -o root -g root -m 0755 /usr/local/bin/ffprobe "$BASE/runtime/media/ffprobe"
install -d -o pocketworld -g pocketworld -m 0700 "$BASE/data" "$BASE/work"
install -d -o root -g root -m 0755 /opt/pocketworld /opt/pocketworld/artifact-helper /opt/pocketworld/service-tools
install -d -o root -g pocketworld -m 0750 /etc/pocketworld
if [[ ! -x "$BASE/runtime/node-${NODE_VERSION}-linux-x64/bin/node" ]]; then
  ARCHIVE="$BASE/staging/$NODE_ARCHIVE"
  if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
      "https://nodejs.org/dist/${NODE_VERSION}/${NODE_ARCHIVE}" --output "$ARCHIVE.partial"
    mv -- "$ARCHIVE.partial" "$ARCHIVE"
  fi
  printf '%s  %s\n' "$NODE_SHA256" "$ARCHIVE" | sha256sum --check --status
  tar --extract --xz --file "$ARCHIVE" --directory "$BASE/runtime" --no-same-owner
  chown -R root:root "$BASE/runtime/node-${NODE_VERSION}-linux-x64"
fi
ln -sfn "$BASE/runtime/node-${NODE_VERSION}-linux-x64" /opt/pocketworld/node
/opt/pocketworld/node/bin/node --version
/usr/bin/python3 - <<'PY'
import json,os,pathlib,pwd,secrets
account=pwd.getpwnam('pocketworld')
root=pathlib.Path('/etc/pocketworld')
configs={
 'api.json':{'host':'9.135.79.113','port':8787,'dataDir':'/mnt/data2/pocketworld/data','adminToken':secrets.token_urlsafe(32)},
 'worker.json':{'dataDir':'/mnt/data2/pocketworld/data','workDir':'/mnt/data2/pocketworld/work',
  'hubOrigin':'http://127.0.0.1:8000','successStatus':'SUCCESS','plyProfile':'worldmirror2-probability-v1',
  'ffFrameCount':16,'sfmFrameCount':64,'maxConcurrentJobs':2,
  'ffmpegPath':'/usr/local/bin/ffmpeg','ffprobePath':'/usr/local/bin/ffprobe',
  'artifactLocal':{'pythonPath':'/usr/bin/python3','helperPath':'/opt/pocketworld/artifact-helper/read-hub-cameras.py','useSudo':True}}
}
for name,config in configs.items():
 path=root/name
 if not path.exists():
  fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'w') as handle:json.dump(config,handle,indent=2);handle.write('\n')
 os.chown(path,account.pw_uid,account.pw_gid);os.chmod(path,0o600)
print('Private configurations are installed; credentials were not printed.')
PY
install -o root -g root -m 0644 "$HERE/pocketworld-api.service" /etc/systemd/system/pocketworld-api.service
install -o root -g root -m 0644 "$HERE/pocketworld-dual-worker.service" /etc/systemd/system/pocketworld-dual-worker.service
install -o root -g root -m 0644 "$HERE/wait-for-api.mjs" /opt/pocketworld/service-tools/wait-for-api.mjs
visudo --check --file "$HERE/pocketworld-artifact.sudoers"
install -o root -g root -m 0440 "$HERE/pocketworld-artifact.sudoers" /etc/sudoers.d/pocketworld-artifact
systemctl daemon-reload
echo 'Base installed. API and worker have NOT been started or enabled.'
