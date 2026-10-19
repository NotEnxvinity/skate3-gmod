"""The collision reader keeps what it can read of a park's collision."""
import struct, unittest

from skate3_formats import retail_collision_mesh as rcm

QUAD = [(0, 0, 0), (0, 1, 0), (1, 0, 0), (1, 1, 0)]


def cluster(units, verts=QUAD):
    """An uncompressed cluster holding `units` (raw bytes)."""
    body = b''.join(struct.pack('>3f', *v) + b'\0' * 4 for v in verts)
    units = b''.join(units)
    head = bytearray(16)
    struct.pack_into('>HHH', head, 0, 0, len(units), len(verts))
    head[10], head[12] = len(verts), 0
    data = bytearray(bytes(head) + body + units)
    struct.pack_into('>H', data, 8, len(data))
    return bytes(data)


def mesh(clusters, triangles):
    table = 96 + 48
    offsets, at = [], table + 4 * len(clusters)
    for c in clusters:
        offsets.append(at)
        at += len(c)
    data = bytearray(at)
    struct.pack_into('>3f', data, 0, 0, 0, 0)
    struct.pack_into('>3f', data, 16, 1, 1, 1)
    struct.pack_into('>I', data, 40, triangles)
    struct.pack_into('>II', data, 48, 96, table)
    struct.pack_into('>f', data, 56, 1.0)
    struct.pack_into('>I', data, 64, len(clusters))
    struct.pack_into('>I', data, 80, at)
    for i, (o, c) in enumerate(zip(offsets, clusters)):
        struct.pack_into('>I', data, table + 4 * i, o)
        data[o:o + len(c)] = c
    return bytes(data)


def counted(units, verts=QUAD):
    c = bytearray(cluster(units, verts))
    struct.pack_into('>H', c, 0, len(units))
    return bytes(c)


TRI = bytes([1, 0, 1, 2])
STRIP = bytes([3, 2, 0, 1, 2, 3])  # two triangles over four indices
BAD = bytes([9, 0, 1, 2])  # a unit type nothing reads


class LenientCollisionTest(unittest.TestCase):
    def test_strip_units_read_as_triangles(self):
        got = rcm.decode_clustered_mesh(mesh([counted([STRIP])], 2))
        self.assertEqual(len(got.triangles), 2)

    def test_strict_by_default(self):
        with self.assertRaises(ValueError):
            rcm.decode_clustered_mesh(mesh([counted([TRI, BAD])], 1))

    def test_bad_unit_keeps_the_triangles_before_it(self):
        problems = []
        got = rcm.decode_clustered_mesh(mesh([counted([TRI, BAD])], 1), problems)
        self.assertEqual(len(got.triangles), 1)
        self.assertEqual(len(problems), 1)

    def test_bad_cluster_is_skipped(self):
        broken = bytearray(counted([TRI]))
        broken[12] = 7  # compression nothing reads
        problems = []
        got = rcm.decode_clustered_mesh(mesh([bytes(broken), counted([TRI])], 2), problems)
        self.assertEqual(len(got.triangles), 1)
        self.assertTrue(problems)


if __name__ == '__main__':
    unittest.main()
