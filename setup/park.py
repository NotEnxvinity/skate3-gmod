"""Turns Skate 3's create-a-park pieces and the Mega Park stadium on the
player's own disc into files Garry's Mod can spawn: one JSON per piece in
garrysmod/data/skate3/park and its textures as PNGs in
garrysmod/materials/skate3/park.

The pieces live in data/content/parkassets.big, named and grouped by the
park editor's recipe XML; the stadium is the world stream in
data/content/worldDIST_MegaPark.big. Each piece keeps its render mesh and
its own Skate 3 collision mesh. Everything is converted to Source units
(inches, Z up); Skate 3 is metres, Y up, with the other handedness.

    python park.py --game <extracted game folder> --gmod <garrysmod folder>
"""
from pathlib import Path
import argparse, json, re, shutil, struct, sys, tempfile, traceback, zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))

import park_tiles  # noqa: E402
from skate3_formats.archive import BigArchive  # noqa: E402
from skate3_formats.geometry import decode as decode_model  # noqa: E402
from skate3_formats.world_materials import enrich  # noqa: E402
from skate3_formats.world_textures import decode as decode_texture  # noqa: E402
from skate3_formats.retail_collision_mesh import decode_rx2_clustered_meshes  # noqa: E402
from skate3_formats.skate3_streams import read_atoc, read_sfil  # noqa: E402

PIECES = 'data/content/parkassets.big'
# The skateparks the game keeps as small self-contained worlds, each turned
# into one big piece: (file, piece id, name).
MAPS = (
    ('worldDIST_MegaPark.big', 'megapark_stadium', 'Mega Park Stadium'),
    ('worldDIST_MaloofMoneyCup.big', 'map_maloof', 'Maloof Money Cup'),
    ('worldDIST_BlackBoxPark.big', 'map_blackbox', 'Black Box Park'),
    ('worldDIST_DownTownSkatePark.big', 'map_downtown_park', 'Downtown Skate Park'),
    ('worldDIST_IndustrialSkatePark.big', 'map_industrial_park', 'Industrial Skate Park'),
    ('worldDIST_SkateSchool.big', 'map_skate_school', 'Skate School'),
    ('worldDIST_StartPark.big', 'map_start_park', 'Start Park'),
)
# Lowercased, as setup matches paths on a disc image.
FROM_DISC = {PIECES.lower()} | {('data/content/' + m[0]).lower() for m in MAPS}
INCHES = 39.3701
# The park editor's groups, in the order the spawn menu lists them.
CATEGORIES = ('Mega', 'Vert', 'Street', 'Rails', 'Hubbas', 'Plaza', 'PreMade', 'OTS',
              'Misc', 'DownTown', 'Branded', 'Foliage', 'DMO_Ramps', 'DMO_Rails',
              'DMO_Boxes', 'DMO_Barriers', 'DMO_Tables', 'DMO_Bins', 'DMO_Misc')
SKIP = {'Spawner', 'Teleports'}


def source(x, y, z):
    """Skate 3 metres, Y up, to Source inches, Z up. Swapping two axes also
    flips the handedness, which Skate 3's data needs."""
    return (x * INCHES, z * INCHES, y * INCHES)


# Typos in Skate 3's own piece names.
TYPOS = {'quater': 'quarter', 'legdes': 'ledges', 'lampost': 'lamppost', 'stantion': 'stanchion'}


def label(name):
    """'ab_MegaParkRollIn' -> 'Mega Park Roll In'."""
    name = re.sub(r'^[a-z]{1,3}_', '', name).replace('_', ' ')
    name = re.sub(r'(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ', name)
    for typo, fixed in TYPOS.items():
        name = re.sub(typo, lambda m: fixed.capitalize() if m[0][0].isupper() else fixed, name, flags=re.I)
    return re.sub(r'\s+', ' ', name).strip()


def recipes(archive):
    """Every piece the park editor offers: (model id, name, category)."""
    for path in archive.entries:
        if not path.startswith('data/content/recipe/') or not path.endswith('.xml'):
            continue
        category = None
        for line in archive.read(path).decode('latin1').splitlines():
            comp = re.search(r'<comp n="([^"]+)"', line)
            if comp:
                category = comp[1]
            mod = re.search(r'<mod id="0x([0-9a-f]{16})" n="([^"]+)"', line)
            if mod and category not in SKIP:
                # The recipe id's type byte is 03; its model's is 07.
                yield mod[1][:6] + '07' + mod[1][8:], mod[2], category


def mesh(data, offset=(0, 0, 0)):
    """The render groups of one RX2 model, in Source units, moved by
    `offset` (metres, Skate 3 axes)."""
    model = enrich(data, decode_model(data))
    groups = []
    for group in model['groups']:
        p = group['positions']
        diffuse = next((c['guid'] for c in group['material']['channels'] if c['role'] == 'diffuse'), None)
        groups.append({
            'tex': diffuse,
            'pos': [round(v, 2) for i in range(0, len(p), 3)
                    for v in source(p[i] - offset[0], p[i + 1] - offset[1], p[i + 2] - offset[2])],
            'uv': [round(v, 5) for v in group.get('uv') or []],
            'idx': group['indices'],
        })
    return groups


def collision(data, offset=(0, 0, 0)):
    """The piece's own Skate 3 collision as a flat list of triangle corners
    (Source units), plus each triangle's surface id."""
    tris, surfaces = [], []
    for part in decode_rx2_clustered_meshes(data):
        for t in part.triangles:
            for corner in (t.a, t.b, t.c):
                tris.extend(round(v, 2) for v in source(corner[0] - offset[0], corner[1] - offset[1], corner[2] - offset[2]))
            surfaces.append(t.surface)
    return tris, surfaces


def bounds(groups):
    p = [g['pos'][i:i + 3] for g in groups for i in range(0, len(g['pos']), 3)]
    return [[min(v[a] for v in p) for a in range(3)], [max(v[a] for v in p) for a in range(3)]]


def textures_of(archive, report):
    found = {}
    for path in archive.entries:
        if '/texture/' in path and path.endswith('.rx2'):
            try:
                meta, png = decode_texture(archive.read(path))
                found[meta['id']] = png
            except ValueError:
                pass
    return found


def cutout(png):
    """Whether a texture is a cutout (leaves, fences, grates): some of it is
    see-through. Textures whose alpha is only a soft mask for something else
    have no clear pixels and stay solid. Reads the plain RGBA PNGs
    world_textures writes."""
    width, height = struct.unpack_from('>2I', png, 16)
    at, data = 8, b''
    while at < len(png):
        size, kind = struct.unpack_from('>I4s', png, at)
        if kind == b'IDAT':
            data += png[at + 8:at + 8 + size]
        at += size + 12
    rows = zlib.decompress(data)
    stride = width * 4 + 1
    clear = sum(1 for y in range(height) for a in rows[y * stride + 4:(y + 1) * stride:4] if a < 16)
    return clear >= 0.01 * width * height


def piece(pid, name, category, groups, tris, surfaces):
    return {'id': pid, 'name': label(name), 'category': category, 'bounds': bounds(groups),
            'groups': groups, 'collision': tris}


def pieces(game, report):
    """Yields every park piece, then the stadium, and the textures they use."""
    archive = BigArchive(Path(game) / PIECES)
    report('Reading the park pieces off your disc')
    textures = textures_of(archive, report)
    models = {p.rsplit('/', 1)[-1][:-4].removeprefix('0x'): p for p in archive.entries if '/model/' in p}
    made, failed = [], 0
    for pid, name, category in recipes(archive):
        path = models.get(pid)
        if path is None:
            continue
        try:
            data = archive.read(path)
            groups = mesh(data)
            tris, surfaces = collision(data)
            made.append(piece(pid, name, category, groups, tris, surfaces))
        except (ValueError, KeyError, IndexError) as error:
            failed += 1
            print(f'park piece {name}: {error}', file=sys.stderr)
    report(f'Converted {len(made)} park pieces' + (f' ({failed} not supported yet)' if failed else ''))
    for file, pid, name in MAPS:
        path = Path(game) / 'data/content' / file
        if not path.is_file():
            continue
        try:
            made.append(world(path, pid, name, textures))
            report(f'Converted {name}')
        except Exception as error:
            traceback.print_exc()
            report(f'Couldn\'t convert {name} ({error}); the rest still works.')
    return made, textures


def world(path, pid, name, textures):
    """A whole skatepark world (the Mega Park stadium, Maloof, ...): its
    stream's render models and collision as one piece, with its origin in
    the middle of the floor."""
    archive = BigArchive(path)
    with tempfile.TemporaryDirectory(prefix='skate3-stadium-') as work:
        work = Path(work)
        for member in archive.entries:
            (work / member.rsplit('/', 1)[-1]).write_bytes(archive.read(member))
        assets = {}
        for table in work.glob('*.xst'):
            stream = table.stem.rsplit('_', 1)[1]
            records = read_atoc(table)
            for sfil in work.glob(f'c{stream}_*.xsf'):
                for asset in read_sfil(sfil, records, require_all_records=False):
                    assets[asset.record.asset_id] = (asset.record.asset_type, asset.data)
    renders, sims = [], []
    for kind, data in assets.values():
        if kind == 0x1000:
            try:
                meta, png = decode_texture(data)
                textures.setdefault(meta['id'], png)
            except ValueError:
                pass
        elif kind == 0x4:
            renders.append(data)
        elif kind == 0x1:
            sims.append(data)
    whole = [decode_model(d)['bounds'] for d in renders]
    low = [min(b[0][a] for b in whole) for a in range(3)]
    high = [max(b[1][a] for b in whole) for a in range(3)]
    offset = ((low[0] + high[0]) / 2, 0, (low[2] + high[2]) / 2)
    groups, tris, surfaces = [], [], []
    for data in renders:
        groups += mesh(data, offset)
    for data in sims:
        try:
            t, s = collision(data, offset)
            tris += t
            surfaces += s
        except ValueError:
            pass
    if not groups:
        raise ValueError('no render models in its stream')
    return piece(pid, name, 'Maps', groups, tris, surfaces)


def write_piece(folder, piece):
    # Gmod's file.Read only reaches data/ files with whitelisted
    # extensions; .json is one.
    (folder / f'{piece["id"]}.json').write_text(json.dumps(piece, separators=(',', ':')))


def install(game, gmod, report=print):
    """Writes the pieces into garrysmod/data/skate3/park and their textures
    into garrysmod/materials/skate3/park, replacing an earlier setup's."""
    made, textures = pieces(game, report)
    if not made:
        raise RuntimeError('no park pieces were found on the disc')
    return write_all(made, textures, gmod, report)


def write_all(made, textures, gmod, report=print):
    """Writes converted pieces (and the textures by guid) for the mod."""
    gmod = Path(gmod)
    used = {g['tex'] for p in made for g in p['groups'] if g['tex']}
    data_out, tex_out = gmod / 'data/skate3/park', gmod / 'materials/skate3/park'
    for out in (data_out, tex_out):
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir(parents=True)
    for guid in sorted(used & set(textures)):
        (tex_out / f'{guid}.png').write_bytes(textures[guid])
    index = []
    cut = {guid for guid in used & set(textures) if cutout(textures[guid])}
    for p in made:
        for g in p['groups']:
            if g['tex'] not in textures:
                g['tex'] = None
            if g['tex'] in cut:
                g['cut'] = True
        entry = {k: p[k] for k in ('id', 'name', 'category', 'bounds')}
        if p['category'] == 'Maps':
            # A whole park is cut into tiles that share its origin: Garry's
            # Mod can't build one physics mesh for a park, and a tile is only
            # loaded and drawn where it matters.
            tiles = park_tiles.tile(p)
            for t in tiles:
                write_piece(data_out, t)
            entry['tiles'] = [t['id'] for t in tiles]
            report(f'{p["name"]}: {len(tiles)} tiles')
        else:
            p['collision'] = park_tiles.clean_collision(p['collision'])
            write_piece(data_out, p)
        index.append(entry)
    order = {c: i for i, c in enumerate(('Maps',) + CATEGORIES)}
    index.sort(key=lambda p: (order.get(p['category'], len(order)), p['name']))
    (data_out / 'index.json').write_text(json.dumps(index, separators=(',', ':')))
    report(f'Installed {len(made)} park pieces and {len(used & set(textures))} textures in {data_out.parent}')
    return len(made)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--game', type=Path, required=True, help='extracted Skate 3 folder (holding default.xex and data/)')
    parser.add_argument('--gmod', type=Path, required=True, help='the garrysmod folder')
    args = parser.parse_args()
    install(args.game, args.gmod)


if __name__ == '__main__':
    main()
