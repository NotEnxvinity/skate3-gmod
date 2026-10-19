"""park.write_all writes pieces, tiles and the index the Lua side reads."""
from pathlib import Path
import json, os, tempfile, unittest

import park


def grid(n, size=10.0):
    """A flat n x n quad grid as one render group plus matching collision, its
    triangles facing up the way Skate 3 winds them (clockwise from outside)."""
    pos, uv, idx, collision = [], [], [], []
    for y in range(n + 1):
        for x in range(n + 1):
            pos += [x * size, y * size, 0.0]
            uv += [x / n, y / n]
    for y in range(n):
        for x in range(n):
            a = y * (n + 1) + x
            idx += [a, a + n + 1, a + 1, a + 1, a + n + 1, a + n + 2]
    for t in range(0, len(idx), 3):
        for k in range(3):
            collision += pos[idx[t + k] * 3:idx[t + k] * 3 + 3]
    return {'tex': None, 'pos': pos, 'uv': uv, 'idx': idx}, collision


def make(pid, name, category, n):
    group, collision = grid(n)
    pts = [group['pos'][i:i + 3] for i in range(0, len(group['pos']), 3)]
    bounds = [[min(p[a] for p in pts) for a in range(3)], [max(p[a] for p in pts) for a in range(3)]]
    return {'id': pid, 'name': name, 'category': category, 'bounds': bounds,
            'groups': [group], 'collision': collision}


class WriteAllTest(unittest.TestCase):
    def test_pieces_and_tiles(self):
        with tempfile.TemporaryDirectory() as gmod:
            made = [make('aa', 'Small ramp', 'Vert', 4), make('bb', 'Big park', 'Maps', 120)]
            park.write_all(made, {}, gmod, lambda _: None)
            out = Path(gmod) / 'data/skate3/park'
            index = json.loads((out / 'index.json').read_text())
            by_id = {p['id']: p for p in index}
            self.assertEqual(index[0]['id'], 'bb', 'parks come first')
            self.assertNotIn('tiles', by_id['aa'])
            self.assertNotIn('floor', by_id['aa'])
            self.assertEqual(by_id['bb']['floor'], 0.0)
            tiles = by_id['bb']['tiles']
            self.assertGreater(len(tiles), 1)
            total = 0
            for t in tiles:
                piece = json.loads((out / f'{t}.json').read_text())
                self.assertLessEqual(len(piece['collision']) // 9, park.park_tiles.MAX_COLLISION)
                total += len(piece['collision']) // 9
            self.assertEqual(total, 120 * 120 * 2)
            self.assertTrue((out / 'aa.json').is_file())
            self.assertFalse((out / 'bb.json').exists(), 'a park is only its tiles')

    def test_rerun_leaves_unchanged_files_alone(self):
        with tempfile.TemporaryDirectory() as gmod:
            out = Path(gmod) / 'data/skate3/park'
            park.write_all([make('aa', 'Small ramp', 'Vert', 4), make('cc', 'Old ramp', 'Vert', 3)], {}, gmod, lambda _: None)
            for f in out.glob('*.json'):
                os.utime(f, (1000, 1000))
            park.write_all([make('aa', 'Small ramp', 'Vert', 4)], {}, gmod, lambda _: None)
            self.assertEqual(os.stat(out / 'aa.json').st_mtime, 1000, 'same piece, not rewritten')
            self.assertFalse((out / 'cc.json').exists(), 'a piece the disc no longer has is removed')
            self.assertFalse((out.parent / 'park.partial').exists())
            self.assertFalse((Path(gmod) / 'materials/skate3/park.partial').exists())


if __name__ == '__main__':
    unittest.main()
