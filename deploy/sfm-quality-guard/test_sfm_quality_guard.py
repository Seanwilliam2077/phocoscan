"""Synthetic control-flow fixtures only; never invokes COLMAP or a GPU."""
import importlib.util
import pathlib
import sqlite3
import struct
import tempfile
import types
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("guard", pathlib.Path(__file__).with_name("104_sfm_quality_guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def model(directory, points=100, registered=6):
    directory.mkdir(parents=True)
    with (directory / "images.bin").open("wb") as handle:
        handle.write(struct.pack("<Q", registered))
        for i in range(registered):
            handle.write(struct.pack("<idddddddi", i + 1, 1, 0, 0, 0, i, 0, 0, 1))
            handle.write((f"image_{i+1:06d}.jpg").encode() + b"\x00")
            handle.write(struct.pack("<Q", 0))
    with (directory / "points3D.bin").open("wb") as handle:
        handle.write(struct.pack("<Q", points))
        for i in range(points):
            handle.write(struct.pack("<QdddBBBdQ", i, i, 0, 1, 1, 2, 3, .5, 2))
            handle.write(struct.pack("<iiii", 1, 0, 2, 0))


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.database = self.root / "database.db"
        self.output = self.root / "sparse"
        self.output.mkdir()
        self.names = [f"image_{i:06d}.jpg" for i in range(1, 7)]
        (self.root / "sfm-image-order.txt").write_text("\n".join(self.names) + "\n")
        with sqlite3.connect(self.database) as db:
            db.execute("CREATE TABLE images(image_id INTEGER,name TEXT)")
            db.executemany("INSERT INTO images VALUES (?,?)", enumerate(self.names, 1))
            db.execute("CREATE TABLE two_view_geometries(pair_id INTEGER,rows INTEGER,config INTEGER)")
            db.executemany("INSERT INTO two_view_geometries VALUES (?,?,?)", [
                (1 * 2147483647 + 2, 1000, 6),
                (1 * 2147483647 + 3, 300, 3),
                (4 * 2147483647 + 6, 290, 2),
            ])
        self.command = ["SYNTHETIC-COLMAP-NEVER-EXECUTED", "mapper", "--output_path", str(self.output)]

    def test_rejects_homography_seed_and_uses_current_filename_order(self):
        count, pairs = guard.candidates(self.database)
        self.assertEqual(count, 6)
        self.assertEqual(len(pairs), 2)
        self.assertTrue(all(p["configuration"] in [2, 3, 9] for p in pairs))
        self.assertEqual(pairs[0]["names"], [self.names[0], self.names[2]])

    def test_real_binary_quality_checks_reject_empty_or_partial_model(self):
        model(self.root / "empty", points=0)
        model(self.root / "partial", registered=2)
        model(self.root / "valid")
        self.assertFalse(guard.quality(self.root / "empty", 6)["accepted"])
        self.assertFalse(guard.quality(self.root / "partial", 6)["accepted"])
        self.assertTrue(guard.quality(self.root / "valid", 6)["accepted"])

    def test_recovers_only_after_quality_pass_and_preserves_failed_attempt(self):
        calls = []
        def run(args, check):
            calls.append(args)
            target = pathlib.Path(args[args.index("--output_path") + 1]) / "0"
            model(target, points=0 if len(calls) == 1 else 100)
            return types.SimpleNamespace(returncode=0)
        with mock.patch.object(guard.subprocess, "run", side_effect=run):
            code = guard.map_with_guard(self.database, self.output, self.command)
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 2)
        self.assertTrue((self.root / "sfm_quality_guard/attempt-0/0/points3D.bin").is_file())
        self.assertTrue(guard.quality(self.output / "0", 6)["accepted"])

    def test_failed_attempts_are_bounded_without_promoting_output(self):
        def run(args, check):
            model(pathlib.Path(args[args.index("--output_path") + 1]) / "0", points=0)
            return types.SimpleNamespace(returncode=0)
        with mock.patch.object(guard.subprocess, "run", side_effect=run) as runner:
            code = guard.map_with_guard(self.database, self.output, self.command)
        self.assertEqual(code, 1)
        self.assertEqual(runner.call_count, 3)
        self.assertFalse((self.output / "0").exists())

    def test_feature_drop_cannot_lower_registration_denominator(self):
        with sqlite3.connect(self.database) as db:
            db.execute("DELETE FROM images WHERE image_id=6")
        with mock.patch.object(guard.subprocess, "run") as runner:
            with self.assertRaisesRegex(ValueError, "complete source image list"):
                guard.map_with_guard(self.database, self.output, self.command)
        runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
