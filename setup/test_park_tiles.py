"""Cuts a synthetic skatepark into tiles and checks nothing is lost or too big."""
import random, unittest

import park_tiles


def grid_park(n, textures=2):
    """An n x n grid of quads (2 triangles each) across `textures` groups, with
    the same grid as collision; 100 inch cells."""
    groups = [{'tex': f't{k}', 'pos': [], 'uv': [], 'idx': []} for k in range(textures)]
    collision = []
    for i in range(n):
        for j in range(n):
            g = groups[(i + j) % textures]
            base = len(g['pos']) // 3
            for dx, dy in ((0, 0), (1, 0), (1, 1), (0, 1)):
                g['pos'] += [(i + dx) * 100.0, (j + dy) * 100.0, 5.0 * ((i + j) % 3)]
                g['uv'] += [dx, dy]
            g['idx'] += [base, base + 1, base + 2, base, base + 2, base + 3]
            for a, b, c in ((0, 1, 2), (0, 2, 3)):
                for corner in (a, b, c):
                    dx, dy = ((0, 0), (1, 0), (1, 1), (0, 1))[corner]
                    collision += [(i + dx) * 100.0, (j + dy) * 100.0, 5.0 * ((i + j) % 3)]
    return {'id': 'map_test', 'name': 'Test Park', 'category': 'Maps', 'groups': groups, 'collision': collision}


class TileTest(unittest.TestCase):
    def test_small_park_is_one_tile(self):
        tiles = park_tiles.tile(grid_park(4))
        self.assertEqual(len(tiles), 1)
        self.assertEqual(tiles[0]['id'], 'map_test_t0')

    def test_big_park_is_cut_and_nothing_is_lost(self):
        park = grid_park(80)  # 12,800 render and collision triangles
        tiles = park_tiles.tile(park, max_collision=2000, max_render=3000)
        self.assertGreater(len(tiles), 4)
        render = sum(len(g['idx']) // 3 for t in tiles for g in t['groups'])
        collision = sum(len(t['collision']) // 9 for t in tiles)
        self.assertEqual(render, 80 * 80 * 2)
        self.assertEqual(collision, 80 * 80 * 2)
        for t in tiles:
            self.assertLessEqual(len(t['collision']) // 9, 2000)
            self.assertLessEqual(sum(len(g['idx']) // 3 for g in t['groups']), 3000)
            for g in t['groups']:
                self.assertEqual(len(g['pos']) // 3, len(g['uv']) // 2)
                self.assertLess(max(g['idx']), len(g['pos']) // 3)

    def test_tiles_stay_in_the_parks_own_space(self):
        tiles = park_tiles.tile(grid_park(40), max_collision=500, max_render=500)
        lo = min(t['bounds'][0][0] for t in tiles)
        hi = max(t['bounds'][1][0] for t in tiles)
        self.assertEqual((lo, hi), (0.0, 4000.0))

    def test_textures_and_cutouts_follow_their_triangles(self):
        park = grid_park(10)
        park['groups'][1]['cut'] = True
        for t in park_tiles.tile(park, max_collision=60, max_render=60):
            for g in t['groups']:
                self.assertEqual(g.get('cut', False), g['tex'] == 't1')

    def test_degenerate_collision_is_dropped(self):
        flat = [0, 0, 0, 100, 0, 0, 0, 100, 0,  # fine
                0, 0, 0, 0, 0, 0, 5, 5, 5,  # a point
                0, 0, 0, 100, 0, 0, 200, 0, 0,  # a line
                0, 0, 0, 0.1, 0, 0, 0, 100, 0,  # a sliver, edge under 0.25
                0, 0, 0, 100, 0, 0, 0, 100, 0]  # the first one again
        self.assertEqual(park_tiles.clean_collision(flat), [0, 0, 0, 100, 0, 0, 0, 100, 0])

    def test_random_soup_keeps_every_usable_triangle(self):
        rng = random.Random(3)
        flat = [rng.uniform(0, 3000) for _ in range(9 * 3000)]
        park = {'id': 'm', 'name': 'M', 'category': 'Maps', 'groups': [], 'collision': flat}
        kept = len(park_tiles.clean_collision(flat)) // 9
        tiles = park_tiles.tile(park, max_collision=400, max_render=400)
        self.assertEqual(sum(len(t['collision']) // 9 for t in tiles), kept)
        self.assertTrue(all(len(t['collision']) // 9 <= 400 for t in tiles))


if __name__ == '__main__':
    unittest.main()


class GroundHeightTest(unittest.TestCase):
    def quad(self, z, size=100.0, x=0.0, up=True):
        """Two triangles of a flat square at height z, facing up or down (the
        way Skate 3's outward clockwise triangles do)."""
        a, b, c, d = (x, 0, z), (x + size, 0, z), (x + size, size, z), (x, size, z)
        tris = [(a, c, b), (a, d, c)] if up else [(a, b, c), (a, c, d)]
        return [v for t in tris for corner in t for v in corner]

    def test_ignores_a_deep_pit(self):
        flat = self.quad(0.0, 1000.0) + self.quad(-5000.0, 10.0)
        self.assertEqual(park_tiles.ground_height(flat), 0.0)

    def test_ignores_ceilings(self):
        flat = self.quad(0.0, 100.0) + self.quad(-900.0, 5000.0, up=False)
        self.assertEqual(park_tiles.ground_height(flat), 0.0)

    def test_no_floor(self):
        self.assertIsNone(park_tiles.ground_height(self.quad(0.0, up=False)))


class CleanCollisionTest(unittest.TestCase):
    A, B, C = (0, 0, 0), (10, 0, 0), (0, 10, 0)

    def flat(self, *tris):
        return [v for t in tris for corner in t for v in corner]

    def test_drops_a_repeated_triangle(self):
        t = (self.A, self.B, self.C)
        rotated = (self.B, self.C, self.A)
        self.assertEqual(len(park_tiles.clean_collision(self.flat(t, t, rotated))), 9)

    def test_keeps_the_back_of_a_two_sided_surface(self):
        front = (self.A, self.C, self.B)
        back = (self.A, self.B, self.C)
        self.assertEqual(len(park_tiles.clean_collision(self.flat(front, back))), 18)
