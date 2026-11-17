"""The D-pad gestures' hand shapes: how a finger joint's turn reads as a
bend, and which frames of a gesture preview count as the gesture held. The
last test needs the engine (SKATE3_ENGINE) and a converted anim folder
(SKATE3_ANIM, assets/private/stock/data/anim from a real disc)."""
from pathlib import Path
import json, math, os, tempfile, unittest

import gestures

ENGINE = os.environ.get('SKATE3_ENGINE')
ANIM = os.environ.get('SKATE3_ANIM')


def z_turn(degrees):
    """A quaternion (x, y, z, w) curling a finger by `degrees`."""
    half = math.radians(-degrees) / 2
    return (0.0, 0.0, math.sin(half), math.cos(half))


def hands(bend):
    """Both hands with every joint at `bend` degrees."""
    return [[[float(bend)] * 3 for _ in range(5)] for _ in range(2)]


class GestureTest(unittest.TestCase):
    def test_a_z_turn_reads_as_that_many_degrees_of_curl(self):
        for degrees in (-20, 0, 45, 90):
            self.assertAlmostEqual(gestures.bend(z_turn(degrees)), degrees, places=4)

    def test_every_catalog_gesture_has_a_preview_clip(self):
        self.assertEqual(len(gestures.CLIPS), 37)

    def test_the_held_shape_is_the_long_still_run_not_the_wind_up(self):
        relaxed = hands(20)
        # Relaxed, a quick swing through a fist, then a long flat hand (Spock).
        track = [hands(20)] * 5 + [hands(50), hands(80), hands(50)] + [hands(-5)] * 12 + [hands(20)] * 5
        shape = gestures.held_shape(track, relaxed)
        self.assertEqual(set(shape), {'R', 'L'})
        self.assertEqual(shape['R'][1], [-5.0, -5.0, -5.0])

    def test_a_frame_without_the_bind_pose_has_no_aim(self):
        track = [hands(20)] * 3 + [hands(80)] * 6
        shape = gestures.held_shape(track, hands(20), [None] * len(track))
        self.assertNotIn('aimR', shape)

    def test_aims_are_averaged_over_the_held_frames(self):
        track = [hands(20)] * 3 + [hands(80)] * 6
        up = [[[(0.0, 0.0, 1.0)] * 3] * 5] * 2
        ahead = [[[(1.0, 0.0, 0.0)] * 3] * 5] * 2
        shape = gestures.held_shape(track, hands(20), [ahead] * 3 + [up] * 6)
        self.assertEqual(shape['aimL'][2][1], [0.0, 0.0, 1.0])

    def test_everyday_poses_need_every_source(self):
        aims = [[[(1.0, 0.0, 0.0)] * 3] * 5] * 2
        shapes = {'fists': {'aimR': 1, 'aimL': 2}, 'airplane': {'aimR': 3, 'aimL': 4}}
        poses = gestures.everyday_poses(shapes, {'fists': [aims], 'airplane': [aims]})
        self.assertEqual(set(poses), {'relaxed', 'grip', 'open'})
        self.assertEqual(poses['grip'], {'aimR': 1, 'aimL': 2})
        self.assertEqual(gestures.everyday_poses({'fists': shapes['fists']}, {'fists': [aims]}), {})
        self.assertEqual(gestures.everyday_poses(shapes, {'fists': [None]}), {})

    def test_shapes_are_clamped(self):
        shape = gestures.held_shape([hands(20), hands(170), hands(170)], hands(20))
        self.assertEqual(shape['L'][0], [120.0, 120.0, 120.0])

    @unittest.skipUnless(ENGINE and ANIM, 'needs SKATE3_ENGINE and SKATE3_ANIM')
    def test_real_disc_peace_sign_has_two_fingers_up(self):
        with tempfile.TemporaryDirectory() as out:
            self.assertTrue(gestures.export(ENGINE, ANIM, out, lambda _: None))
            made = json.loads((Path(out) / 'hands.json').read_text())
            shapes, poses = made['gestures'], made['poses']
        self.assertEqual(len(shapes), 37)
        thumb, index, middle, ring, pinky = shapes['peace']['R']
        self.assertLess(max(index + middle), 20)
        self.assertGreater(min(ring + pinky), 45)
        # Where the bones point, in the hand's frame (x to the knuckles, y
        # across them to the pinky, z out of the palm): a peace sign's index
        # and middle point ahead, ring and pinky dive into the palm.
        thumb, index, middle, ring, pinky = shapes['peace']['aimR']
        self.assertGreater(min(index[0][0], middle[0][0], middle[2][0]), 0.8)
        self.assertGreater(min(ring[0][2], pinky[0][2]), 0.8)
        # Thumbs up: the thumb sticks out on the index side over a fist.
        thumb, index = shapes['fonz_eh']['aimR'][:2]
        self.assertLess(max(j[1] for j in thumb), -0.7)
        self.assertLess(index[1][0], -0.8)
        # The everyday hands: an open hand points every finger ahead, a grip
        # curls them back into the palm, relaxed sits in between.
        for side in ('aimR', 'aimL'):
            for finger in poses['open'][side][1:]:
                self.assertGreater(min(j[0] for j in finger), 0.9)
            for finger in poses['grip'][side][1:]:
                self.assertLess(finger[1][0], -0.5)
            for finger in poses['relaxed'][side][1:]:
                self.assertGreater(finger[0][0], 0.6)
                self.assertGreater(finger[2][2], 0.2)
        for side in ('aimR', 'aimL'):
            for finger in shapes['shaka'][side]:
                for x, y, z in finger:
                    self.assertAlmostEqual(x * x + y * y + z * z, 1, places=2)


if __name__ == '__main__':
    unittest.main()
