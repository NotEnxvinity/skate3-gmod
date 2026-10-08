"""Writes the gm_skate3_* maps: an open, sky-roofed grass field as a Source
(version 20) .bsp, written directly with no map compiler.

The maps hold nothing from the disc. Loading one tells the addon which
skatepark to build in the middle of it from the player's own converted data,
so they can ship with the addon.
"""

import argparse
import io
import math
import struct
import zipfile
from pathlib import Path

# (map name, park piece id); the piece ids are setup/park.py's MAPS.
MAPS = (
    ('gm_skate3_megapark', 'megapark_stadium'),
    ('gm_skate3_maloof', 'map_maloof'),
    ('gm_skate3_blackbox', 'map_blackbox'),
    ('gm_skate3_downtown_park', 'map_downtown_park'),
    ('gm_skate3_industrial_park', 'map_industrial_park'),
    ('gm_skate3_skate_school', 'map_skate_school'),
    ('gm_skate3_start_park', 'map_start_park'),
)

HALF = 14000  # the field runs from -HALF to HALF across
HEIGHT = 14000  # and from the ground at z = 0 up to the sky
WALL = 64  # thickness of the box's six brushes

FLOOR_MATERIAL = 'nature/grassfloor002a'
SKY_MATERIAL = 'tools/toolsskybox'
SKY_NAME = 'sky_day01_01'

# Units per lightmap luxel on the ground: the field is one face, and a
# brush face's lightmap may be at most 32 luxels across.
LUXEL = 1024
GROUND_LIGHT = (200, 200, 190)

CONTENTS_SOLID = 0x1
SURF_SKY = 0x4
SURF_NOLIGHT = 0x400
LEAF_FLAGS_SKY = 0x1

LUMP_ENTITIES, LUMP_PLANES, LUMP_TEXDATA, LUMP_VERTEXES, LUMP_VISIBILITY = 0, 1, 2, 3, 4
LUMP_NODES, LUMP_TEXINFO, LUMP_FACES, LUMP_LIGHTING = 5, 6, 7, 8
LUMP_LEAFS, LUMP_EDGES, LUMP_SURFEDGES, LUMP_MODELS = 10, 12, 13, 14
LUMP_LEAFFACES, LUMP_LEAFBRUSHES, LUMP_BRUSHES, LUMP_BRUSHSIDES = 16, 17, 18, 19
LUMP_AREAS, LUMP_ORIGINALFACES, LUMP_GAME_LUMP, LUMP_PAKFILE = 20, 27, 35, 40
LUMP_TEXDATA_STRING_DATA, LUMP_TEXDATA_STRING_TABLE = 43, 44
LUMP_LEAF_AMBIENT_INDEX, LUMP_LEAF_AMBIENT_LIGHTING = 52, 56


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


class Planes:
    """Planes in the opposite pairs the engine expects (n and n ^ 1)."""

    def __init__(self):
        self.list = []

    def add(self, normal, dist):
        for i, (n, d, _) in enumerate(self.list):
            if n == normal and d == dist:
                return i
        axis = [abs(c) for c in normal].index(1)
        self.list.append((normal, dist, axis))
        self.list.append((tuple(-c for c in normal), -dist, axis))
        return len(self.list) - 2

    def pack(self):
        return b''.join(struct.pack('<4fi', *n, d, t) for n, d, t in self.list)


def entities(park):
    ents = [
        {
            'classname': 'worldspawn',
            'skyname': SKY_NAME,
            'maxpropscreenwidth': '-1',
            'detailmaterial': 'detail/detailsprites',
            'detailvbsp': 'detail.vbsp',
            'mapversion': '1',
            'skate3_park': park,
        },
        {'classname': 'info_player_start', 'origin': '0 0 16', 'angles': '0 0 0'},
    ]
    text = ''.join('{\n' + ''.join(f'"{k}" "{v}"\n' for k, v in e.items()) + '}\n' for e in ents)
    return text.encode() + b'\0'


def build(park):
    """The whole .bsp for one park's map, as bytes."""
    planes = Planes()
    # The field's six sides, each a slab behind a plane facing into the field.
    # (inward normal, inward dist, slab mins, slab maxs, material)
    outer = HALF + WALL
    sides = [
        ((0, 0, 1), 0, (-outer, -outer, -WALL), (outer, outer, 0), FLOOR_MATERIAL),
        ((0, 0, -1), -HEIGHT, (-outer, -outer, HEIGHT), (outer, outer, HEIGHT + WALL), SKY_MATERIAL),
        ((1, 0, 0), -HALF, (-outer, -outer, -WALL), (-HALF, outer, HEIGHT + WALL), SKY_MATERIAL),
        ((-1, 0, 0), -HALF, (HALF, -outer, -WALL), (outer, outer, HEIGHT + WALL), SKY_MATERIAL),
        ((0, 1, 0), -HALF, (-outer, -outer, -WALL), (outer, -HALF, HEIGHT + WALL), SKY_MATERIAL),
        ((0, -1, 0), -HALF, (-outer, HALF, -WALL), (outer, outer, HEIGHT + WALL), SKY_MATERIAL),
    ]

    # Materials: texdata, its string table, and one texinfo per material.
    names = [FLOOR_MATERIAL, SKY_MATERIAL]
    string_data, string_table = b'', []
    for n in names:
        string_table.append(len(string_data))
        string_data += n.upper().encode() + b'\0'
    texdata = b''.join(struct.pack('<3fi4i', 0.4, 0.4, 0.3, i, 512, 512, 512, 512) for i in range(len(names)))
    # Grass tiles every 512 units; the sky has no lightmap.
    s_vec = (1.0, 0, 0, 0)
    t_vec = (0, -1.0, 0, 0)
    light_s = (1 / LUXEL, 0, 0, 0)
    light_t = (0, -1 / LUXEL, 0, 0)
    texinfo = struct.pack('<16fii', *s_vec, *t_vec, *light_s, *light_t, 0, 0)
    texinfo += struct.pack('<16fii', *s_vec, *t_vec, *light_s, *light_t, SURF_SKY | SURF_NOLIGHT, 1)

    # Brushes and their sides, each side on an outward plane.
    brushes, brushsides = b'', b''
    for _, _, lo, hi, material in sides:
        first = len(brushsides) // 8
        for axis in range(3):
            for sign, value in ((1, hi[axis]), (-1, lo[axis])):
                normal = tuple(sign if a == axis else 0 for a in range(3))
                p = planes.add(normal, sign * value)
                brushsides += struct.pack('<Hhhh', p, 1 if material == SKY_MATERIAL else 0, -1, 0)
        brushes += struct.pack('<3i', first, 6, CONTENTS_SOLID)

    # The six faces looking into the field, wound clockwise from the front
    # like the rest of Source.
    verts, edges, surfedges, faces, lighting = [], [(0, 0)], [], b'', b''
    face_planes = []
    for normal, dist, _, _, material in sides:
        p = planes.add(normal, dist)
        face_planes.append(p)
        axis = [abs(c) for c in normal].index(1)
        u, v = [a for a in range(3) if a != axis]
        corners = []
        for cu, cv in ((-1, -1), (-1, 1), (1, 1), (1, -1)):
            c = [0.0, 0.0, 0.0]
            c[axis] = dist * normal[axis]
            for a, k in ((u, cu), (v, cv)):
                c[a] = (HEIGHT if k > 0 else 0) if a == 2 else k * HALF
            corners.append(tuple(c))
        # Clockwise from the front means the corners' cross product points
        # away from the face's normal.
        if _dot(_cross(_sub(corners[1], corners[0]), _sub(corners[2], corners[0])), normal) > 0:
            corners.reverse()
        first_edge = len(surfedges)
        base = len(verts)
        verts += corners
        for i in range(4):
            edges.append((base + i, base + (i + 1) % 4))
            surfedges.append(len(edges) - 1)
        area = abs(_dot(_cross(_sub(corners[1], corners[0]), _sub(corners[2], corners[0])), normal))
        if material == FLOOR_MATERIAL:
            ss = [_dot(c, light_s[:3]) + light_s[3] for c in corners]
            ts = [_dot(c, light_t[:3]) + light_t[3] for c in corners]
            mins = (math.floor(min(ss)), math.floor(min(ts)))
            size = (math.ceil(max(ss)) - mins[0], math.ceil(max(ts)) - mins[1])
            lightofs = len(lighting)
            lighting += struct.pack('<BBBb', *GROUND_LIGHT, 0) * ((size[0] + 1) * (size[1] + 1))
            styles, tex = (0, 255, 255, 255), 0
        else:
            mins, size, lightofs, styles, tex = (0, 0), (0, 0), -1, (255, 255, 255, 255), 1
        faces += struct.pack('<HBBihhhh4Bif2i2iiHHI', p, 0, 1, first_edge, 4, tex, -1, -1,
                             *styles, lightofs, area, *mins, *size, len(faces) // 56, 0, 0, 0)

    # The tree: each node splits off one slab's solid leaf; what's in front of
    # all six is the field, leaf 1. Leaf 0 is the usual empty solid leaf.
    nodes, leafs = b'', b''
    big = 32767

    def leaf(contents, cluster, area, flags, lo, hi, firstface, numfaces, firstbrush, numbrushes):
        return struct.pack('<ihH3h3hHHHHh2x', contents, cluster, area | (flags << 9),
                           *[max(-big, min(big, int(x))) for x in lo],
                           *[max(-big, min(big, int(x))) for x in hi],
                           firstface, numfaces, firstbrush, numbrushes, -1)

    lo_all, hi_all = (-outer, -outer, -WALL), (outer, outer, HEIGHT + WALL)
    leafs += leaf(CONTENTS_SOLID, -1, 0, 0, (0, 0, 0), (0, 0, 0), 0, 0, 0, 0)
    leafs += leaf(0, 0, 1, LEAF_FLAGS_SKY, (-HALF, -HALF, 0), (HALF, HALF, HEIGHT), 0, 6, 0, 0)
    leafbrushes = b''
    for i, (_, _, lo, hi, _) in enumerate(sides):
        leafs += leaf(CONTENTS_SOLID, -1, 0, 0, lo, hi, 0, 0, i, 1)
        leafbrushes += struct.pack('<H', i)
    for i in range(6):
        front = -(1 + 1) if i == 5 else i + 1  # the field leaf, or the next node
        back = -(2 + i + 1)
        nodes += struct.pack('<3i3h3hHHhh', face_planes[i], front, back,
                             *lo_all, *hi_all, i, 1, 0, 0)
    leaffaces = struct.pack('<6H', *range(6))

    # One cluster that sees itself, and an even ambient light for models.
    visibility = struct.pack('<iii', 1, 12, 13) + b'\x01\x01'
    ambient_index = b''.join(struct.pack('<HH', 1 if i == 1 else 0, 0) for i in range(len(leafs) // 32))
    cube = [(230, 230, 220), (150, 150, 150), (190, 190, 185), (190, 190, 185), (190, 190, 185), (190, 190, 185)]
    ambient = b''.join(struct.pack('<BBBb', *c, 0) for c in cube) + bytes((128, 128, 2, 0))
    areas = struct.pack('<4i', 0, 0, 0, 0)
    models = struct.pack('<9f3i', *lo_all, *hi_all, 0, 0, 0, 0, 0, 6)
    game_lump = struct.pack('<i', 0)
    pak = io.BytesIO()
    zipfile.ZipFile(pak, 'w').close()

    lumps = {
        LUMP_ENTITIES: entities(park),
        LUMP_PLANES: planes.pack(),
        LUMP_TEXDATA: texdata,
        LUMP_VERTEXES: b''.join(struct.pack('<3f', *v) for v in verts),
        LUMP_VISIBILITY: visibility,
        LUMP_NODES: nodes,
        LUMP_TEXINFO: texinfo,
        LUMP_FACES: faces,
        LUMP_LIGHTING: lighting,
        LUMP_LEAFS: leafs,
        LUMP_EDGES: b''.join(struct.pack('<2H', *e) for e in edges),
        LUMP_SURFEDGES: b''.join(struct.pack('<i', s) for s in surfedges),
        LUMP_MODELS: models,
        LUMP_LEAFFACES: leaffaces,
        LUMP_LEAFBRUSHES: leafbrushes,
        LUMP_BRUSHES: brushes,
        LUMP_BRUSHSIDES: brushsides,
        LUMP_AREAS: areas,
        LUMP_ORIGINALFACES: faces,
        LUMP_GAME_LUMP: game_lump,
        LUMP_PAKFILE: pak.getvalue(),
        LUMP_TEXDATA_STRING_DATA: string_data,
        LUMP_TEXDATA_STRING_TABLE: b''.join(struct.pack('<i', o) for o in string_table),
        LUMP_LEAF_AMBIENT_INDEX: ambient_index,
        LUMP_LEAF_AMBIENT_LIGHTING: ambient,
    }
    header_size = 8 + 64 * 16 + 4
    body, directory = b'', []
    for i in range(64):
        data = lumps.get(i, b'')
        if data:
            body += b'\0' * (-len(body) % 4)
            directory.append((header_size + len(body), len(data)))
            body += data
        else:
            directory.append((0, 0))
    header = b'VBSP' + struct.pack('<i', 20)
    header += b''.join(struct.pack('<iiii', ofs, ln, 0, 0) for ofs, ln in directory)
    header += struct.pack('<i', 1)
    # The game lump's own directory is empty, so its offsets need no fixing.
    return header + body


def write_maps(maps_dir, report=print):
    maps_dir = Path(maps_dir)
    maps_dir.mkdir(parents=True, exist_ok=True)
    for name, park in MAPS:
        (maps_dir / f'{name}.bsp').write_bytes(build(park))
    report(f'Wrote {len(MAPS)} skatepark maps to {maps_dir}')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--out', type=Path, required=True, help='the maps folder to write into')
    write_maps(parser.parse_args().out)


if __name__ == '__main__':
    main()
