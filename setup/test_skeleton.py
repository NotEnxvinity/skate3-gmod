"""Hall of Meat's skeleton: which main bone carries what, how a piece splits
into rigid chunks, and the file the Lua side reads. The engine's own reader is
only needed for the last test (SKATE3_ENGINE, plus SKATE3_MARQUEE pointing at
a marquee.big from a real disc)."""
from pathlib import Path
import os, tempfile, unittest

import skeleton

ENGINE = os.environ.get('SKATE3_ENGINE')
MARQUEE = os.environ.get('SKATE3_MARQUEE')
PARENTS = {'lefthand': 'leftforearm', 'lefthandindex1': 'lefthand', 'lefthandindex2': 'lefthandindex1',
           'neck1': 'neck', 'leftforearm': 'leftarm', 'leftarm': 'leftshoulder', 'leftshoulder': 'spine3'}


def identity(shift=(0., 0., 0.)):
    return [[1., 0., 0., 0.], [0., 1., 0., 0.], [0., 0., 1., 0.], [*shift, 1.]]


class SkeletonTest(unittest.TestCase):
    def test_bones_the_engine_does_not_give_lua_ride_their_nearest_main_ancestor(self):
        self.assertEqual(skeleton.main_bone('LeftHandIndex2', PARENTS), 'LEFTHAND')
        self.assertEqual(skeleton.main_bone('Neck1', PARENTS), 'NECK')
        self.assertEqual(skeleton.main_bone('LeftFoot', PARENTS), 'LEFTFOOT')
        self.assertIsNone(skeleton.main_bone('Unheard_Of', PARENTS))

    def test_the_bone_decides_the_side_not_the_discs_piece_name(self):
        # The disc's Calf_Left is skinned to the right leg.
        self.assertEqual(skeleton.part_of('Calf_Left', 'RIGHTLEG'), 'rshin')
        self.assertEqual(skeleton.part_of('Calf_Right', 'LEFTFOOT'), 'lshin')
        self.assertEqual(skeleton.part_of('Toes_Left', 'LEFTTOEBASE'), 'lfoot')
        self.assertEqual(skeleton.part_of('Rib_Cage', 'LEFTSHOULDER'), 'lcollar')
        self.assertEqual(skeleton.part_of('Rib_Cage', 'SPINE2'), 'ribs')
        self.assertEqual(skeleton.part_of('Skull', 'HEAD'), 'skull')
        self.assertEqual(skeleton.part_of('Lower_Spine', 'SPINE1'), 'spine')

    def test_a_piece_splits_by_the_bone_carrying_most_of_each_triangle(self):
        import numpy as np
        ibp = {'HIPS': np.array(identity()), 'SPINE': np.array(identity((0., -1., 0.)))}
        mesh = {
            'positions': [(0., 0., 0.), (1., 0., 0.), (0., 1., 0.), (0., 2., 0.), (1., 2., 0.), (0., 3., 0.)],
            'normals': [(0., 0., 1.)] * 6,
            'uvs': [(0., 0.)] * 6,
            # Triangle one is all hips; triangle two leans on the spine.
            'skin_bones': [(0, 1, 0, 0)] * 3 + [(1, 0, 0, 0)] * 3,
            'skin_weights': [(1., 0., 0., 0.)] * 3 + [(0.9, 0.1, 0., 0.)] * 3,
            'indices': [0, 1, 2, 3, 4, 5],
        }
        groups = skeleton.groups_of('Hips', mesh, ['Hips', 'Spine'], ibp, {})
        self.assertEqual(sorted(groups), [('HIPS', 'pelvis'), ('SPINE', 'pelvis')])
        verts, tris = groups[('SPINE', 'pelvis')]
        self.assertEqual(tris, [(0, 1, 2)])
        # The spine is bound a metre lower (its inverse bind moves points -1 in
        # skate Y); Source is Z up, in inches.
        self.assertAlmostEqual(verts[0][2], (2. - 1.) / skeleton.INCH, places=3)
        self.assertAlmostEqual(verts[0][4], -1.0, places=5)  # a +Z skate normal is -Y in Source

    def test_the_file_reads_back_as_written(self):
        groups = {('HEAD', 'skull'): ([(1., 2., 3., 0., 0., 1., .25, .5)] * 3, [(0, 1, 2)]),
                  ('LEFTFOOT', 'lfoot'): ([(0.5, 0., 0., 1., 0., 0., 0., 1.)] * 4, [(0, 1, 2), (2, 1, 3)])}
        back = skeleton.decode(skeleton.encode(groups))
        self.assertEqual(sorted(back), sorted(groups))
        for key, (verts, tris) in groups.items():
            self.assertEqual(back[key][1], tris)
            for a, b in zip(back[key][0], verts):
                for x, y in zip(a, b):
                    self.assertAlmostEqual(x, y, places=6)
        with self.assertRaises(ValueError):
            skeleton.decode(b'nope')

    def test_a_disc_without_marquee_keeps_the_xray(self):
        said = []
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(skeleton.export(ENGINE or tmp, tmp, Path(tmp) / 'out', said.append))
        self.assertTrue(said)

    @unittest.skipUnless(ENGINE and MARQUEE, 'SKATE3_ENGINE and SKATE3_MARQUEE not set')
    def test_the_real_disc_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            game = Path(tmp) / 'game'
            (game / 'data/content').mkdir(parents=True)
            os.symlink(MARQUEE, game / 'data/content/marquee.big')
            out = Path(tmp) / 'out'
            self.assertTrue(skeleton.export(ENGINE, game, out, lambda _: None))
            groups = skeleton.decode((out / 'hom.bin').read_bytes())
            parts = {part for _, part in groups}
            self.assertEqual(parts, {'skull', 'spine', 'ribs', 'pelvis', 'lcollar', 'rcollar', 'larm', 'rarm', 'lforearm',
                                     'rforearm', 'lhand', 'rhand', 'lfemur', 'rfemur', 'lshin', 'rshin', 'lfoot', 'rfoot'})
            self.assertTrue(all(bone in skeleton.BODY_BONES for bone, _ in groups))
            self.assertEqual(sum(len(t) for _, t in groups.values()), 16805)
            self.assertTrue((out / 'hom.png').is_file())


if __name__ == '__main__':
    unittest.main()
