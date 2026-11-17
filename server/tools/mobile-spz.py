#!/usr/bin/env python3
"""Create a v3 mobile derivative whose SplatIO RDF readback matches the original PLY.
Never alters the source. Round-trip checks reject coordinate overflow or lost SH bands.
"""
import sys,json,pathlib,os,ctypes
import numpy as np
import spz

def convert(source,dest):
    # Native SPZ writes diagnostics to file descriptor 1 (not Python's stdout).
    # Reserve stdout for the one JSON reply, both here and in the image adapter.
    sys.stdout.flush()
    saved=os.dup(1)
    try:
        os.dup2(2,1)
        return _convert(source,dest)
    finally:
        ctypes.CDLL(None).fflush(None)
        sys.stdout.flush();os.dup2(saved,1);os.close(saved)

def _convert(source,dest):
    unpack=spz.UnpackOptions();unpack.to_coord=spz.CoordinateSystem.UNSPECIFIED
    cloud=spz.load_splat_from_ply(str(source),unpack)
    pack=spz.PackOptions();pack.from_coord=spz.CoordinateSystem.RDF;pack.version=3
    # Keep all eight stored SH bits. The library's 5/4-bit defaults erase subtle
    # higher-order coefficients and are unsuitable for our high-quality version.
    pack.sh1_bits=8;pack.sh_rest_bits=8
    spz.save_spz(cloud,pack,str(dest))
    check=spz.UnpackOptions();check.to_coord=spz.CoordinateSystem.RDF
    restored=spz.load_spz(str(dest),check)
    assert cloud.num_points==restored.num_points and cloud.sh_degree==restored.sh_degree
    positions=np.asarray(cloud.positions);restored_positions=np.asarray(restored.positions)
    maximum=float(np.max(np.abs(positions-restored_positions)))
    assert np.isfinite(maximum) and maximum<=0.002,'position quantization exceeded bound'
    original_sh=np.asarray(cloud.sh);restored_sh=np.asarray(restored.sh)
    assert original_sh.size==restored_sh.size
    sh_error=float(np.max(np.abs(original_sh-restored_sh))) if original_sh.size else 0
    assert np.isfinite(sh_error) and sh_error<=0.02,'SH quantization exceeded bound'
    return {'points':cloud.num_points,'shDegree':cloud.sh_degree,'maxPositionError':maximum,'maxSHError':sh_error,'shBits':8,'lossy':True,'coordinateReadback':'RDF'}

if __name__=='__main__':
    try:
        source=pathlib.Path(sys.argv[1]);dest=pathlib.Path(sys.argv[2]);print(json.dumps(convert(source,dest)))
    except Exception:
        print('SPZ conversion failed validation',file=sys.stderr);sys.exit(1)
