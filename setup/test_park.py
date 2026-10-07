import unittest

import park


class ParkTest(unittest.TestCase):
    def test_labels_read_like_the_park_editor(self):
        self.assertEqual(park.label('ab_MegaParkRollIn'), 'Mega Park Roll In')
        self.assertEqual(park.label('ai_MegaQuaterPipe90Corner'), 'Mega Quarter Pipe90 Corner')
        self.assertEqual(park.label('bd_DMO_UN_DumpsterOpen'), 'DMO UN Dumpster Open')

    def test_skate_metres_y_up_become_source_inches_z_up(self):
        x, y, z = park.source(1, 2, 3)
        self.assertAlmostEqual(x, 39.3701)
        self.assertAlmostEqual(y, 3 * 39.3701)
        self.assertAlmostEqual(z, 2 * 39.3701)

    def test_disc_paths_are_lowercased_for_images(self):
        self.assertIn('data/content/worlddist_megapark.big', park.FROM_DISC)
        self.assertIn('data/content/worlddist_maloofmoneycup.big', park.FROM_DISC)

    def test_cutout_needs_clear_pixels(self):
        from skate3_formats.world_textures import png
        solid = png(2, 2, bytes([9, 9, 9, 255]) * 4)
        leaf = png(2, 2, bytes([9, 9, 9, 255]) * 3 + bytes([9, 9, 9, 0]))
        mask = png(2, 2, bytes([9, 9, 9, 128]) * 4)
        self.assertFalse(park.cutout(solid))
        self.assertTrue(park.cutout(leaf))
        self.assertFalse(park.cutout(mask))

    def test_label_fixes_typos(self):
        self.assertEqual(park.label('ab_MegaQuaterPipe'), 'Mega Quarter Pipe')
        self.assertEqual(park.label('quaterpipeescalator'), 'quarterpipeescalator')


if __name__ == '__main__':
    unittest.main()
