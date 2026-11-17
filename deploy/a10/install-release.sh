#!/usr/bin/env bash
# Usage: sudo bash install-release.sh /absolute/source.tar.gz RELEASE_ID
# Upload only allowlisted source files. No Windows credentials/data are needed.
set -euo pipefail
umask 022
[[ ${EUID} -eq 0 && $# -eq 2 ]] || { echo 'Use: install-release.sh ARCHIVE RELEASE_ID as root.' >&2; exit 1; }
ARCHIVE="$(realpath -- "$1")"
RELEASE="$2"
[[ "$RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || { echo 'Invalid release ID.' >&2; exit 1; }
TARGET="/mnt/data2/pocketworld/releases/$RELEASE"
[[ ! -e "$TARGET" ]] || { echo 'Release already exists; choose a new immutable ID.' >&2; exit 1; }
[[ -x /opt/pocketworld/node/bin/node ]] || { echo 'Install the base runtime first.' >&2; exit 1; }
/usr/bin/python3 - "$ARCHIVE" "$TARGET" <<'PY'
import pathlib,sys,tarfile
archive,target=sys.argv[1:]
allowed={'server/src','server/test','server/tools'}
files={'server/package.json','server/package-lock.json','server/index.mjs','server/admin.mjs','server/README.md'}
with tarfile.open(archive,'r:gz') as bundle:
 for member in bundle.getmembers():
  p=pathlib.PurePosixPath(member.name)
  if p.is_absolute() or '..' in p.parts or member.issym() or member.islnk() or not(member.isdir() or member.isfile()):raise SystemExit('Unsafe release archive')
  normalized=p.as_posix().rstrip('/')
  if normalized not in files and normalized!='server' and not any(normalized==q or normalized.startswith(q+'/') for q in allowed):raise SystemExit('Unexpected source file in release')
  if any(part.startswith('.') for part in p.parts):raise SystemExit('Hidden files are excluded from releases')
 pathlib.Path(target).mkdir(mode=0o755)
 bundle.extractall(target,filter='data')
PY
export PATH=/opt/pocketworld/node/bin:/usr/local/bin:/usr/bin:/bin
npm ci --prefix "$TARGET/server" --omit=dev --ignore-scripts --no-audit --no-fund --cache /mnt/data2/pocketworld/staging/npm-cache
chown -R root:root "$TARGET"
chmod -R a+rX,go-w "$TARGET"
[[ -f "$TARGET/server/tools/read-hub-cameras.py" ]] || { echo 'Missing bounded artifact helper.' >&2; exit 1; }
/usr/bin/python3 - "$TARGET/server/tools/read-hub-cameras.py" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);compile(p.read_bytes(),str(p),'exec')
PY
# Unit tests are local synthetic/read-only checks and do not submit GPU jobs.
cd "$TARGET/server"
/usr/sbin/runuser -u pocketworld -- /opt/pocketworld/node/bin/node --test --test-concurrency=1 "$TARGET"/server/test/*.test.mjs
install -o root -g root -m 0644 "$TARGET/server/tools/read-hub-cameras.py" /opt/pocketworld/artifact-helper/read-hub-cameras.py.next
mv -f /opt/pocketworld/artifact-helper/read-hub-cameras.py.next /opt/pocketworld/artifact-helper/read-hub-cameras.py
ln -sfn "$TARGET" /opt/pocketworld/current.next
mv -Tf /opt/pocketworld/current.next /opt/pocketworld/current
systemd-analyze verify /etc/systemd/system/pocketworld-api.service /etc/systemd/system/pocketworld-dual-worker.service
echo "Release selected: $RELEASE. No service was started or restarted."
