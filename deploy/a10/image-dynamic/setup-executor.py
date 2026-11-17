#!/usr/bin/env python3
"""Install/start the dedicated executor. Does not switch the public API or touch AgeScan units."""
import pathlib,subprocess,sys,os,pwd,secrets,shutil,json
stage=pathlib.Path(sys.argv[1]);release=pathlib.Path(sys.argv[2]);root=pathlib.Path('/opt/pocketworld/image-executor')
assert os.geteuid()==0 and (release/'server/tools/triposplat_service.py').is_file()
u=pwd.getpwnam('yulingji')
for p in [pathlib.Path('/mnt/data2/pocketworld-triposplat'),pathlib.Path('/dev/shm/phocoscan-triposplat')]:
 p.mkdir(exist_ok=True);os.chown(p,u.pw_uid,u.pw_gid);os.chmod(p,0o700)
tmpfiles=pathlib.Path('/etc/tmpfiles.d/pocketworld-triposplat.conf')
tmpfiles.write_text('d /dev/shm/phocoscan-triposplat 0700 yulingji users -\n');os.chmod(tmpfiles,0o644)
subprocess.run(['systemd-tmpfiles','--create',str(tmpfiles)],check=True)
root.mkdir(exist_ok=True,mode=0o755)
for name in ['dynamic_gpu.py','triposplat_service.py']:
 p=root/name;shutil.copy2(release/'server/tools'/name,p);os.chown(p,0,0);os.chmod(p,0o644)
env=pathlib.Path('/etc/pocketworld/triposplat-dynamic.env')
if not env.exists():
 values={'TRIPOSPLAT_API_KEY':secrets.token_urlsafe(32),'TRIPOSPLAT_HOST':'127.0.0.1','TRIPOSPLAT_PORT':'18782','TRIPOSPLAT_DATA_DIR':'/mnt/data2/pocketworld-triposplat','TRIPOSPLAT_WORK_ROOT':'/dev/shm/phocoscan-triposplat/jobs','TRIPOSPLAT_ALLOWED_KEY_PREFIX':'agescan/phocoscan/','TRIPOSPLAT_MIN_FREE_GPU_MB':'7000','TRIPOSPLAT_MAX_ATTEMPTS':'1','TRIPOSPLAT_MODEL':'triposplat','TRIPOSPLAT_STORE':'cos'}
 env.write_text(''.join(k+'='+json.dumps(v)+'\n' for k,v in values.items()));os.chmod(env,0o600)
unit=pathlib.Path('/etc/systemd/system/pocketworld-triposplat.service');shutil.copy2(stage/'pocketworld-triposplat.service',unit);os.chmod(unit,0o644)
subprocess.run(['systemd-analyze','verify',str(unit)],check=True)
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','enable','--now','pocketworld-triposplat'],check=True)
print('DEDICATED_EXECUTOR_STARTED_API_NOT_SWITCHED')
