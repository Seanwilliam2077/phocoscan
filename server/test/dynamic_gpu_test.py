import importlib.util,pathlib,sys,tempfile,unittest,subprocess
from types import SimpleNamespace
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'tools'))
from dynamic_gpu import GPUSelector,devices,Busy
class Tests(unittest.TestCase):
 def query(self,output):return devices(lambda *a,**k:SimpleNamespace(stdout=output))
 def test_not_first_gpu(self):
  rows=self.query('GPU-0000, 100, 24000\nGPU-0001, 22000, 24000\n')
  with tempfile.TemporaryDirectory() as d:
   s=GPUSelector(d,query=lambda:rows)
   with s.lease() as gpu:self.assertEqual(gpu,'GPU-0001')
 def test_insufficient_and_bad_telemetry(self):
  with tempfile.TemporaryDirectory() as d:
   s=GPUSelector(d,query=lambda:[('GPU-0000',6999)])
   with self.assertRaises(Busy):s.available()
   with self.assertRaises(Busy):
    with s.lease():pass
  for text in ['', 'GPU-0000,N/A,24000', 'GPU-0000,25000,24000', 'GPU-0000,10000,24000\nGPU-0000,10000,24000']:
   with self.assertRaises(Busy):self.query(text)
 def test_pending_reservations(self):
  with tempfile.TemporaryDirectory() as d:
   s=GPUSelector(d,query=lambda:[('GPU-0000',7000)])
   self.assertTrue(s.available())
   with self.assertRaises(Busy):s.available(1)
 def test_lease_release_and_contention(self):
  with tempfile.TemporaryDirectory() as d:
   s=GPUSelector(d,query=lambda:[('GPU-0000',20000),('GPU-0001',18000)])
   with s.lease() as a:
    with s.lease() as b:self.assertNotEqual(a,b)
   with s.lease() as c:self.assertEqual(c,'GPU-0000')
 def test_memory_rechecked_after_lease(self):
  values=iter([[('GPU-0000',20000)],[('GPU-0000',100)]])
  with tempfile.TemporaryDirectory() as d:
   s=GPUSelector(d,query=lambda:next(values))
   with self.assertRaises(Busy):
    with s.lease():self.fail('must not start')
if __name__=='__main__':unittest.main()
