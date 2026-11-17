#!/usr/bin/env python3
"""Switch only PocketWorld to its tested private executor, with an idle guard/rollback."""
import json, os, pathlib, shutil, sqlite3, subprocess, time, urllib.request, urllib.error

assert os.geteuid() == 0
root = pathlib.Path('/etc/pocketworld')
api, bridge = root / 'api.json', root / 'agescan.json'
release = pathlib.Path('/opt/pocketworld/current').resolve()
assert (release / 'server/tools/triposplat_service.py').is_file()
env = dict(line.split('=', 1) for line in (root / 'triposplat-dynamic.env').read_text().splitlines() if '=' in line)
key = json.loads(env['TRIPOSPLAT_API_KEY'])
request = urllib.request.Request('http://127.0.0.1:18782/capacity', headers={'X-Api-Key': key})
try:
    with urllib.request.urlopen(request, timeout=10) as response:
        capacity = json.load(response)
        assert capacity['dynamicGPU'] is True and capacity['minFreeMiB'] == 7000
except urllib.error.HTTPError as error:
    # A genuinely busy server is still a healthy, fail-closed executor.
    assert error.code == 503

def idle():
    with sqlite3.connect('file:/mnt/data2/pocketworld/data/pocketworld.sqlite?mode=ro', uri=True) as db:
        native = db.execute("SELECT count(*) FROM video_reconstruction_tasks_v2 WHERE status IN ('queued','processing')").fetchone()[0]
        images = sum(json.loads(r[0])['status'] in ('queued', 'processing', 'cancelling') for r in db.execute('SELECT json FROM image_generations'))
    assert native == images == 0, 'PocketWorld has active work; no cutover'

def systemctl(*args):
    subprocess.run(['systemctl', *args], check=True, timeout=60)

def write(path, value):
    info = path.stat()
    tmp = path.with_suffix('.json.dynamic-next')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    os.chmod(tmp, info.st_mode & 0o777)
    os.chown(tmp, info.st_uid, info.st_gid)
    os.replace(tmp, path)

idle()
backup = root / ('pre-image-dynamic-' + str(int(time.time())))
backup.mkdir(mode=0o700)
for path in (api, bridge):
    shutil.copy2(path, backup / path.name)
(backup / 'release.txt').write_text(str(release) + '\n')
systemctl('stop', 'pocketworld-api')
try:
    # Freeze new admissions before checking again; never stop a working GPU worker.
    idle()
except BaseException:
    systemctl('start', 'pocketworld-api')
    raise
systemctl('stop', 'pocketworld-dual-worker')
try:
    a, b = json.loads(api.read_text()), json.loads(bridge.read_text())
    a['imageGeneration']['dynamicGPU'] = True
    a['gpuAdmission'].setdefault('roleMinFreeMiB', {})['image'] = 7000
    a['gpuAdmission'].setdefault('roleGPUUUIDs', {}).pop('image', None)
    b['origin'], b['apiKey'] = 'http://127.0.0.1:18782', key
    write(bridge, b)
    write(api, a)
    systemctl('start', 'pocketworld-api', 'pocketworld-dual-worker')
    systemctl('is-active', 'pocketworld-api', 'pocketworld-dual-worker', 'pocketworld-triposplat')
except BaseException:
    for path in (api, bridge):
        write(path, json.loads((backup / path.name).read_text()))
    systemctl('restart', 'pocketworld-api', 'pocketworld-dual-worker')
    raise
print('DYNAMIC_IMAGE_ACTIVE', 'backup=' + str(backup), 'release=' + release.name)
