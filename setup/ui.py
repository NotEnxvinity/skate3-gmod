"""Skate 3's on-screen look, from the player's own disc: the trick score
widget's art, the D-pad menu's panel and button icons, and the Futura bitmap
fonts the game draws its text with. The engine's own HUD extractors (the
ones its prepare_hud and extract_session_marker scripts run) decode the
disc's APT/GEO/RX2 files; this turns what they produce into PNGs Garry's Mod
can draw plus one ui.json that says where each piece sits.

Writes assets/ui/*.png and assets/ui/ui.json. Nothing here is distributed:
it is made on the player's machine from their disc, like the rest of
assets/. Everything is laid out on Skate 3's own 1280x720 canvas; the mod
scales it to the screen.
"""
from pathlib import Path
import json, sys, tempfile

# The retail button icons the menus use (all "_hud" variants, the ones the
# in-game D-pad menu draws).
BUTTONS = ('A', 'B', 'X', 'Y', 'L_Bumper', 'R_Bumper', 'L_Trigger', 'R_Trigger', 'DPad', 'DPad_Up', 'DPad_Down',
           'DPad_Left', 'DPad_Right', 'Start', 'Back', 'Stick_Left', 'Stick_Right', 'L3_Click', 'R3_Click')
# FontManager's APT names for the two atlases the HUD text uses.
FONTS = {'heavy': 'Futura Std Medium', 'shadow': 'Futura Shadow'}
# Shapes of the trickdisplay2 movie the score widget is built from.
SHAPES = ('36', '38', '40', '43', '45', '46', '47', '51', '54', '57', '61', '64', '68', '72', '81')
# Where an upscaled copy of a texture sits in the HD pack: the same names and
# folders as the exported UI textures (ui/screens/hud2/trickdisplay2/35.png).
HD_SCORE = 'ui/screens/hud2/trickdisplay2/%s.png'
HD_PANEL = 'ui/screens/hud2/hudphonelist/%s.png'
HD_BUTTON = 'ui/images/buttons/xbox360/buttons/button_%s_hud.png'
# The Futura atlases, by font key (heavy is the text colour pass, shadow the black one).
HD_LOGO = 'ui/screens/hud2/homscoring/%s.png'
HD_FONT = {'heavy': 'fonts/atlas-png/futuraheavy.png', 'shadow': 'fonts/atlas-png/futurashadow.png'}
PANEL = (91.0, 48.0)  # where the quick menu's panel sits on the canvas
# The front-end archives the extractors read (miscboot.big is names.py's too).
FROM_DISC = {'data/big/fedata.big', 'data/big/fetexture.big', 'data/big/fedynamic.big', 'data/big/miscboot.big'}


def png(raw, width, height, path):
    from PIL import Image
    if len(raw) != width * height * 4:
        raise ValueError(f'{path.name}: expected {width * height * 4} bytes, found {len(raw)}')
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.frombytes('RGBA', (width, height), raw).save(path)


def quad(vertices):
    """[[x, y, u, v] x 4], clockwise from the top left, from a rectangle's
    triangles ({position, uv} vertices). None if it isn't a rectangle."""
    unique = {}
    for v in vertices:
        unique[(round(v['position'][0], 3), round(v['position'][1], 3))] = [min(1.0, max(0.0, round(c, 4))) for c in v['uv']]
    xs = sorted({k[0] for k in unique})
    ys = sorted({k[1] for k in unique})
    if len(xs) != 2 or len(ys) != 2 or len(unique) != 4:
        return None
    return [[x, y, *unique[(x, y)]] for x, y in ((xs[0], ys[0]), (xs[1], ys[0]), (xs[1], ys[1]), (xs[0], ys[1]))]


# The Hall of Meat panel's magazine logo: the sprite of the homscoring movie that holds it.
LOGO_BUNDLE = 'data/fe/source/screens/hud2/homscoring'
LOGO_SPRITE = 20


def logo_pieces(cache):
    """The logo's pieces (a soft shadow, then the lettering in two halves) from
    the homscoring movie: [(texture dict, rectangle, number)] in draw order."""
    from vendor.skate3_ui.scene_graph import AssetCache, SceneFlattener
    flat = SceneFlattener(AssetCache(cache), lambda path, owner, character: {'frame': 0}).flatten(LOGO_BUNDLE, LOGO_SPRITE)
    pieces = []
    for prim in flat['primitives']:
        t = prim.get('texture')
        rect = quad([v for tri in prim['triangles'] for v in tri]) if t else None
        number = t['resource_name'].split('\\')[-1].split('.')[0] if t else ''
        # 1 is the panel's own backdrop (a red-tinted frosted panel), 10 the logo's shadow, 16/17 the lettering.
        if rect is not None and number in ('1', '10', '16', '17'):
            pieces.append((t, rect, number))
    return pieces


def build(scoring, marker, out, report=print, logo=None):
    """scoring: prepare_hud's output folder; marker: extract_session_marker's;
    logo: the extracted homscoring folder (optional, the Hall of Meat logo)."""
    scoring, marker, out = Path(scoring), Path(marker), Path(out)
    hud = json.loads((scoring / 'runtime/trickdisplay.json').read_text(encoding='utf-8'))
    menu = json.loads((marker / 'hud.json').read_text(encoding='utf-8'))
    ui = {'version': 1, 'canvas': [1280, 720], 'textures': {}, 'shapes': {}, 'fonts': {}, 'buttons': {}, 'panel': {}}

    def add_texture(name, raw, width, height, hd=None):
        if name not in ui['textures']:
            png(raw, width, height, out / (name + '.png'))
            ui['textures'][name] = {'w': width, 'h': height}
            if hd:
                ui['textures'][name]['hd'] = hd
        return name

    # The score widget's pieces.
    for shape in SHAPES:
        pieces = []
        for prim in hud['shapes'].get(shape, []):
            rect = quad([v for tri in prim['triangles'] for v in tri])
            if rect is None:
                continue
            t = prim['texture']
            number = t['resource_name'].split('\\')[-1].split('.')[0]
            name = add_texture('hud' + number, (scoring / t['rgba']).read_bytes(), t['width'], t['height'],
                               HD_SCORE % number)
            pieces.append({'tex': name, 'quad': rect, 'color': prim['color']})
        ui['shapes'][shape] = pieces

    # The Futura bitmap fonts (the text pass pairs a black shadow atlas with
    # the foreground one).
    for key, family in FONTS.items():
        font = hud['fonts'][family]
        definition = font['definition']
        atlas = definition['textures'][0]
        name = add_texture('font_' + key, (scoring / font['texture']).read_bytes(), atlas['width'], atlas['height'],
                           HD_FONT[key])
        glyphs = {g['glyph_index']: g for g in definition['glyphs']}
        chars = {}
        for item in definition['characters']:
            g = glyphs.get(item['glyph_index'])
            if g is None:
                continue
            a, b, c, d = g['atlas_bounds']
            chars[str(item['codepoint'])] = [round(a / atlas['width'], 6), round(b / atlas['height'], 6),
                                             round(c / atlas['width'], 6), round(d / atlas['height'], 6),
                                             g['width'], g['height'], g['x_offset'], g['y_offset'], g['x_advance']]
        ui['fonts'][key] = {'tex': name, 'ascent': definition['metrics']['Ascent'], 'chars': chars}

    # The D-pad menu's panel: three rows' worth, cut into a top, a stretchy
    # middle and a bottom, each as the mirrored halves the movie places.
    panel = {'top': [], 'mid': [], 'bottom': []}
    for mesh in menu['meshes']:
        if mesh['role'] != 'art':
            continue
        t = menu['textures'][mesh['texture']]
        # source: .../hudphonelist/0001_2.Texture.rgba, the texture's number is 2
        number = Path(t['source']).name.split('.')[0].split('_', 1)[-1]
        name = add_texture('panel%d' % mesh['texture'], (marker / t['file']).read_bytes(), t['width'], t['height'],
                           HD_PANEL % number)
        rect = quad(mesh['vertices'])
        if rect is None:
            continue
        ys = [p[1] for p in rect]
        part = 'top' if max(ys) <= 80 else 'mid' if min(ys) >= 80 and max(ys) <= 151 else 'bottom'
        panel[part].append({'tex': name, 'quad': rect})
    ui['panel'] = {'origin': list(PANEL), 'top_y': 48.0, 'mid_y': 80.0, 'bottom_y': 151.0, 'bottom_end': 183.0,
                   'opacity': menu['presentation']['panel_opacity'], **panel}

    # Button icons: the same bank the game's own menus use.
    bank = marker / 'source-cache/assets/data/fe/source/images/buttons/xbox360/buttons'
    listing = json.loads((bank / 'manifest.json').read_text(encoding='utf-8'))['textures']
    by_name = {t['name']: t for t in listing}
    for button in BUTTONS:
        item = by_name.get(f'button_{button}_hud.Texture')
        if item is None:
            continue
        ui['buttons'][button] = add_texture('btn_' + button, (bank / item['rgba_file']).read_bytes(), item['width'], item['height'],
                                          HD_BUTTON % button)

    # The Hall of Meat panel's logo, if it could be read.
    if logo is not None:
        try:
            pieces = []
            for t, rect, number in logo_pieces(logo):
                name = add_texture('hom' + number, (Path(logo) / t['rgba']).read_bytes(), t['width'], t['height'],
                                   HD_LOGO % number)
                pieces.append({'tex': name, 'quad': rect, 'shadow': number in ('1', '10')})
            if pieces:
                ui['logo'] = pieces
        except Exception as error:
            report(f'Hall of Meat logo skipped: {error}')

    (out / 'ui.json').write_text(json.dumps(ui, separators=(',', ':')), encoding='utf-8')
    report(f'Skate 3 UI art ready: {len(ui["textures"])} images, {len(ui["fonts"])} fonts')
    return ui


def export(engine, game, out, collections, report):
    """Runs the engine's HUD extractors on the disc's files and writes `out`
    (garrysmod/data/skate3/assets/ui)."""
    engine = Path(engine).resolve()
    sys.path.insert(0, str(engine / 'tools'))
    sys.path.insert(0, str(engine))
    import prepare_hud, extract_session_marker
    with tempfile.TemporaryDirectory(prefix='skate3-ui-') as tmp:
        tmp = Path(tmp)
        prepare_hud.prepare(Path(game).resolve(), tmp / 'scoring', Path(collections).resolve())
        extract_session_marker.prepare(Path(game).resolve(), tmp / 'marker')
        logo = None
        try:
            from vendor.skate3_ui.project import extract_project
            extract_project(Path(game).resolve(), tmp / 'logo', include_dynamic=True, prefixes=(LOGO_BUNDLE,), update=True)
            logo = tmp / 'logo'
        except Exception as error:
            report(f'Hall of Meat logo skipped: {error}')
        return build(tmp / 'scoring', tmp / 'marker', out, report, logo)


def install_hd(source, out, report):
    """The optional HD pack (upscaled copies of the textures above, in the
    folders HD_* name) from a folder or a zip into out (data/skate3/ui-hd).
    Only .png files under ui/ and fonts/atlas-png/ are taken. Returns how many were installed."""
    import shutil, zipfile
    source, out = Path(source), Path(out)
    count = 0
    if source.is_dir():
        files = ((p.relative_to(source).as_posix(), p) for p in source.rglob('*.png'))
        opener = lambda p: p.open('rb')
    else:
        archive = zipfile.ZipFile(source)
        files = ((n, n) for n in archive.namelist() if n.lower().endswith('.png'))
        opener = archive.open
    for name, handle in files:
        parts = [x for x in name.split('/') if x]
        # ui/... (the textures) or fonts/atlas-png/... (the Futura atlases),
        # with any wrapping Skate3-UI-HD folder dropped.
        starts = [i for i, x in enumerate(parts) if x == 'ui' or (x == 'fonts' and parts[i + 1:i + 2] == ['atlas-png'])]
        if not starts:
            continue
        rel = parts[starts[0]:]
        if '..' in rel:
            continue
        target = out.joinpath(*rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        with opener(handle) as src, open(target, 'wb') as dst:
            shutil.copyfileobj(src, dst)
        count += 1
    report(f'Installed {count} HD UI images')
    return count


def find_hd(*here):
    """An HD pack (Skate3-UI-HD, a folder or a .zip) next to the setup, one
    folder up from it, or in the player's Downloads or Desktop. None if none."""
    places = [Path(h) for h in here] + [Path(h).parent for h in here]
    places += [Path.home() / 'Downloads', Path.home() / 'Desktop']
    for place in places:
        for name in ('Skate3-UI-HD.zip', 'Skate3-UI-HD'):
            pack = place / name
            try:
                if pack.is_file() or (pack.is_dir() and ((pack / 'ui').is_dir() or (pack / 'fonts').is_dir())):
                    return pack
            except OSError:
                continue
    return None


# A PlayStation 3 copy of Skate 3 (optional) gives the PlayStation button
# pictures the game itself draws, instead of the mod's own drawn ones.
PS3_BIG = 'data/big/fedynamic.big'
PS3_BANK = 'data/fe/source/images/buttons/ps3/buttons.rps3'


def ps3_root(folder):
    """The USRDIR of a decrypted PS3 copy (a JB folder), found from the folder
    picked, its PS3_GAME/USRDIR or one folder down. None if it isn't one."""
    folder = Path(folder)
    for candidate in (folder, folder / 'USRDIR', folder / 'PS3_GAME/USRDIR'):
        if (candidate / PS3_BIG).is_file():
            return candidate
    try:
        for child in sorted(folder.iterdir()):
            if child.is_dir() and (child / 'PS3_GAME/USRDIR' / PS3_BIG).is_file():
                return child / 'PS3_GAME/USRDIR'
    except OSError:
        pass
    return None


def find_ps3(*here):
    """A PS3 copy of the game next to the setup, one folder up from it, or in
    the player's Downloads or Desktop (a folder, or a folder in one of those)."""
    places = [Path(h) for h in here] + [Path(h).parent for h in here]
    places += [Path.home() / 'Downloads', Path.home() / 'Desktop']
    for place in places:
        try:
            for folder in [place] + sorted(p for p in place.iterdir() if p.is_dir()):
                found = ps3_root(folder)
                if found is not None:
                    return found
        except OSError:
            continue
    return None


def dxt5_png(raw, width, height, path):
    """A 64x64-style DXT5 texture (the PS3 stores these as plain blocks) as a PNG."""
    import io, struct
    from PIL import Image
    header = (b'DDS ' + struct.pack('<7I', 124, 0x81007, height, width, len(raw), 0, 1) + b'\0' * 44 +
              struct.pack('<2I4s5I', 32, 4, b'DXT5', 0, 0, 0, 0, 0) + struct.pack('<5I', 0x1000, 0, 0, 0, 0))
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.open(io.BytesIO(header + raw)).convert('RGBA').save(path)


def export_ps3(engine, usrdir, out, report):
    """Reads the PS3 copy's button bank into assets/ui/ps_*.png and notes them
    in ui.json (buttons_ps), next to the Xbox ones. `out` is assets/ui."""
    engine, usrdir, out = Path(engine).resolve(), Path(usrdir), Path(out)
    sys.path.insert(0, str(engine / 'tools'))
    sys.path.insert(0, str(engine))
    from vendor.skate3_ui.big import BigArchive
    from vendor.skate3_ui import rw4
    archive = BigArchive(usrdir / PS3_BIG)
    entry = next((e for e in archive.entries if e.path == PS3_BANK), None)
    if entry is None:
        raise ValueError('this copy has no PlayStation button bank')
    manifest = out / 'ui.json'
    ui = json.loads(manifest.read_text(encoding='utf-8'))
    with tempfile.TemporaryDirectory(prefix='skate3-ps3-') as tmp:
        bank = Path(tmp) / 'buttons.rps3'
        bank.write_bytes(archive.read(entry))
        _, textures = rw4.read_textures(bank)
    by_name = {t.name: t for t in textures}
    ui['buttons_ps'] = {}
    for button in BUTTONS:
        t = by_name.get(f'button_{button}_hud.Texture')
        if t is None:
            continue
        meta = t.metadata
        # 0x88 is the PS3's DXT5; anything else isn't read.
        if meta.get('format') != 136 or meta['width'] * meta['height'] != len(t.data):
            continue
        dxt5_png(t.data, meta['width'], meta['height'], out / f'ps_{button}.png')
        ui['textures'][f'ps_{button}'] = {'w': meta['width'], 'h': meta['height']}
        ui['buttons_ps'][button] = f'ps_{button}'
    manifest.write_text(json.dumps(ui, separators=(',', ':')), encoding='utf-8')
    report(f'PlayStation button art ready: {len(ui["buttons_ps"])} buttons')
    return len(ui['buttons_ps'])


# The Futura the game's own web pages use: real TrueType files on the disc.
# Garry's Mod can draw text with them at any size (the bitmap atlases above are
# soft above 720p). They're renamed so they can't clash with a Futura the
# player has installed, and so the mod can find them by one name.
FONT_DISC = 'data/webkit/FuturaStd-Heavy.ttf'
FONT_FAMILY = 'S3GM Futura'
FONT_FILE = 's3gm_futura.ttf'


def rename_ttf(data, family):
    """A TrueType file's bytes with its name table replaced so the family is
    `family` (style Bold, as the original). Fixes the checksums."""
    import struct
    count = struct.unpack('>H', data[4:6])[0]
    tables = []
    for i in range(count):
        tag, _, offset, length = struct.unpack('>4sIII', data[12 + i * 16:28 + i * 16])
        tables.append((tag, bytearray(data[offset:offset + length])))
    names = {1: family, 2: 'Bold', 3: family + ' Bold', 4: family + ' Bold', 6: family.replace(' ', '') + '-Bold'}
    records, strings = [], b''
    # Windows (UTF-16BE) and Mac (Roman) copies of each, sorted as the format wants.
    for platform, encoding, language, codec in ((1, 0, 0, 'mac_roman'), (3, 1, 0x409, 'utf-16-be')):
        for name_id, text in sorted(names.items()):
            raw = text.encode(codec)
            records.append((platform, encoding, language, name_id, len(raw), len(strings)))
            strings += raw
    table = struct.pack('>HHH', 0, len(records), 6 + 12 * len(records))
    table += b''.join(struct.pack('>6H', *r) for r in records) + strings
    tables = [(t, bytearray(table) if t == b'name' else b) for t, b in tables]
    if not any(t == b'name' for t, _ in tables):
        raise ValueError('not a font with a name table')
    # One ascent and descent everywhere (they add up to the em), so a font of
    # size N is N pixels tall with its baseline at 0.825 N on every platform,
    # whichever of the font's three metric sets the system reads.
    for t, b in tables:
        if t == b'head':
            b[8:12] = b'\0\0\0\0'  # checkSumAdjustment, set below
        elif t == b'hhea':
            b[4:10] = struct.pack('>hhh', 825, -175, 0)
        elif t == b'OS/2' and len(b) >= 78:
            b[68:74] = struct.pack('>hhh', 825, -175, 0)
            b[74:78] = struct.pack('>HH', 825, 175)
            b[62:64] = struct.pack('>H', struct.unpack('>H', b[62:64])[0] | 0x80)  # use the typo metrics
    def checksum(blob):
        blob = bytes(blob) + b'\0' * (-len(blob) % 4)
        return sum(struct.unpack('>%dI' % (len(blob) // 4), blob)) & 0xFFFFFFFF
    # Device metrics tables that would override the metrics above at some sizes.
    tables = [(t, b) for t, b in tables if t not in (b'VDMX', b'hdmx', b'LTSH')]
    n = len(tables)
    power = 1 << (n.bit_length() - 1)
    header = data[:4] + struct.pack('>HHHH', n, power * 16, power.bit_length() - 1, n * 16 - power * 16)
    directory_size = 12 + 16 * len(tables)
    out, entries, offset = bytearray(), [], directory_size
    for tag, blob in sorted(tables, key=lambda x: x[0]):
        entries.append(struct.pack('>4sIII', tag, checksum(blob), offset, len(blob)))
        padded = bytes(blob) + b'\0' * (-len(blob) % 4)
        out += padded
        offset += len(padded)
    font = bytearray(header + b''.join(entries) + out)
    adjust = (0xB1B0AFBA - checksum(font)) & 0xFFFFFFFF
    for i in range(len(tables)):
        tag, _, off, _ = struct.unpack('>4sIII', font[12 + i * 16:28 + i * 16])
        if tag == b'head':
            font[off + 8:off + 12] = struct.pack('>I', adjust)
    return bytes(font)


def export_fonts(game, folder, report):
    """The disc's Futura as TrueType into folder (garrysmod/resource/fonts)."""
    from vendor.skate3_ui.big import BigArchive
    archive = BigArchive(Path(game) / 'data/big/miscboot.big')
    entry = next((e for e in archive.entries if e.path == FONT_DISC), None)
    if entry is None:
        raise ValueError('the disc has no Futura TrueType file')
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / FONT_FILE).write_bytes(rename_ttf(archive.read(entry), FONT_FAMILY))
    report(f'Futura for the Skate 3 look installed in {folder / FONT_FILE}')
