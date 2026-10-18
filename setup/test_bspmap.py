"""The generated gm_skate3_* maps carry what the engine needs to load them
and trace on them."""
import struct, unittest

import bspmap, physbox

LUMP_LEAFS, LUMP_PHYSCOLLIDE = 10, 29


def lumps(data):
    return [struct.unpack_from('<iiii', data, 8 + 16 * i) for i in range(64)]


class MapTest(unittest.TestCase):
    def test_header_versions(self):
        data = bspmap.build('map_maloof')
        self.assertEqual(data[:4], b'VBSP')
        table = lumps(data)
        self.assertEqual(table[LUMP_LEAFS][2], 1)
        self.assertEqual(table[bspmap.LUMP_FACES][2], 1)
        self.assertEqual(table[bspmap.LUMP_LIGHTING][2], 1)

    def test_world_has_collision_solid(self):
        data = bspmap.build('map_maloof')
        offset, length, _, _ = lumps(data)[LUMP_PHYSCOLLIDE]
        model, size, keys, count = struct.unpack_from('<4i', data, offset)
        self.assertEqual((model, count), (0, 1))
        solid = data[offset + 16 + 4:offset + 16 + 4 + size - 4]
        self.assertEqual(solid[:4], b'VPHY')
        # the lump ends with the terminating record
        self.assertEqual(struct.unpack_from('<4i', data, offset + length - 16), (-1, 0, 0, 0))
        self.assertEqual(offset + 16 + size + keys + 16, offset + length)

    def test_box_points_cover_the_ground(self):
        solid = physbox.solid((-100, -200, -64), (100, 200, 0))
        points = [struct.unpack_from('<3f', solid, 284 + 16 * i) for i in range(8)]
        xs, ys, zs = zip(*points)
        self.assertAlmostEqual(max(xs) - min(xs), 200 * physbox.INCH, places=4)
        self.assertAlmostEqual(max(zs) - min(zs), 400 * physbox.INCH, places=4)
        self.assertAlmostEqual(max(ys) - min(ys), 64 * physbox.INCH, places=4)


if __name__ == '__main__':
    unittest.main()
