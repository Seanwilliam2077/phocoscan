#!/usr/bin/env python3
"""Apply the reviewed two-file GPU patch only when BOTH shared Hub and PocketWorld are idle.
Run as root with the staging directory argument. Exits 2 without changes while busy.
"""
import hashlib,json,os,pathlib,shutil,sqlite3,subprocess,sys,time
stage=pathlib.Path(sys.argv[1]).resolve()
expected='/mnt/data2/services/realityscan-hub/releases/5d7a3db4bcc3-20261110-model-stage-review-scope/backend'
current=subprocess.check_output(['systemctl','show','rshub-worker','-p','WorkingDirectory','--value'],text=True).strip()
assert current==expected,'Hub release changed; review the patch against the new release'
root=pathlib.Path(current)/'app';hashes=json.loads((stage/'hashes.json').read_text())
for name,hashes_for_file in hashes.items():
 assert name in ['worldmirror_runner.py','gpu_pool.py']
 assert hashlib.sha256((root/name).read_bytes()).hexdigest()==hashes_for_file['old'],'Hub source changed'
 assert hashlib.sha256((stage/name).read_bytes()).hexdigest()==hashes_for_file['new'],'Staged source changed'
 compile((stage/name).read_bytes(),name,'exec')
pw=sqlite3.connect('/mnt/data2/pocketworld/data/pocketworld.sqlite',timeout=3)
hub=sqlite3.connect('/mnt/data2/services/realityscan-hub/data/hub.db',timeout=3)
# Hold both write locks across the idle check and worker stop. New submissions cannot race it.
pw.execute('BEGIN IMMEDIATE');hub.execute('BEGIN IMMEDIATE')
a=pw.execute("select count(*) from video_reconstruction_tasks_v2 where status in ('queued','processing')").fetchone()[0]
b=hub.execute("select count(*) from step where status in ('RUNNING','PENDING','QUEUED')").fetchone()[0]
if a or b:
 print('DEFERRED_ACTIVE_TASKS',{'pocketworld':a,'hub':b});hub.rollback();pw.rollback();sys.exit(2)
backup=stage/('backup-'+str(int(time.time())));backup.mkdir()
for name in hashes:shutil.copy2(root/name,backup/name)
subprocess.run(['systemctl','stop','rshub-worker'],check=True,timeout=40)
try:
 for name in hashes:
  dest=root/name;info=dest.stat();tmp=dest.with_suffix('.py.pocketworld-next')
  tmp.write_bytes((stage/name).read_bytes());os.chmod(tmp,info.st_mode & 0o777);os.chown(tmp,info.st_uid,info.st_gid);os.replace(tmp,dest)
 hub.commit();pw.commit()
 subprocess.run(['systemctl','start','rshub-worker'],check=True,timeout=30)
 subprocess.run(['systemctl','is-active','--quiet','rshub-worker'],check=True)
except BaseException:
 for name in hashes:shutil.copy2(backup/name,root/name)
 hub.rollback();pw.rollback();subprocess.run(['systemctl','start','rshub-worker'])
 raise
# The executor now dynamically leases any eligible GPU; remove the temporary admission affinity.
p=pathlib.Path('/etc/pocketworld/api.json');info=p.stat();shutil.copy2(p,backup/'api.json')
d=json.loads(p.read_text());d['gpuAdmission'].get('roleGPUUUIDs',{}).pop('preview',None)
tmp=p.with_suffix('.json.next');tmp.write_text(json.dumps(d,indent=2)+'\n');os.chmod(tmp,info.st_mode&0o777);os.chown(tmp,info.st_uid,info.st_gid);os.replace(tmp,p)
subprocess.run(['systemctl','restart','pocketworld-api'],check=True,timeout=30)
print('APPLIED_DYNAMIC_GPU',str(backup))
