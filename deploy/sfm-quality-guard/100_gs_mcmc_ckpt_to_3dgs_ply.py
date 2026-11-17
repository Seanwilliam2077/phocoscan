#!/usr/bin/env python3
"""Export gsplat MCMC checkpoint to standard 62-property 3DGS PLY in COLMAP world frame."""
import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np
import torch
from plyfile import PlyData, PlyElement
from pycolmap import SceneManager
from scipy.spatial.transform import Rotation

REPO = Path(os.environ.get("GSPLAT_ROOT", Path(__file__).resolve().parents[1]))
GSPLAT_EXAMPLES = REPO / "third_party/gsplat/examples"

CANONICAL_PROPS = (
    ["x", "y", "z", "nx", "ny", "nz"]
    + [f"f_dc_{i}" for i in range(3)]
    + [f"f_rest_{i}" for i in range(45)]
    + ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
)


def percentile_bbox(xyz: np.ndarray) -> dict:
    p1 = np.percentile(xyz, 1, axis=0)
    p99 = np.percentile(xyz, 99, axis=0)
    return {
        "x": (float(p1[0]), float(p99[0])),
        "y": (float(p1[1]), float(p99[1])),
        "z": (float(p1[2]), float(p99[2])),
    }


def bbox_extent_ok(exported: dict, reference: dict, lo: float = 0.5, hi: float = 2.0) -> bool:
    """Compare 1/99 percentile bbox via characteristic length (geometric mean of axis spans)."""
    e_exts, r_exts = [], []
    for axis in ("x", "y", "z"):
        e_lo, e_hi = exported[axis]
        r_lo, r_hi = reference[axis]
        e_exts.append(e_hi - e_lo)
        r_exts.append(r_hi - r_lo)
    r_scale = float(np.prod(r_exts) ** (1.0 / 3.0))
    if r_scale <= 0:
        return False
    e_scale = float(np.prod(e_exts) ** (1.0 / 3.0))
    ratio = e_scale / r_scale
    return lo <= ratio <= hi


def median_exp_scale0(scales_log: np.ndarray) -> float:
    return float(np.median(np.exp(scales_log[:, 0])))


def read_ply_property_names(path: Path) -> list:
    ply = PlyData.read(str(path))
    return [p.name for p in ply.elements[0].properties]


def write_3dgs_ply(
    path: Path,
    means: np.ndarray,
    sh0: np.ndarray,
    shN: np.ndarray,
    opacities: np.ndarray,
    scales: np.ndarray,
    quats: np.ndarray,
    ref_props: list,
) -> None:
    n = means.shape[0]
    dtype = [("x", "f4"), ("y", "f4"), ("z", "f4"), ("nx", "f4"), ("ny", "f4"), ("nz", "f4")]
    for i in range(3):
        dtype.append((f"f_dc_{i}", "f4"))
    for i in range(45):
        dtype.append((f"f_rest_{i}", "f4"))
    dtype.extend(
        [
            ("opacity", "f4"),
            ("scale_0", "f4"),
            ("scale_1", "f4"),
            ("scale_2", "f4"),
            ("rot_0", "f4"),
            ("rot_1", "f4"),
            ("rot_2", "f4"),
            ("rot_3", "f4"),
        ]
    )
    assert [d[0] for d in dtype] == ref_props

    arr = np.empty(n, dtype=dtype)
    arr["x"], arr["y"], arr["z"] = means[:, 0], means[:, 1], means[:, 2]
    arr["nx"] = arr["ny"] = arr["nz"] = 0.0
    for i in range(3):
        arr[f"f_dc_{i}"] = sh0[:, i]
    for i in range(45):
        arr[f"f_rest_{i}"] = shN[:, i]
    arr["opacity"] = opacities
    arr["scale_0"], arr["scale_1"], arr["scale_2"] = scales[:, 0], scales[:, 1], scales[:, 2]
    arr["rot_0"], arr["rot_1"], arr["rot_2"], arr["rot_3"] = (
        quats[:, 0],
        quats[:, 1],
        quats[:, 2],
        quats[:, 3],
    )

    path.parent.mkdir(parents=True, exist_ok=True)
    PlyData([PlyElement.describe(arr, "vertex")], text=False).write(str(path))


def transform_splats_to_colmap(
    means_g: np.ndarray,
    scales_g: np.ndarray,
    quats_g: np.ndarray,
    T: np.ndarray,
) -> tuple:
    M, t = T[:3, :3], T[:3, 3]
    s = abs(np.linalg.det(M)) ** (1.0 / 3.0)
    R = M / s
    Minv = np.linalg.inv(M)

    means_c = (means_g - t) @ Minv.T
    scales_c = scales_g - np.log(s)

    q = quats_g / np.linalg.norm(quats_g, axis=1, keepdims=True)
    Rg = Rotation.from_quat(q[:, [1, 2, 3, 0]]).as_matrix()
    Rc = R.T @ Rg
    q_xyzw = Rotation.from_matrix(Rc).as_quat()
    quats_c = q_xyzw[:, [3, 0, 1, 2]]
    return means_c, scales_c, quats_c, s, R, Minv


def verify_written_splats(path, means, scales, quats, opacities, sh0, shN, T):
    """Verify actual serialized geometry against the checkpoint, not a bbox proxy.

    Quaternion signs are interchangeable, so compare rotation matrices. Float32
    serialization is allowed; a missing/inverted transform or changed attributes
    are not. The independent COLMAP extent gate remains mandatory.
    """
    data = PlyData.read(str(path))["vertex"].data
    if len(data) != len(means) or not len(data):
        return False, {"count_matches": False}
    def columns(names):
        return np.column_stack([data[name] for name in names]).astype(np.float64)
    xyz = columns(["x", "y", "z"])
    log_scales = columns([f"scale_{i}" for i in range(3)])
    q = columns([f"rot_{i}" for i in range(4)])
    M, t = T[:3, :3], T[:3, 3]
    scale = abs(np.linalg.det(M)) ** (1.0 / 3.0)
    if not np.isfinite(scale) or scale <= 0:
        return False, {"valid_similarity": False}
    rotation = M / scale
    try:
        actual_r = rotation @ Rotation.from_quat(q[:, [1, 2, 3, 0]]).as_matrix()
        expected_r = Rotation.from_quat(quats[:, [1, 2, 3, 0]]).as_matrix()
    except ValueError:
        return False, {"valid_quaternions": False}
    comparisons = {
        "means": (xyz @ M.T + t, means),
        "log_scales": (log_scales + np.log(scale), scales),
        "rotations": (actual_r, expected_r),
        "opacities": (data["opacity"], opacities),
        "sh0": (columns([f"f_dc_{i}" for i in range(3)]), sh0),
        "shN": (columns([f"f_rest_{i}" for i in range(45)]), shN),
    }
    passed = {k: bool(np.allclose(a, b, rtol=2e-5, atol=2e-5))
              for k, (a, b) in comparisons.items()}
    errors = {k: float(np.max(np.abs(a - b))) for k, (a, b) in comparisons.items()}
    return all(passed.values()), {"attributes": passed, "max_absolute_errors": errors}


def filter_invalid(means, scales, quats, opacities, sh0, shN):
    invalid = (
        ~np.isfinite(means).all(axis=1)
        | ~np.isfinite(scales).all(axis=1)
        | ~np.isfinite(quats).all(axis=1)
        | ~np.isfinite(opacities)
        | ~np.isfinite(sh0).all(axis=1)
        | ~np.isfinite(shN).all(axis=1)
    )
    valid = ~invalid
    return (
        means[valid],
        scales[valid],
        quats[valid],
        opacities[valid],
        sh0[valid],
        shN[valid],
        int(invalid.sum()),
    )


def load_colmap_points(sparse_dir: Path) -> np.ndarray:
    manager = SceneManager(str(sparse_dir))
    manager.load_points3D()
    p3d = manager.points3D
    if isinstance(p3d, np.ndarray):
        if p3d.ndim == 2 and p3d.shape[1] == 3:
            return p3d.astype(np.float64)
        raise ValueError(f"unexpected points3D array shape {p3d.shape}")
    return np.array([p.xyz for p in p3d.values()])


def is_pocketworld_sfm(data_dir):
    """Limit the new verification to app-owned independent SfM projects."""
    p = Path(data_dir).resolve()
    return (p.name == "gs_mcmc_dataset" and p.parent.parent.name == "3DGS"
            and p.parent.parent.parent.name.startswith("PocketWorld-SfM-")
            and p.parent.parent.parent.parent == Path("/mnt/data2/services/realityscan-hub/data/projects"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--result-dir", required=True)
    parser.add_argument("--ckpt-step", type=int, required=True)
    parser.add_argument("--out-iteration", type=int, default=30000)
    parser.add_argument("--test-every", type=int, default=8)
    parser.add_argument("--out-ply", default=None)
    args = parser.parse_args()

    os.chdir(GSPLAT_EXAMPLES)
    sys.path.insert(0, str(GSPLAT_EXAMPLES))

    from datasets.colmap import Parser
    from datasets.normalize import transform_points

    data_dir = Path(args.data_dir)
    result_dir = Path(args.result_dir)
    ckpt_path = result_dir / "ckpts" / f"ckpt_{args.ckpt_step}_rank0.pt"
    raw_ply = result_dir / "ply" / f"point_cloud_{args.ckpt_step}.ply"

    if args.out_ply:
        out_ply = Path(args.out_ply)
    else:
        out_ply = (
            result_dir
            / "point_cloud"
            / f"iteration_{args.out_iteration}"
            / "point_cloud.ply"
        )
    out_check = out_ply.parent / "export_check.json"

    if not ckpt_path.is_file():
        print(f"ERROR: missing {ckpt_path}", file=sys.stderr)
        return 1

    colmap_parser = Parser(
        data_dir=str(data_dir), factor=1, normalize=True, test_every=args.test_every
    )
    T = colmap_parser.transform

    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=True)
    splats = ckpt["splats"]
    n_ckpt = splats["means"].shape[0]

    if splats["shN"].shape[1] != 15:
        print(
            f"ERROR: shN has {splats['shN'].shape[1]} bands, expected 15 (sh_degree=3)",
            file=sys.stderr,
        )
        return 1

    means_g = splats["means"].numpy()
    scales_g = splats["scales"].numpy()
    quats_g = splats["quats"].numpy()
    opacities = splats["opacities"].numpy()
    sh0 = splats["sh0"].squeeze(1).numpy()
    shN = splats["shN"].permute(0, 2, 1).reshape(n_ckpt, -1).numpy()

    means_c, scales_c, quats_c, s, R, Minv = transform_splats_to_colmap(
        means_g, scales_g, quats_g, T
    )
    valid = (np.isfinite(means_c).all(axis=1) & np.isfinite(scales_c).all(axis=1)
             & np.isfinite(quats_c).all(axis=1) & np.isfinite(opacities)
             & np.isfinite(sh0).all(axis=1) & np.isfinite(shN).all(axis=1))
    means_c, scales_c, quats_c, opacities, sh0, shN, n_dropped = filter_invalid(
        means_c, scales_c, quats_c, opacities, sh0, shN
    )
    n_written = means_c.shape[0]

    write_3dgs_ply(
        out_ply, means_c, sh0, shN, opacities, scales_c, quats_c, CANONICAL_PROPS
    )

    raw_points = load_colmap_points(data_dir / "sparse" / "0")
    colmap_bbox = percentile_bbox(raw_points)
    exported_bbox = percentile_bbox(means_c)
    exported_med = median_exp_scale0(scales_c)

    transformed = transform_points(T, raw_points)
    max_diff = float(np.max(np.abs(transformed - colmap_parser.points)))
    rot_ok = bool(s > 0 and np.allclose(R @ R.T, np.eye(3), atol=1e-6))
    roundtrip_ok = max_diff < 1e-3 and rot_ok

    check_header = read_ply_property_names(out_ply) == CANONICAL_PROPS and len(CANONICAL_PROPS) == 62
    check_n = n_written == n_ckpt - n_dropped
    check_bbox = bbox_extent_ok(exported_bbox, colmap_bbox)

    raw_med = median_exp_scale0(scales_g[valid])
    unnormalization_ok, written_verification = verify_written_splats(
        out_ply, means_g[valid], scales_g[valid], quats_g[valid],
        opacities, sh0, shN, T)
    if not is_pocketworld_sfm(data_dir):
        # Preserve the existing shared Hub contract for projects outside this app.
        raw_fail_bbox = False
        scale_ratio_ok = False
        if raw_ply.is_file():
            raw = PlyData.read(str(raw_ply)).elements[0].data
            raw_xyz = np.column_stack([raw["x"], raw["y"], raw["z"]])
            raw_scales = np.column_stack([raw["scale_0"], raw["scale_1"], raw["scale_2"]])
            raw_med = median_exp_scale0(raw_scales)
            raw_fail_bbox = not bbox_extent_ok(percentile_bbox(raw_xyz), colmap_bbox)
            expected_ratio = 1.0 / s
            actual_ratio = exported_med / raw_med if raw_med > 0 else 0.0
            scale_ratio_ok = abs(actual_ratio - expected_ratio) / expected_ratio < 0.05
        unnormalization_ok = raw_fail_bbox and scale_ratio_ok

    checks = {
        "header_62_match": bool(check_header),
        "n_written": bool(check_n),
        "transform_roundtrip": bool(roundtrip_ok),
        "bbox_vs_colmap_points": bool(check_bbox),
        "unnormalization_applied": bool(unnormalization_ok),
    }

    export_check = {
        "T": T.tolist(),
        "s": float(s),
        "log_s": float(np.log(s)),
        "N_ckpt": int(n_ckpt),
        "N_dropped": int(n_dropped),
        "N_written": int(n_written),
        "exported_percentile_bbox": exported_bbox,
        "colmap_points_percentile_bbox": colmap_bbox,
        "exported_median_exp_scale0": exported_med,
        "raw_median_exp_scale0": raw_med,
        "written_checkpoint_verification": written_verification,
        "checks": checks,
    }
    with open(out_check, "w") as f:
        json.dump(export_check, f, indent=2)

    print(f"Exported {n_written} Gaussians to {out_ply}")
    print(f"similarity scale s={s:.6f}, median exp(scale_0)={exported_med:.6f}")
    print(f"transform_roundtrip max|diff|={max_diff:.6e}")
    for name, ok in checks.items():
        print(f"  check {name}: {'PASS' if ok else 'FAIL'}")

    if not all(checks.values()):
        print("ERROR: export checks failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
