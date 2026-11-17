import ast, contextlib, importlib.util, os, pathlib, subprocess, sys, types, unittest
from unittest.mock import patch
ROOT=pathlib.Path(sys.argv.pop(1))
pkg=types.ModuleType('pwfixture');pkg.__path__=[];sys.modules['pwfixture']=pkg
cfg=types.ModuleType('pwfixture.config');cfg.DEPLOYMENT_PROFILE='a10';sys.modules[cfg.__name__]=cfg
spec=importlib.util.spec_from_file_location('pwfixture.gpu_pool',ROOT/'gpu_pool.py')
pool=importlib.util.module_from_spec(spec);sys.modules[spec.name]=pool;spec.loader.exec_module(pool)
source=ast.parse((ROOT/'worldmirror_runner.py').read_text())
namespace={'__package__':'pwfixture','contextmanager':contextlib.contextmanager,'config':cfg,'os':os,'subprocess':subprocess,'ProgressCallback':object,'_cancel_requested':lambda _:False}
exec(compile(ast.Module(body=[n for n in source.body if isinstance(n,ast.FunctionDef) and n.name in ['gpu_lease','_leased_gpu_uuid']],type_ignores=[]),'runner','exec'),namespace)
class Tests(unittest.TestCase):
 def setUp(self):pool._in_use.clear();pool._exclusive.clear()
 def test_any_idle_gpu_and_release(self):
  with patch.object(pool,'_query_gpu_memory_mib',return_value={0:(21000,23000),7:(500,23000)}):
   with namespace['gpu_lease']('synthetic',0,lambda _:None) as gpu:
    self.assertEqual(gpu,7);self.assertIn(7,pool._exclusive)
   self.assertFalse(pool._in_use)
 def test_busy_does_not_fallback_or_wait(self):
  with patch.object(pool,'_query_gpu_memory_mib',return_value={0:(21000,23000)}):
   with self.assertRaises(pool.GpuBusyError):
    with namespace['gpu_lease']('synthetic',0,lambda _:None):self.fail()
 def test_existing_lease_is_not_reused(self):
  pool._in_use.add(7)
  with patch.object(pool,'_query_gpu_memory_mib',return_value={0:(21000,23000),7:(0,23000)}):
   with self.assertRaises(pool.GpuBusyError):pool.acquire_available([0,7],20000)
 def test_unknown_memory_is_not_permission(self):
  with patch.object(pool,'_query_gpu_memory_mib',return_value=None):
   self.assertFalse(pool.precheck(20000)[0])
   with self.assertRaises(pool.GpuBusyError):pool.acquire(0,20000)
 def test_runtime_uuid_matches_lease(self):
  with patch.object(subprocess,'run',return_value=types.SimpleNamespace(returncode=0,stdout='7, GPU-selected\n')):
   self.assertEqual(namespace['_leased_gpu_uuid'](7),'GPU-selected')
   with self.assertRaises(RuntimeError):namespace['_leased_gpu_uuid'](0)
unittest.main()
