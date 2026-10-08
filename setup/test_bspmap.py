import struct
import unittest

import bspmap


def lump(data, index):
    offset, length = struct.unpack_from('<ii', data, 8 + index * 16)
    return data[offset:offset + length]


class BspMapTest(unittest.TestCase):
    def setUp(self):
        self.data = bspmap.build('map_maloof')

    def records(self, index, fmt):
        raw = lump(self.data, index)
        size = struct.calcsize(fmt)
        self.assertEqual(len(raw) % size, 0)
        return [struct.unpack_from(fmt, raw, i) for i in range(0, len(raw), size)]

    def leaf_at(self, point):
        planes = self.records(bspmap.LUMP_PLANES, '<4fi')
        nodes = self.records(bspmap.LUMP_NODES, '<3i3h3hHHhh')
        n = 0
        while n >= 0:
            plane = planes[nodes[n][0]]
            side = sum(plane[k] * point[k] for k in range(3)) - plane[3]
            n = nodes[n][1] if side >= 0 else nodes[n][2]
        return self.records(bspmap.LUMP_LEAFS, '<ihH3h3hHHHHh2x')[-n - 1]

    def test_header(self):
        self.assertEqual(self.data[:4], b'VBSP')
        self.assertEqual(struct.unpack_from('<i', self.data, 4)[0], 20)

    def test_field_is_open_and_outside_is_solid(self):
        self.assertEqual(self.leaf_at((0, 0, 100))[0], 0)
        for p in ((0, 0, -10), (0, 0, bspmap.HEIGHT + 10), (bspmap.HALF + 10, 0, 5), (0, -bspmap.HALF - 10, 5)):
            self.assertEqual(self.leaf_at(p)[0], bspmap.CONTENTS_SOLID, p)

    def test_planes_come_in_opposite_pairs(self):
        planes = self.records(bspmap.LUMP_PLANES, '<4fi')
        for a, b in zip(planes[::2], planes[1::2]):
            self.assertEqual(tuple(-x for x in a[:4]), b[:4])

    def test_faces_face_into_the_field_clockwise(self):
        planes = self.records(bspmap.LUMP_PLANES, '<4fi')
        verts = self.records(bspmap.LUMP_VERTEXES, '<3f')
        edges = self.records(bspmap.LUMP_EDGES, '<2H')
        surfedges = [s[0] for s in self.records(bspmap.LUMP_SURFEDGES, '<i')]
        for face in self.records(bspmap.LUMP_FACES, '<HBBihhhh4Bif2i2iiHHI'):
            v = [verts[edges[abs(s)][0 if s >= 0 else 1]] for s in surfedges[face[3]:face[3] + face[4]]]
            normal = planes[face[0]][:3]
            # Facing the field: the field's middle is in front.
            self.assertGreater(sum(normal[k] * ((0, 0, 100)[k] - v[0][k]) for k in range(3)), 0)
            cross = bspmap._cross(bspmap._sub(v[1], v[0]), bspmap._sub(v[2], v[0]))
            self.assertLess(bspmap._dot(cross, normal), 0)

    def test_names_its_park(self):
        self.assertIn(b'"skate3_park" "map_maloof"', lump(self.data, bspmap.LUMP_ENTITIES))


if __name__ == '__main__':
    unittest.main()
