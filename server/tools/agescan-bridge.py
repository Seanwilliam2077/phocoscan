#!/usr/bin/env python3
"""Dedicated phocoscan adapter to the shared TripoSplat API. No credentials in stdout.
The config is installed privately on the server; the helper only handles our own prefixes.
"""
import argparse, json, pathlib, sys, uuid, urllib.request, urllib.error

def main():
    p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('operation',choices=['advance','cancel','delete','probe','admit']);p.add_argument('id');p.add_argument('attempt');p.add_argument('folder');p.add_argument('provider',nargs='?',default='');a=p.parse_args()
    cfg=json.loads(pathlib.Path(a.config).read_text())
    ident=str(uuid.UUID(a.id));attempt=str(uuid.UUID(a.attempt));folder=pathlib.Path(a.folder).resolve()
    assert folder==pathlib.Path(cfg['dataRoot']).resolve()/ident
    origin=cfg['origin'];assert origin in ['http://127.0.0.1:18082','http://127.0.0.1:18782']
    def request(method,path,body=None):
        req=urllib.request.Request(origin+path,data=None if body is None else json.dumps(body).encode(),method=method,headers={'X-Api-Key':cfg['apiKey'],'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=30) as r:return json.load(r)
    if a.operation=='admit':
        try:print(json.dumps(request('GET','/capacity')))
        except urllib.error.HTTPError as e:
            if e.code!=503:raise
            print('{"available":false}')
        return
    from qcloud_cos import CosConfig,CosS3Client
    cos=CosS3Client(CosConfig(Region=cfg['region'],SecretId=cfg['secretId'],SecretKey=cfg['secretKey'],Scheme='https',Endpoint=cfg.get('endpoint') or None))
    prefix=cfg['prefix'];assert prefix=='agescan/phocoscan/'
    base=prefix+ident+'/';source=base+'input/';output=base+attempt+'/output/';bucket=cfg['bucket']
    if a.operation=='probe':
        request('GET','/health')
        try:request('GET','/jobs/'+ident)
        except urllib.error.HTTPError as e:assert e.code==404
        cos.list_objects(Bucket=bucket,Prefix=base,MaxKeys=1)
        print('{"health":true,"authenticatedAPI":true,"privateObjectStorage":true}');return
    if a.operation=='delete':
        marker=''
        while True:
            r=cos.list_objects(Bucket=bucket,Prefix=base,Marker=marker,MaxKeys=1000)
            for item in r.get('Contents',[]):
                key=item['Key'];assert key.startswith(base);cos.delete_object(Bucket=bucket,Key=key)
            if r.get('IsTruncated')!='true':break
            marker=r['NextMarker']
        print('{"ok":true}');return
    provider=a.provider
    if not provider:
        image=folder/'image.jpg';assert 0<image.stat().st_size<=20*1024*1024
        cos.upload_file(Bucket=bucket,Key=source+'image.jpg',LocalFilePath=str(image),PartSize=5,MAXThread=2)
        body={'idempotency_key':'phocoscan:'+attempt,'input':{'bucket':bucket,'region':cfg['region'],'prefix':source,'file':'image.jpg'},'output':{'bucket':bucket,'region':cfg['region'],'prefix':output},'params':{'num_gaussians':262144,'seed':42}}
        try:provider=request('POST','/jobs',body)['job_id']
        except urllib.error.HTTPError as e:
            if e.code!=503:raise
            print('{"status":"failed","errorCode":"GPU_BUSY"}');return
    provider=str(uuid.UUID(provider))
    if a.operation=='cancel':job=request('POST','/jobs/'+provider+'/cancel',{})
    else:job=request('GET','/jobs/'+provider)
    result={'jobId':provider,'status':job['status'],'stage':job.get('stage'),'progress':job.get('progress',0),'errorCode':(job.get('error') or {}).get('code')}
    if job['status']=='succeeded' and a.operation!='cancel':
        outputs=job['outputs'];assert outputs['ply']=='model.ply' and outputs['spz']=='model.spz'
        for name in ['model.ply','model.spz']:
            meta=cos.head_object(Bucket=bucket,Key=output+name);size=int(meta['Content-Length']);assert 0<size<=150*1024*1024
            tmp=folder/(name+'.download');cos.download_file(Bucket=bucket,Key=output+name,DestFilePath=str(tmp));assert tmp.stat().st_size==size;tmp.replace(folder/name)
        # Re-encode for our existing SplatIO RDF reader; retain the untouched source PLY.
        import importlib.util
        spec=importlib.util.spec_from_file_location('mobile_spz',pathlib.Path(__file__).with_name('mobile-spz.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        module.convert(folder/'model.ply',folder/'model.spz')
        result['viewHint']=outputs.get('view_hint')
    print(json.dumps(result))

if __name__=='__main__':
    try:main()
    except Exception:
        # Do not leak COS signed URLs, internal service traces, keys or raw paths.
        print('image adapter unavailable',file=sys.stderr);sys.exit(1)
