"""sync_tree and write_if_changed write only what differs."""
from pathlib import Path
import os, tempfile, unittest

from syncdir import sync_tree, write_if_changed


def put(root, rel, data):
    path = Path(root) / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


class SyncTree(unittest.TestCase):
    def test_unchanged_files_are_not_touched(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp, 'src'), Path(tmp, 'dst')
            put(src, 'a.wav', b'one')
            put(src, 'sub/b.wav', b'two')
            put(dst, 'a.wav', b'one')
            put(dst, 'sub/b.wav', b'old')
            os.utime(dst / 'a.wav', (1000, 1000))
            written, kept, removed = sync_tree(src, dst)
            self.assertEqual((written, kept, removed), (1, 1, 0))
            self.assertEqual(os.stat(dst / 'a.wav').st_mtime, 1000)
            self.assertEqual((dst / 'sub/b.wav').read_bytes(), b'two')

    def test_extras_are_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp, 'src'), Path(tmp, 'dst')
            put(src, 'keep.txt', b'x')
            put(dst, 'keep.txt', b'x')
            put(dst, 'stale.txt', b'y')
            put(dst, 'old/deep/stale.txt', b'z')
            written, kept, removed = sync_tree(src, dst)
            self.assertEqual((written, kept, removed), (0, 1, 2))
            self.assertEqual(sorted(p.name for p in dst.rglob('*')), ['keep.txt'])

    def test_file_and_folder_swap_places(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp, 'src'), Path(tmp, 'dst')
            put(src, 'x/inner.txt', b'1')
            put(src, 'y', b'2')
            put(dst, 'x', b'file')
            put(dst, 'y/inner.txt', b'folder')
            sync_tree(src, dst)
            self.assertEqual((dst / 'x/inner.txt').read_bytes(), b'1')
            self.assertEqual((dst / 'y').read_bytes(), b'2')

    def test_move_renames_when_the_target_is_new(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp, 'src'), Path(tmp, 'new/dst')
            put(src, 'a.txt', b'1')
            self.assertEqual(sync_tree(src, dst, move=True), (1, 0, 0))
            self.assertFalse(src.exists())
            self.assertEqual((dst / 'a.txt').read_bytes(), b'1')

    def test_move_with_an_existing_target_leaves_the_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp, 'src'), Path(tmp, 'dst')
            put(src, 'a.txt', b'1')
            put(dst, 'a.txt', b'1')
            self.assertEqual(sync_tree(src, dst, move=True), (0, 1, 0))
            self.assertTrue(src.exists())

    def test_write_if_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, 'fonts/f.ttf')
            self.assertTrue(write_if_changed(path, b'abc'))
            os.utime(path, (1000, 1000))
            self.assertFalse(write_if_changed(path, b'abc'))
            self.assertEqual(os.stat(path).st_mtime, 1000)
            self.assertTrue(write_if_changed(path, b'abd'))
            self.assertEqual(path.read_bytes(), b'abd')


if __name__ == '__main__':
    unittest.main()
