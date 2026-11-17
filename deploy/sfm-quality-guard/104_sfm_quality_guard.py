#!/usr/bin/env python3
"""Bounded, source-local recovery for image-only COLMAP initialization.

No old project, camera, pose or Gaussian output is read. At most three mapper
attempts are made. Failed models and each quality decision remain in this run.
"""
import argparse
import json
import math
import pathlib
import re
import shutil
import sqlite3
import statistics
import struct
import subprocess
import sys


def natural(value):
    return [(0, int(part)) if part.isdigit() else (1, part.lower())
            for part in re.split(r"(\d+)", value)]


def image_names(directory):
    root = pathlib.Path(directory)
    names = sorted((p.relative_to(root).as_posix() for p in root.rglob("*")
                    if p.is_file() and p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}), key=natural)
    if len(names) < 2 or any("\n" in n or "\r" in n for n in names):
        raise ValueError("Need at least two image names without line breaks")
    return names


def save(path, value):
    pathlib.Path(path).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def candidates(database):
    with sqlite3.connect(pathlib.Path(database).resolve().as_uri() + "?mode=ro", uri=True) as db:
        images = dict(db.execute("SELECT image_id,name FROM images"))
        ordered = sorted(images.values(), key=natural)
        rank = {name: i for i, name in enumerate(ordered)}
        count = len(ordered)
        minimum_gap = min(max(2, math.ceil(count * .03)), max(1, count - 1))
        pairs = []
        for pair_id, inliers, config in db.execute("SELECT pair_id,rows,config FROM two_view_geometries WHERE rows >= 100"):
            # Installed COLMAP scene/two_view_geometry.h: essential/fundamental/
            # non-panoramic calibrated rig only. Homographies are not seed pairs.
            if config not in (2, 3, 9):
                continue
            a, b = divmod(pair_id, 2147483647)
            if a not in images or b not in images:
                continue
            gap = abs(rank[images[a]] - rank[images[b]])
            if gap < minimum_gap:
                continue
            pairs.append({"image_id1": a, "image_id2": b,
                          "names": [images[a], images[b]], "inliers": inliers,
                          "configuration": config, "ordinal_gap": gap,
                          "midpoint": (rank[images[a]] + rank[images[b]]) / 2,
                          "score": inliers * math.sqrt(min(gap, max(2, count // 5)))})
    pairs.sort(key=lambda p: (-p["score"], sorted(p["names"])))
    selected = []
    # Choose two distinct portions of the current sequence, when available.
    for pair in pairs:
        if all(abs(pair["midpoint"] - prior["midpoint"]) >= max(2, count / 8) for prior in selected):
            selected.append(pair)
        if len(selected) == 2:
            break
    for pair in pairs:
        if len(selected) == 2:
            break
        if pair not in selected:
            selected.append(pair)
    return count, selected


def unpack(handle, fmt):
    size = struct.calcsize(fmt)
    value = handle.read(size)
    if len(value) != size:
        raise ValueError("Truncated COLMAP model")
    return struct.unpack(fmt, value)


def quality(model, expected):
    model = pathlib.Path(model)
    report = {"accepted": False, "expected_images": expected,
              "minimum_registered": min(expected, max(3, math.ceil(expected * .5))),
              "minimum_points": 100, "maximum_median_reprojection_error": 4.0}
    try:
        with (model / "images.bin").open("rb") as handle:
            registered = unpack(handle, "<Q")[0]
            if registered > expected:
                raise ValueError("Registered count exceeds input images")
            for _ in range(registered):
                image = unpack(handle, "<idddddddi")
                if not all(math.isfinite(x) for x in image[1:8]):
                    raise ValueError("Non-finite image pose")
                for _ in range(4096):
                    byte = handle.read(1)
                    if byte == b"\x00":
                        break
                    if not byte:
                        raise ValueError("Truncated image name")
                else:
                    raise ValueError("Oversized image name")
                points2d = unpack(handle, "<Q")[0]
                if points2d > 10000000 or len(handle.read(points2d * 24)) != points2d * 24:
                    raise ValueError("Invalid image observations")
            if handle.read(1):
                raise ValueError("Unexpected image model bytes")
        errors = []
        with (model / "points3D.bin").open("rb") as handle:
            points = unpack(handle, "<Q")[0]
            if points > 10000000:
                raise ValueError("Oversized sparse model")
            for _ in range(points):
                record = unpack(handle, "<QdddBBBdQ")
                track = record[-1]
                if not all(math.isfinite(v) for v in record[1:4]) or not math.isfinite(record[-2]) or record[-2] < 0:
                    raise ValueError("Non-finite sparse geometry/error")
                if track < 2 or track > expected or len(handle.read(track * 8)) != track * 8:
                    raise ValueError("Invalid sparse point track")
                errors.append(record[-2])
            if handle.read(1):
                raise ValueError("Unexpected sparse model bytes")
        median = statistics.median(errors) if errors else None
        report.update(registered_images=registered, sparse_points=points, median_reprojection_error=median)
        report["accepted"] = (registered >= report["minimum_registered"] and points >= 100
                              and median is not None and median <= 4.0)
        if not report["accepted"]:
            report["reason"] = "Sparse model below registration/point/error thresholds"
    except (OSError, ValueError, struct.error) as error:
        report["reason"] = str(error)
    return report


def map_with_guard(database, output, command):
    if not command or "--output_path" not in command:
        raise ValueError("Expected explicit COLMAP mapper command")
    count, selected = candidates(database)
    # The denominator is the complete source list, not a potentially reduced
    # database after feature extraction. Missing or duplicate images fail closed.
    source_list = pathlib.Path(database).resolve().parent / "sfm-image-order.txt"
    expected_names = source_list.read_text(encoding="utf-8").splitlines()
    if len(expected_names) < 2 or len(set(expected_names)) != len(expected_names):
        raise ValueError("Invalid complete source image list")
    with sqlite3.connect(pathlib.Path(database).resolve().as_uri() + "?mode=ro", uri=True) as db:
        actual_names = [row[0] for row in db.execute("SELECT name FROM images")]
    if sorted(actual_names) != sorted(expected_names):
        raise ValueError("Feature database images differ from the complete source image list")
    if count != len(expected_names):
        raise ValueError("Source image count differs from the feature database")
    count = len(expected_names)
    output = pathlib.Path(output).resolve()
    guard = output.parent / "sfm_quality_guard"
    guard.mkdir(exist_ok=False)
    save(guard / "candidates.json", {"source": "current COLMAP database only", "image_count": count,
                                    "maximum_mapper_attempts": 3, "candidates": selected})
    reports = []
    for index, pair in enumerate([None] + selected):
        destination = guard / ("attempt-" + str(index))
        destination.mkdir()
        args = list(command)
        args[args.index("--output_path") + 1] = str(destination)
        args += ["--default_random_seed", "0", "--Mapper.random_seed", "0", "--Mapper.num_threads", "1"]
        if pair:
            args += ["--Mapper.init_image_id1", str(pair["image_id1"]), "--Mapper.init_image_id2", str(pair["image_id2"])]
        print("=== [101/3] guarded mapper attempt " + str(index) + ": " + json.dumps(pair), flush=True)
        code = subprocess.run(args, check=False).returncode
        report = quality(destination / "0", count)
        report.update(attempt=index, mapper_exit_code=code, initialization=pair)
        if code != 0:
            report["accepted"] = False
        reports.append(report)
        save(guard / ("attempt-" + str(index) + "-quality.json"), report)
        save(guard / "summary.json", reports)
        print("=== sparse quality: " + json.dumps(report), flush=True)
        if report["accepted"]:
            if (output / "0").exists():
                raise ValueError("Refusing to replace an existing sparse model")
            shutil.copytree(destination / "0", output / "0")
            return 0
    print("ERROR: bounded SfM initialization attempts failed quality validation", file=sys.stderr)
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["list", "map", "check", "candidates"])
    parser.add_argument("--images")
    parser.add_argument("--database")
    parser.add_argument("--output", required=True)
    args, command = parser.parse_known_args()
    if command and command[0] == "--":
        command = command[1:]
    if args.mode == "list":
        pathlib.Path(args.output).write_text("\n".join(image_names(args.images)) + "\n", encoding="utf-8")
        return 0
    if args.mode == "candidates":
        count, pairs = candidates(args.database)
        save(args.output, {"image_count": count, "candidates": pairs})
        return 0
    if args.mode == "check":
        count, _ = candidates(args.database)
        report = quality(args.output, count)
        print(json.dumps(report))
        return 0 if report["accepted"] else 1
    return map_with_guard(args.database, args.output, command)


if __name__ == "__main__":
    sys.exit(main())
