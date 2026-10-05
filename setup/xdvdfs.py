"""Reads files straight out of an Xbox 360 disc image (XDVDFS), so setup can
take a Skate 3 ISO without unpacking all of it first. Only the files the
converters need are copied out.

The layout follows extract-xiso (XboxDev): 2048-byte sectors, a volume
descriptor in sector 32 of the game partition, and directories stored as
binary trees of entries.
"""
from pathlib import Path
import struct

SECTOR = 2048
MAGIC = b'MICROSOFT*XBOX*MEDIA'
# Where the game partition starts on the different disc formats: plain XDVDFS
# images, XGD2 (most Xbox 360 games, Skate 3 included), XGD3 and XGD1.
PARTITIONS = (0, 0x0FD90000, 0x02080000, 0x18300000)
DIRECTORY = 0x10


class Image:
    def __init__(self, path):
        self.file = open(path, 'rb')
        for base in PARTITIONS:
            self.file.seek(base + 32 * SECTOR)
            head = self.file.read(28)
            if head[:20] == MAGIC:
                self.base = base
                self.root = struct.unpack('<II', head[20:28])
                return
        self.file.close()
        raise RuntimeError(f'{Path(path).name} is not an Xbox 360 disc image')

    def close(self):
        self.file.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _read(self, sector, size):
        self.file.seek(self.base + sector * SECTOR)
        return self.file.read(size)

    def _entries(self, sector, size):
        """Every entry of one directory table: (name, sector, size, is_dir)."""
        if size == 0:
            return []
        table = self._read(sector, size)
        found, pending, seen = [], [0], set()
        while pending:
            offset = pending.pop()
            if offset in seen or offset + 14 > len(table):
                continue
            seen.add(offset)
            left, right = struct.unpack_from('<HH', table, offset)
            if left == 0xFFFF:
                continue
            start, length, attributes, name_length = struct.unpack_from('<IIBB', table, offset + 4)
            name = table[offset + 14:offset + 14 + name_length].decode('latin-1')
            found.append((name, start, length, bool(attributes & DIRECTORY)))
            for child in (left, right):
                if child:
                    pending.append(child * 4)
        return found

    def walk(self, sector=None, size=None, prefix=''):
        """Yields (path, sector, size) for every file, paths with '/'."""
        if sector is None:
            sector, size = self.root
        for name, start, length, is_dir in self._entries(sector, size):
            path = prefix + name
            if is_dir:
                yield from self.walk(start, length, path + '/')
            else:
                yield path, start, length

    def extract(self, destination, wanted, report=print):
        """Copies the files `wanted(path)` accepts (paths lowercased) into
        `destination`, keeping their folders. Returns how many were copied."""
        destination = Path(destination)
        copied = 0
        for path, start, length in self.walk():
            if not wanted(path.lower()):
                continue
            out = destination / path
            out.parent.mkdir(parents=True, exist_ok=True)
            report(f'Copying {path} ({length // (1024 * 1024)} MB)')
            self.file.seek(self.base + start * SECTOR)
            with open(out, 'wb') as f:
                left = length
                while left:
                    chunk = self.file.read(min(left, 8 * 1024 * 1024))
                    if not chunk:
                        raise RuntimeError(f'The disc image ends inside {path}; is it complete?')
                    f.write(chunk)
                    left -= len(chunk)
            copied += 1
        return copied
