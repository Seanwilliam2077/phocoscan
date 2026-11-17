#!/usr/bin/env python3
"""Read-only hardware telemetry; no GPU selection, process termination or CUDA work."""
import json, os, pathlib, subprocess, time
out = pathlib.Path('/run/pocketworld-gpu/status.json')
gpus = []
try:
    result = subprocess.run(['/usr/bin/nvidia-smi', '--query-gpu=uuid,memory.free', '--format=csv,noheader,nounits'],
                            check=True, capture_output=True, text=True, timeout=5)
    for line in result.stdout.splitlines():
        uuid, free = [v.strip() for v in line.split(',')]
        if not uuid.startswith('GPU-') or int(free) < 0: raise ValueError('Invalid GPU telemetry')
        gpus.append({'uuid': uuid, 'freeMiB': int(free)})
except Exception:
    gpus = []  # fail closed; never authorize from stale or unknown hardware state
out.parent.mkdir(exist_ok=True)
tmp = out.with_suffix('.tmp')
tmp.write_text(json.dumps({'at': int(time.time()*1000), 'gpus': gpus}))
os.chmod(tmp, 0o644)
os.replace(tmp, out)
