"""Run with the existing TripoSplat runtime. All GPU/model calls are mocked."""
import pathlib,sys,tempfile,unittest
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'tools'))
import triposplat_service as app
from dynamic_gpu import GPUSelector,Busy
from fastapi import HTTPException
class Tests(unittest.TestCase):
 def test_service_bootstrap_matches_installed_runtime_without_loading_a_model(self):
  with tempfile.TemporaryDirectory() as d:
   settings=app.Settings(api_key='synthetic-only',port=18782,data_dir=pathlib.Path(d),work_root=pathlib.Path(d)/'jobs',allowed_key_prefix='agescan/phocoscan/')
   with patch.object(app,'Settings',return_value=settings),patch.object(app,'build_store',autospec=True) as storage,patch.object(app.service,'run',autospec=True) as run,patch.object(app,'InferenceProcess') as inference:
    app.main()
    storage.assert_called_once_with('cos',local_root=settings.local_store_root,secret_id=settings.cos_secret_id,secret_key=settings.cos_secret_key,endpoint=settings.cos_endpoint,env_prefix='TRIPOSPLAT_')
    run.assert_called_once();inference.assert_not_called()
    web,executor=run.call_args.args
    self.assertTrue(any(route.path=='/capacity' for route in web.routes))
    self.assertEqual(run.call_args.kwargs['port'],18782)
 def test_busy_does_not_create_and_existing_attempt_survives_busy(self):
  with tempfile.TemporaryDirectory() as d:
   selector=GPUSelector(pathlib.Path(d)/'locks',query=lambda:[('GPU-0003',6999)])
   store=app.AdmittedStore(pathlib.Path(d)/'jobs.db',selector,lambda:None)
   with self.assertRaises(HTTPException) as raised:store.create('a',{}, {'x':1},{'y':1})
   self.assertEqual(raised.exception.status_code,503);self.assertEqual(store._conn.execute('select count(*) from jobs').fetchone()[0],0)
   selector.query=lambda:[('GPU-0003',20000)]
   job=store.create('a',{}, {'x':1},{'y':1})
   selector.query=lambda:[('GPU-0003',0)]
   self.assertEqual(store.create('a',{}, {'x':1},{'y':1}).job_id,job.job_id)
   with self.assertRaises(HTTPException):store.create('a',{'changed':1},{'x':1},{'y':1})
 def test_dynamic_environment_and_cleanup_on_success_and_failure(self):
  for fail in [False,True]:
   with tempfile.TemporaryDirectory() as d:
    seen={}
    class FakeInference:
     def __init__(self,*a,**kw):seen['env']=kw['env']
     def call(self,*a,**kw):
      if fail:raise ValueError('synthetic')
      return {'ok':True}
     def stop(self):seen['stopped']=True
    class FakeRunner:
     def __init__(self,s,o,inference):self.inference=inference
     def run(self,c):return self.inference.call({})
    settings=SimpleNamespace(child_env=lambda:{'CUDA_VISIBLE_DEVICES':'GPU-fixed'},load_timeout_seconds=1)
    ctx=SimpleNamespace(raise_if_canceled=lambda:None,job=SimpleNamespace(job_id='synthetic'))
    selector=GPUSelector(d,query=lambda:[('GPU-0000',100),('GPU-0003',22000)])
    with patch.object(app,'InferenceProcess',FakeInference),patch.object(app,'TripoSplatRunner',FakeRunner):
     runner=app.DynamicRunner(settings,None,selector,lambda:None)
     if fail:
      with self.assertRaises(ValueError):runner.run(ctx)
     else:self.assertEqual(runner.run(ctx),{'ok':True})
    self.assertEqual(seen['env']['CUDA_VISIBLE_DEVICES'],'GPU-0003');self.assertTrue(seen['stopped'])
    with selector.lease() as selected:self.assertEqual(selected,'GPU-0003')
 def test_busy_never_constructs_model(self):
  with tempfile.TemporaryDirectory() as d:
   selector=GPUSelector(d,query=lambda:[('GPU-0000',10)])
   with patch.object(app,'InferenceProcess') as factory:
    runner=app.DynamicRunner(None,None,selector,lambda:None)
    with self.assertRaises(app.JobFailed) as e:runner.run(SimpleNamespace(raise_if_canceled=lambda:None))
    self.assertEqual(e.exception.code,'GPU_BUSY');factory.assert_not_called()
if __name__=='__main__':unittest.main()
