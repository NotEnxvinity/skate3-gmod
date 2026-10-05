"""Builds a tiny disc image in the XDVDFS layout and reads it back."""
from pathlib import Path
import struct, tempfile, unittest

import xdvdfs


def entry(left, right, sector, size, is_dir, name):
    raw = struct.pack('<HHIIBB', left, right, sector, size, 0x10 if is_dir else 0x20, len(name)) + name.encode()
    return raw + b'\xff' * (-len(raw) % 4)


def table(entries):
    """Entries as a right-leaning tree: each links the next through `right`."""
    out, offsets = b'', []
    sizes = [len(entry(0, 0, 0, 0, False, e[0])) for e in entries]
    position = 0
    for size in sizes:
        offsets.append(position)
        position += size
    for i, (name, sector, size, is_dir) in enumerate(entries):
        right = offsets[i + 1] // 4 if i + 1 < len(entries) else 0
        out += entry(0, right, sector, size, is_dir, name)
    return out


def image(base=0):
    sectors = {}
    data = table([('data', 35, SECTOR, True), ('default.xex', 39, 4, False)])
    sectors[34] = data
    sectors[35] = table([('big', 36, SECTOR, True), ('audio', 38, 0, True)])
    sectors[36] = table([('db.big', 37, 11, False), ('fedata.big', 37, 3, False)])
    sectors[37] = b'hello skate'
    sectors[39] = b'XEX2'
    head = xdvdfs.MAGIC + struct.pack('<II', 34, len(data))
    sectors[32] = head
    raw = bytearray(base + 40 * SECTOR)
    for sector, content in sectors.items():
        raw[base + sector * SECTOR:base + sector * SECTOR + len(content)] = content
    return bytes(raw)


SECTOR = xdvdfs.SECTOR


class XdvdfsTest(unittest.TestCase):
    def check(self, base):
        with tempfile.TemporaryDirectory() as tmp:
            iso = Path(tmp) / 'skate.iso'
            iso.write_bytes(image(base))
            with xdvdfs.Image(iso) as disc:
                self.assertEqual(disc.base, base)
                paths = sorted(p for p, _, _ in disc.walk())
                self.assertEqual(paths, ['data/big/db.big', 'data/big/fedata.big', 'default.xex'])
                copied = disc.extract(Path(tmp) / 'out', lambda p: p in {'data/big/db.big', 'default.xex'}, report=lambda _: None)
            self.assertEqual(copied, 2)
            self.assertEqual((Path(tmp) / 'out/data/big/db.big').read_bytes(), b'hello skate')
            self.assertEqual((Path(tmp) / 'out/default.xex').read_bytes(), b'XEX2')

    def test_plain_image(self):
        self.check(0)

    def test_xgd3_partition(self):
        self.check(0x02080000)

    def test_rejects_other_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            junk = Path(tmp) / 'junk.iso'
            junk.write_bytes(b'\0' * 70000)
            with self.assertRaises(RuntimeError):
                xdvdfs.Image(junk)


if __name__ == '__main__':
    unittest.main()
