"""Read-only, exact-task artifact exporter, local fixed command or authorized SSH.

SSH callers prefix REQUEST_B64. Local callers send bounded JSON on stdin.
Install the local helper in a root-owned, non-writable directory; input is data,
never Python code. This script does not create or modify any Hub files.
"""
import base64, hashlib, json, pathlib, re, sqlite3, struct, sys

def main():
    if 'REQUEST_B64' in globals():
        payload = base64.b64decode(REQUEST_B64, validate=True)
    else:
        payload = sys.stdin.buffer.read(16385)
    assert len(payload) <= 16384, 'Request exceeds limit'
    request = json.loads(payload)
    assert isinstance(request, dict) and set(request) == {'projectId', 'stepId', 'groupId', 'imagesAssetId', 'algorithm', 'plySha256'}
    assert re.fullmatch(r'[a-f0-9]{64}', request['plySha256']), 'Invalid model hash'
    for key in ('projectId', 'stepId', 'groupId', 'imagesAssetId'):
        assert re.fullmatch(r'[A-Za-z0-9_-]{1,128}', request[key]), 'Invalid provider ID'
    assert request['algorithm'] in ('gs_worldmirror2', 'gs_mcmc')
    # The Hub's business data moved to its public service root on 2026-11-04 (a notice
    # remains in the retired personal tree). Prefer it; keep the old root as a fallback.
    roots = (pathlib.Path('/mnt/data2/services/realityscan-hub/data'),
             pathlib.Path('/mnt/data2/blaisewang/RealityScan/rs_root/hub_projects'))
    hub = next((root for root in roots if (root / 'hub.db').is_file()), None)
    assert hub is not None, 'Hub data root not found'
    db = sqlite3.connect('file:' + str(hub / 'hub.db') + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    project = db.execute('SELECT id,name,group_id FROM project WHERE id=?', (request['projectId'],)).fetchone()
    step = db.execute('SELECT id,project_id,type,status,exit_code,params FROM step WHERE id=?', (request['stepId'],)).fetchone()
    assert project and step, 'Unknown project/task'
    assert project['group_id'] == request['groupId'] and step['project_id'] == project['id']
    assert step['type'] == request['algorithm'] and step['status'] == 'SUCCESS' and step['exit_code'] == 0
    assert re.fullmatch(r'[A-Za-z0-9_-]{1,120}', project['name']), 'Unsupported project name'
    task = (hub / 'projects' / project['name'] / '3DGS' / step['id']).resolve(strict=True)
    allowed = [hub.resolve(), pathlib.Path('/mnt/data2/zxnzzhang/rsp').resolve()]
    assert any(task.is_relative_to(root) for root in allowed), 'Unexpected task root'

    def bounded(relative, maximum=16*1024*1024):
        p = (task / relative).resolve(strict=True)
        assert p.is_relative_to(task) and p.is_file() and p.stat().st_size <= maximum, 'Invalid task artifact'
        return p

    def digest(p):
        h = hashlib.sha256()
        with p.open('rb') as f:
            while chunk := f.read(1024*1024): h.update(chunk)
        return h.hexdigest()

    def readjson(relative):
        p = bounded(relative)
        return json.loads(p.read_text()), digest(p)

    result = {'projectId': project['id'], 'stepId': step['id'], 'groupId': project['group_id'],
              'algorithm': step['type'], 'status': step['status'], 'metricScaleVerified': False}
    if step['type'] == 'gs_worldmirror2':
        model = bounded('output/worldmirror2/gaussians.ply', 150*1024*1024)
        assert digest(model) == request['plySha256'], 'Model does not match HTTP download'
        cameras, camera_hash = readjson('output/worldmirror2/camera_params.json')
        selected, selection_hash = readjson('input/selected_frames.json')
        png = bounded('output/worldmirror2/depth/depth_0000.png').read_bytes()
        assert png[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack('>II', png[16:24])
        sources = []
        for frame in selected['images']:
            assert re.fullmatch(r'[A-Za-z0-9_.-]+', frame['input'])
            p = bounded('input/images/' + frame['input'], 20*1024*1024)
            sources.append({'cameraIndex': frame['index'], 'sourceIndex': frame['source_index'],
                            'name': frame['source'], 'sha256': digest(p)})
        result.update(cameras=cameras, cameraSha256=camera_hash, selected=sources,
                      selectionSha256=selection_hash, imageWidth=width, imageHeight=height,
                      convention='opencv_camera_to_world')
    else:
        params = json.loads(step['params'] or '{}')
        import_id = params.get('import_step_id')
        assert re.fullmatch(r'[A-Za-z0-9_-]{1,128}', import_id or '')
        prepared = db.execute('SELECT project_id,status,report_json FROM step WHERE id=?', (import_id,)).fetchone()
        assert prepared and prepared['project_id'] == project['id'] and prepared['status'] == 'SUCCESS'
        preparation = json.loads(prepared['report_json'])
        assert preparation['images_asset_id'] == request['imagesAssetId']
        sources = {item['image_name']: item for item in preparation['image_sources']}
        asset_root = (hub / '3dgs_assets' / request['imagesAssetId'] / 'images').resolve(strict=True)
        assert asset_root.is_relative_to(hub.resolve())
        steps = int(params.get('steps', 7000))
        assert 1 <= steps <= 100000
        output = 'output/gs_mcmc/point_cloud/iteration_' + str(steps)
        model = bounded(output + '/point_cloud.ply', 150*1024*1024)
        assert digest(model) == request['plySha256'], 'Model does not match HTTP download'
        check, check_hash = readjson(output + '/export_check.json')
        result.update(exportCheck=check, exportCheckSha256=check_hash)

        class Reader:
            def __init__(self, relative):
                self.path = bounded(relative, 64*1024*1024)
                self.data = self.path.read_bytes(); self.offset = 0
            def unpack(self, fmt):
                values = struct.unpack_from('<' + fmt, self.data, self.offset)
                self.offset += struct.calcsize('<' + fmt)
                return values
            def text(self):
                end = self.data.index(0, self.offset)
                s = self.data[self.offset:end].decode('utf8'); self.offset = end + 1
                return s
            def skip(self, n):
                self.offset += n; assert self.offset <= len(self.data)
            def end(self): assert self.offset == len(self.data)

        c = Reader('sfm_images/sparse/0/cameras.bin'); count, = c.unpack('Q')
        assert 1 <= count <= 2048
        cameras = []
        for _ in range(count):
            cid, model_id, width, height = c.unpack('iiQQ')
            assert model_id == 0, 'Only verified SIMPLE_PINHOLE camera decoder enabled'
            f, cx, cy = c.unpack('ddd')
            cameras.append({'id': cid, 'width': width, 'height': height,
                            'intrinsics': [[f,0,cx],[0,f,cy],[0,0,1]]})
        c.end()
        r = Reader('sfm_images/sparse/0/images.bin'); count, = r.unpack('Q')
        assert 1 <= count <= 2048
        images = []
        for _ in range(count):
            iid, = r.unpack('i'); q = r.unpack('dddd'); t = r.unpack('ddd'); cid, = r.unpack('i')
            name = r.text(); n, = r.unpack('Q'); r.skip(n*24)
            assert re.fullmatch(r'image_\d{6}\.jpg', name)
            source = sources[name]
            assert re.fullmatch(r'[A-Za-z0-9_.-]+', source['asset_filename'])
            p = (asset_root / source['asset_filename']).resolve(strict=True)
            assert p.is_relative_to(asset_root) and p.is_file() and p.stat().st_size <= 20*1024*1024
            source_hash = digest(p)
            assert source_hash == source['sha256'], 'Original source asset changed'
            images.append({'id':iid, 'name':name, 'cameraId':cid, 'sha256':source_hash, 'sourceName':source['source_name'],
                           'worldToCamera':{'quaternionWXYZ':q,'translation':t}})
        r.end()
        result.update(cameras=cameras, images=images, importStepId=import_id, cameraSha256=digest(c.path), imagesSha256=digest(r.path),
                      convention='opencv_world_to_camera')
    db.close()
    print(json.dumps(result, separators=(',', ':')))

if __name__ == '__main__':
    try:
        main()
    except (AssertionError, KeyError, ValueError, TypeError, struct.error, FileNotFoundError):
        # A successful task with invalid or missing exact artifacts must not loop
        # forever as a transport retry. Do not emit remote paths or traceback.
        print('Exact-task artifact verification failed', file=sys.stderr)
        sys.exit(65)
    except Exception:
        print('Read-only artifact command failed', file=sys.stderr)
        sys.exit(70)
