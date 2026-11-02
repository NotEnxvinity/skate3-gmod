"""Hall of Meat's real skeleton, from the player's own disc.

Skate 3 shows the skater's bones through the body in Hall of Meat. Those bones
are an ordinary model on the disc: the recipe `dem_bones_hom` in marquee.big
(Dem Bones' Hall of Meat look), 19 pieces (skull, rib cage, spine, hips, then
arms, hands, legs, feet and toes) skinned to the skater's rig, with one
texture. This reads that model with the engine's own RX2 reader and writes it
for Garry's Mod to draw under the skater's bones:

    assets/skeleton/hom.bin   the pieces, split by the bone that carries them
    assets/skeleton/hom.png   the bone texture

Nothing here is distributed: it is made on the player's machine from their
disc, like the rest of assets/.

The engine hands Lua only the rig's main bones (not fingers or the second neck
bone), so a vertex skinned to one of the others rides its nearest main
ancestor. Each triangle rides the one bone that carries most of its weight, so
a piece is a few rigid chunks, built once; it is not skinned every frame.

hom.bin, little-endian (what Garry's Mod's file:ReadFloat and friends read):
    "S3HM" u8 version, u8 group count
    per group: u8 length + bone name (the engine's, upper case),
               u8 length + body part id (cl_hall_of_meat.lua's),
               u32 vertices, u32 triangles,
               vertices x (x y z nx ny nz u v as f32), in Source units
               relative to the bone, triangles x 3 x u16 vertex numbers
"""
from pathlib import Path
import struct, sys

from syncdir import write_if_changed

FROM_DISC = {'data/content/marquee.big'}
RECIPE = 'dem_bones_hom'
MAGIC = b'S3HM'
VERSION = 1
# Skate space (metres, Y up) to Source (inches, Z up): collision.rs's from_skate.
INCH = 0.0254

# The bones skate3.GetPose returns for the body (lib.rs BODY_BONES).
BODY_BONES = frozenset("""HIPS SPINE SPINE1 SPINE2 SPINE3 NECK HEAD LEFTSHOULDER LEFTARM LEFTFOREARM
LEFTHAND RIGHTSHOULDER RIGHTARM RIGHTFOREARM RIGHTHAND LEFTUPLEG LEFTLEG LEFTFOOT LEFTTOEBASE
RIGHTUPLEG RIGHTLEG RIGHTFOOT RIGHTTOEBASE""".split())

# Which body part (the injury tracker's ids) each kind of piece belongs to,
# by the side of the bone carrying it. The disc's piece names mislead: its
# "Calf_Left" is skinned to the right leg, so the bone decides the side.
LIMB_PARTS = {
    'Bicep': ('larm', 'rarm'), 'Forearm': ('lforearm', 'rforearm'), 'Hand': ('lhand', 'rhand'),
    'Thigh': ('lfemur', 'rfemur'), 'Calf': ('lshin', 'rshin'),
    'Ankle': ('lfoot', 'rfoot'), 'Toes': ('lfoot', 'rfoot'),
}
SIMPLE_PARTS = {'Skull': 'skull', 'Neck': 'spine', 'Lower_Spine': 'spine', 'Hips': 'pelvis', 'Rib_Cage': 'ribs'}
PIECES = tuple(SIMPLE_PARTS) + tuple(f'{kind}_{side}' for kind in LIMB_PARTS for side in ('Left', 'Right'))


def main_bone(name, parents):
    """The nearest bone (the name itself, if it is one) the engine hands to Lua."""
    seen = 0
    key = name.lower()
    while key and key.upper() not in BODY_BONES and seen < 16:
        key = parents.get(key)
        seen += 1
    return key.upper() if key and key.upper() in BODY_BONES else None


def part_of(piece, bone):
    """The body part id a group of `piece` carried by `bone` counts as."""
    kind = piece.rsplit('_', 1)[0] if piece.endswith(('_Left', '_Right')) else piece
    if kind in LIMB_PARTS:
        return LIMB_PARTS[kind][0 if bone.startswith('LEFT') else 1]
    if kind == 'Rib_Cage' and bone.endswith('SHOULDER'):
        return 'lcollar' if bone.startswith('LEFT') else 'rcollar'
    return SIMPLE_PARTS[kind]


def groups_of(piece, mesh, bones, ibp, parents):
    """One piece as rigid groups: {(bone, part): (vertices, triangles)}. `mesh`
    is rx2_skeleton's decoded mesh, `bones` its bone names, `ibp` the main
    bones' inverse bind matrices (row-vector, as the file stores them)."""
    import numpy as np
    positions = np.asarray(mesh['positions'], dtype=np.float64)
    normals = np.asarray(mesh['normals'], dtype=np.float64)
    uvs = np.asarray(mesh['uvs'], dtype=np.float64)
    # Each vertex's weight on the main bones.
    carried = []
    for skin, weight in zip(mesh['skin_bones'], mesh['skin_weights']):
        sums = {}
        for b, w in zip(skin, weight):
            if w <= 0:
                continue
            main = main_bone(bones[b], parents)
            if main is not None:
                sums[main] = sums.get(main, 0.0) + float(w)
        carried.append(sums)
    indices = mesh['indices']
    groups = {}
    for t in range(0, len(indices) - 2, 3):
        corners = indices[t:t + 3]
        total = {}
        for v in corners:
            for bone, w in carried[v].items():
                total[bone] = total.get(bone, 0.0) + w
        if not total:
            continue
        bone = max(sorted(total), key=lambda b: total[b])
        matrix = ibp[bone]
        key = (bone, part_of(piece, bone))
        verts, tris, seen = groups.setdefault(key, ([], [], {}))
        tri = []
        for v in corners:
            if v not in seen:
                local = positions[v] @ matrix[:3, :3] + matrix[3, :3]
                turned = normals[v] @ matrix[:3, :3]
                length = float(np.linalg.norm(turned)) or 1.0
                turned = turned / length
                seen[v] = len(verts)
                verts.append((
                    local[0] / INCH, -local[2] / INCH, local[1] / INCH,
                    turned[0], -turned[2], turned[1],
                    float(uvs[v][0]), float(uvs[v][1]),
                ))
            tri.append(seen[v])
        tris.append(tuple(tri))
    return {key: (verts, tris) for key, (verts, tris, _) in groups.items()}


def encode(groups):
    """hom.bin's bytes from {(bone, part): (vertices, triangles)}."""
    if len(groups) > 255:
        raise ValueError('too many groups')
    out = bytearray(MAGIC + bytes([VERSION, len(groups)]))
    for (bone, part), (verts, tris) in sorted(groups.items()):
        for text in (bone, part):
            raw = text.encode('ascii')
            out += bytes([len(raw)]) + raw
        if len(verts) > 65535:
            raise ValueError(f'{bone} has too many vertices')
        out += struct.pack('<II', len(verts), len(tris))
        for v in verts:
            out += struct.pack('<8f', *v)
        for tri in tris:
            out += struct.pack('<3H', *tri)
    return bytes(out)


def decode(data):
    """What encode wrote, back as {(bone, part): (vertices, triangles)}."""
    if data[:4] != MAGIC or data[4] != VERSION:
        raise ValueError('not a hom.bin this setup wrote')
    at, groups = 6, {}
    for _ in range(data[5]):
        names = []
        for _ in range(2):
            n = data[at]
            names.append(data[at + 1:at + 1 + n].decode('ascii'))
            at += 1 + n
        nv, nt = struct.unpack_from('<II', data, at)
        at += 8
        verts = [struct.unpack_from('<8f', data, at + 32 * i) for i in range(nv)]
        at += 32 * nv
        tris = [struct.unpack_from('<3H', data, at + 6 * i) for i in range(nt)]
        at += 6 * nt
        groups[tuple(names)] = (verts, tris)
    if at != len(data):
        raise ValueError('hom.bin has trailing bytes')
    return groups


def read_model(engine, marquee, work):
    """The recipe's pieces and texture, read out of marquee.big into `work`.
    Returns (piece -> rx2 path, texture png path)."""
    import xml.etree.ElementTree as ET
    sys.path.insert(0, str(Path(engine).resolve()))
    sys.path.insert(0, str(Path(engine).resolve() / 'tools/vendor/utt'))
    from tools.owned_game.big import BigArchive
    from tools.asset_pipeline.marquee_assets import Resources
    from tools.extract_default_skater import import_rx2_parser, decode_texture
    resources = Resources(BigArchive(marquee))
    root = resources.recipe(RECIPE)
    work = Path(work)
    pieces = {}
    for component in root.findall('comp'):
        slot = component.attrib['n']
        mod = component.findall('mod')[0]
        lod = next(l for l in mod.findall('lod') if l.get('idx') == '0')
        path = work / f'{slot}.rx2'
        path.write_bytes(resources.read(f"data/content/marquee/model/{RECIPE}/{slot}/{lod.attrib['arenaid']}.rx2"))
        pieces[slot] = path
    textures = [s.attrib['id'].lower().removeprefix('0x') for m in root.findall('mat') for s in m.findall('sp')
                if s.attrib.get('chn') == 'diffuse']
    if len(textures) != 1:
        raise RuntimeError(f'the Hall of Meat skeleton should have one texture, the recipe names {len(textures)}')
    source = work / 'texture.rx2'
    source.write_bytes(resources.read(f'data/content/marquee/texture/0x{textures[0]}.rx2'))
    png = work / 'texture.png'
    decode_texture(import_rx2_parser(Path(engine).resolve() / 'tools/vendor/utt'), source, png)
    return pieces, png


def build(engine, pieces):
    """{(bone, part): (vertices, triangles)} for every piece's rx2 file."""
    sys.path.insert(0, str(Path(engine).resolve() / 'tools/vendor/skate3_anim'))
    import numpy as np
    import rx2_skeleton as RX2
    parsed = {name: RX2.parse_rx2(str(path)) for name, path in pieces.items()}
    # Every piece skins to the same rig; the main bones' binds come from wherever they appear.
    ibp = {}
    for model in parsed.values():
        for bone in model['bones']:
            key = bone['name'].upper()
            matrix = np.asarray(bone['ibp_matrix'], dtype=np.float64).reshape(4, 4)
            if key in BODY_BONES:
                if key in ibp and not np.allclose(ibp[key], matrix, atol=1e-4):
                    raise RuntimeError(f'the skeleton pieces disagree about the {key} bone')
                ibp.setdefault(key, matrix)
    parents = {}
    for model in parsed.values():
        for bone in model['bones']:
            if bone.get('parent_name'):
                parents[bone['name'].lower()] = bone['parent_name'].lower()
    groups = {}
    for slot, model in parsed.items():
        name = slot.removeprefix('Bones_')
        mesh = next((m for m in model['meshes'] if m.get('positions') and m.get('indices')), None)
        if mesh is None:
            raise RuntimeError(f'the skeleton piece {name} has no mesh')
        if name not in PIECES:
            continue
        names = [b['name'] for b in model['bones']]
        need = {main_bone(names[b], parents) for skin in mesh['skin_bones'] for b in skin}
        lacking = sorted(n for n in need if n and n not in ibp)
        if lacking:
            raise RuntimeError(f'the skeleton piece {name} needs bones the pieces never define: {", ".join(lacking)}')
        for key, (verts, tris) in groups_of(name, mesh, names, ibp, parents).items():
            # Several pieces can ride one bone (the ankle and the toes both ride the foot).
            have_verts, have_tris = groups.setdefault(key, ([], []))
            shift = len(have_verts)
            have_verts.extend(verts)
            have_tris.extend(tuple(i + shift for i in tri) for tri in tris)
    if not groups:
        raise RuntimeError('no skeleton pieces were read')
    return groups


def export(engine, game, out, report):
    """Writes assets/skeleton from the disc's marquee.big (game is the folder
    holding data/). Returns True if it did; the mod draws its X-ray without it."""
    marquee = Path(game) / 'data/content/marquee.big'
    if not marquee.is_file():
        report("This copy of the game has no marquee.big, so Hall of Meat keeps its X-ray look.")
        return False
    import tempfile
    out = Path(out)
    with tempfile.TemporaryDirectory(prefix='s3gm-hom-') as work:
        pieces, png = read_model(engine, marquee, work)
        groups = build(engine, pieces)
        write_if_changed(out / 'hom.bin', encode(groups))
        write_if_changed(out / 'hom.png', Path(png).read_bytes())
    triangles = sum(len(t) for _, t in groups.values())
    report(f"Read Hall of Meat's skeleton from the disc: {len(groups)} parts, {triangles} triangles")
    return True
