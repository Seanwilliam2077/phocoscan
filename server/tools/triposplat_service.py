"""phocoscan-only dynamic TripoSplat executor using the existing model/runtime.
Own port, key, job DB and work directory. Never changes the shared AgeScan service.
"""
import logging,shutil,threading
from fastapi import Header,HTTPException
from svckit import service
from svckit.executor import Executor,JobFailed
from svckit.inference import InferenceProcess
from svckit.jobs import JobStore
from svckit.storage import build_store
from triposplat_svc.api import create_app
from triposplat_svc.config import Settings
from triposplat_svc.runner import TripoSplatRunner
from dynamic_gpu import GPUSelector,Busy

class AdmittedStore(JobStore):
    def __init__(self,path,selector,check_disk):
        super().__init__(path);self.selector=selector;self.check_disk=check_disk;self.admission=threading.Lock()
    def capacity(self):
        with self._lock:
            pending=self._conn.execute("SELECT count(*) FROM jobs WHERE status IN ('queued','running')").fetchone()[0]
        self.check_disk();self.selector.available(pending)
    def create(self,key,params,input,output):
        with self.admission:
            with self._lock:
                existing=self._conn.execute('SELECT * FROM jobs WHERE idempotency_key=?',(key,)).fetchone()
                if existing:
                    job=self._to_job(existing)
                    if (job.params,job.input,job.output)!=(params,input,output):raise HTTPException(409,'idempotency conflict')
                    return job # Already accepted requests must work even when capacity is now busy.
            try:self.capacity()
            except Busy:raise HTTPException(503,'服务器繁忙中') from None
            return super().create(key,params,input,output)

class DynamicRunner:
    def __init__(self,settings,objects,selector,check_disk):
        self.settings=settings;self.objects=objects;self.selector=selector;self.check_disk=check_disk
    def run(self,ctx):
        ctx.raise_if_canceled()
        try:
            self.check_disk()
            with self.selector.lease() as gpu:
                ctx.raise_if_canceled()
                env=self.settings.child_env();env['CUDA_VISIBLE_DEVICES']=gpu
                logging.info('phocoscan dynamic GPU selected %s for %s',gpu,ctx.job.job_id)
                selector=self.selector
                class CheckedInference(InferenceProcess):
                    def call(self,*args,**kwargs):
                        # Input transfer can take time; check again immediately before CUDA loads.
                        if dict(selector.query()).get(gpu,0)<selector.minimum:raise Busy()
                        return super().call(*args,**kwargs)
                inference=CheckedInference('triposplat_svc.model:build',env=env,idle_seconds=1,load_timeout=self.settings.load_timeout_seconds)
                try:return TripoSplatRunner(self.settings,self.objects,inference).run(ctx)
                finally:inference.stop() # Release the selected GPU after success/failure/cancel.
        except Busy:raise JobFailed('GPU_BUSY','服务器繁忙中') from None

def main():
    service.configure_logging();settings=Settings()
    assert settings.model=='triposplat' and settings.store=='cos'
    assert settings.host=='127.0.0.1' and settings.port==18782
    assert settings.allowed_key_prefix=='agescan/phocoscan/'
    lock=service.acquire_lock(settings.data_dir/'executor.lock','phocoscan-triposplat')
    selector=GPUSelector(settings.data_dir/'gpu-locks',settings.min_free_gpu_mb)
    def check_disk():
        if shutil.disk_usage('/dev/shm').free<settings.min_free_shm_gb*1024**3:raise Busy()
    store=AdmittedStore(settings.data_dir/'jobs.db',selector,check_disk)
    objects=build_store(settings.store,local_root=settings.local_store_root,secret_id=settings.cos_secret_id,secret_key=settings.cos_secret_key,endpoint=settings.cos_endpoint,env_prefix='TRIPOSPLAT_')
    app=create_app(settings,store)
    @app.get('/capacity')
    def capacity(x_api_key: str|None=Header(default=None)):
        import secrets
        if not x_api_key or not secrets.compare_digest(x_api_key,settings.api_key):raise HTTPException(401,'invalid api key')
        try:store.capacity()
        except Busy:raise HTTPException(503,'服务器繁忙中') from None
        return {'available':True,'dynamicGPU':True,'minFreeMiB':selector.minimum}
    executor=Executor(store,DynamicRunner(settings,objects,selector,check_disk),settings.work_root,lambda:True,max_attempts=1)
    try:service.run(app,executor,name='phocoscan-triposplat',host=settings.host,port=settings.port,detail='dynamic GPU, memory admission, no resource wait')
    finally:lock.close()

if __name__=='__main__':main()
