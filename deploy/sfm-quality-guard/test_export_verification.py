"""Checks actual serialized splats; no CUDA, private data or training required."""
import importlib.util
import pathlib
import tempfile
import unittest

import numpy as np
from plyfile import PlyData
from scipy.spatial.transform import Rotation

path = pathlib.Path(__file__).with_name('100_gs_mcmc_ckpt_to_3dgs_ply.py')
spec = importlib.util.spec_from_file_location('exporter', path)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

class WrittenCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.tmp.name) / 'scene.ply'
        rng = np.random.default_rng(52)
        self.means = rng.normal(size=(128, 3)).astype('f4')
        self.scales = rng.uniform(-5, -2, size=(128, 3)).astype('f4')
        self.quats = Rotation.random(128, random_state=rng).as_quat()[:, [3, 0, 1, 2]]
        self.opacity = rng.normal(size=128).astype('f4')
        self.sh0 = rng.normal(size=(128, 3)).astype('f4')
        self.shN = rng.normal(size=(128, 45)).astype('f4')

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, scale=0.31):
        self.T = np.eye(4)
        self.T[:3, :3] = scale * Rotation.from_euler('xyz', [25, -30, 80], degrees=True).as_matrix()
        self.T[:3, 3] = [1.2, -0.5, 2.1]
        means, scales, quats, *_ = exporter.transform_splats_to_colmap(self.means, self.scales, self.quats, self.T)
        exporter.write_3dgs_ply(self.path, means, self.sh0, self.shN, self.opacity, scales, quats, exporter.CANONICAL_PROPS)

    def verify(self):
        return exporter.verify_written_splats(self.path, self.means, self.scales, self.quats, self.opacity, self.sh0, self.shN, self.T)[0]

    def corrupt(self, field, delta):
        ply = PlyData.read(self.path, mmap=False)
        ply['vertex'].data[field][0] += delta
        ply.write(self.path)

    def test_serialized_similarities_including_unit_scale(self):
        for scale in [0.01, 0.31, 1, 100]:
            with self.subTest(scale=scale):
                self.write(scale)
                self.assertTrue(self.verify())

    def test_missing_inverse_transform_fails(self):
        self.write()
        exporter.write_3dgs_ply(self.path, self.means, self.sh0, self.shN, self.opacity, self.scales, self.quats, exporter.CANONICAL_PROPS)
        self.assertFalse(self.verify())

    def test_geometry_and_appearance_corruption_fails(self):
        for field in ['x', 'scale_1', 'rot_0', 'opacity', 'f_dc_2', 'f_rest_44']:
            with self.subTest(field=field):
                self.write()
                self.corrupt(field, 0.1)
                self.assertFalse(self.verify())

    def test_quaternion_sign_is_equivalent(self):
        self.write()
        ply = PlyData.read(self.path, mmap=False)
        for i in range(4):
            ply['vertex'].data[f'rot_{i}'] *= -1
        ply.write(self.path)
        self.assertTrue(self.verify())

    def test_scope_excludes_other_hub_projects(self):
        root = '/mnt/data2/services/realityscan-hub/data/projects/'
        self.assertTrue(exporter.is_pocketworld_sfm(root + 'PocketWorld-SfM-test/3DGS/abc/gs_mcmc_dataset'))
        self.assertFalse(exporter.is_pocketworld_sfm(root + 'Other/3DGS/abc/gs_mcmc_dataset'))
        self.assertFalse(exporter.is_pocketworld_sfm('/tmp/PocketWorld-SfM-test/3DGS/abc/gs_mcmc_dataset'))

    def test_extent_gate_still_rejects_expanded_or_collapsed_models(self):
        ref = exporter.percentile_bbox(self.means)
        self.assertTrue(exporter.bbox_extent_ok(ref, ref))
        for factor in [0.1, 3, 7.08455]:
            self.assertFalse(exporter.bbox_extent_ok(exporter.percentile_bbox(self.means * factor), ref))

if __name__ == '__main__':
    unittest.main()
