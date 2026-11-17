"""Fail-closed, per-job GPU selection. No CUDA/model import is needed to check capacity."""
import contextlib,fcntl,pathlib,re,subprocess

class Busy(RuntimeError):
    def __init__(self): super().__init__('服务器繁忙中')

def devices(run=subprocess.run):
    try:
        r=run(['nvidia-smi','--query-gpu=uuid,memory.free,memory.total','--format=csv,noheader,nounits'],capture_output=True,text=True,timeout=3,check=True)
        result=[];seen=set()
        for line in r.stdout.splitlines():
            values=[v.strip() for v in line.split(',')]
            if len(values)!=3:raise ValueError()
            uid,free,total=values[0],int(values[1]),int(values[2])
            if not re.fullmatch(r'GPU-[0-9a-fA-F-]+',uid) or uid in seen or not 0<=free<=total:raise ValueError()
            result.append((uid,free));seen.add(uid)
        if not result:raise ValueError()
        return sorted(result,key=lambda x:(-x[1],x[0]))
    except (OSError,ValueError,subprocess.SubprocessError):raise Busy() from None

class GPUSelector:
    def __init__(self,directory,minimum=7000,query=devices):
        if not isinstance(minimum,int) or minimum<1:raise ValueError('invalid minimum')
        self.directory=pathlib.Path(directory);self.directory.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.minimum=minimum;self.query=query
    def candidates(self):return [uid for uid,free in self.query() if free>=self.minimum]
    def available(self,reserved=0):
        if len(self.candidates())<=reserved:raise Busy()
        return True
    @contextlib.contextmanager
    def lease(self):
        for uid in self.candidates():
            with (self.directory/(uid+'.lock')).open('a') as file:
                try:fcntl.flock(file,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:continue
                try:
                    # Telemetry may have changed between selection and acquiring the lease.
                    if dict(self.query()).get(uid,0)<self.minimum:continue
                    yield uid
                    return
                finally:fcntl.flock(file,fcntl.LOCK_UN)
        raise Busy()
