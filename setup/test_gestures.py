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

    def test_shapes_are_clamped(self):
        shape = gestures.held_shape([hands(20), hands(170), hands(170)], hands(20))
        self.assertEqual(shape['L'][0], [120.0, 120.0, 120.0])

    @unittest.skipUnless(ENGINE and ANIM, 'needs SKATE3_ENGINE and SKATE3_ANIM')
    def test_real_disc_peace_sign_has_two_fingers_up(self):
        with tempfile.TemporaryDirectory() as out:
            self.assertTrue(gestures.export(ENGINE, ANIM, out, lambda _: None))
            shapes = json.loads((Path(out) / 'hands.json').read_text())['gestures']
        self.assertEqual(len(shapes), 37)
        thumb, index, middle, ring, pinky = shapes['peace']['R']
        self.assertLess(max(index + middle), 20)
        self.assertGreater(min(ring + pinky), 45)


if __name__ == '__main__':
    unittest.main()
