"""Skate 3's own sound tuning, read from the disc's attribute vault (the
skater-collections.json the conversion writes): which collision sound each
pair of materials plays, how loud, and the material of each kind of ground.

The mod plays bails with it: a body part hitting the ground is a collision
between that part's material (head 97, torso 98, legs 99, arms 100) and the
ground's, the way retail's collision manager picks it.

The vault keys and record layouts are retail's, as recovered by SK8-ENGINE
(skate-3-rust-engine, tools/asset_pipeline/audio_export.py and
crates/skate-audio/src/player/collision.rs, GPL-3.0); this is a port of the
part of `collision_tuning` and `player_tuning` the mod needs."""
import json, struct
from pathlib import Path

MASK = (1 << 64) - 1


def _mix(a, b, c):
    for who, shift in [(0, 43), (1, -9), (2, 8), (0, 38), (1, -23), (2, 5),
                       (0, 35), (1, -49), (2, 11), (0, 12), (1, -18), (2, 22)]:
        if who == 0:
            a = ((a - b - c) ^ (c >> shift)) & MASK
        elif who == 1:
            b = ((b - c - a) ^ (a << -shift)) & MASK
        else:
            c = ((c - a - b) ^ (b >> shift)) & MASK
    return a, b, c


def hash64(text):
    """The vault's name hash."""
    if not text:
        return 0
    data = text.encode('ascii')
    a = b = 0xABCDEF0011223344
    c = 0x9E3779B97F4A7C13
    pos = 0
    while len(data) - pos >= 24:
        x, y, z = struct.unpack_from('<QQQ', data, pos)
        a, b, c = _mix((a + x) & MASK, (b + y) & MASK, (c + z) & MASK)
        pos += 24
    tail = data[pos:]
    a = (a + int.from_bytes(tail[:8], 'little')) & MASK
    b = (b + int.from_bytes(tail[8:16], 'little')) & MASK
    c = (c + len(data) + (int.from_bytes(tail[16:], 'little') << 8)) & MASK
    return _mix(a, b, c)[2]


# Sk8::AudioSurfaceMap: 95 entries of 18 words, by material (>= 94: entry 94).
# Word 1 the rolling surface, 6 the footstep surface, 7 the collision class.
SURFACE_MAP = ('Hash_C1831BDB6CB1B1EA', 'Hash_C489459A0C07D154', 'Hash_4CA607558B1CF440')
# Retail's material table: the Splice bank family of each of the 143
# materials (0 Skate_Collisions, 1 Skate_Metal, 2 HOM_Set_1, -1 none) and the
# key of its AudioSurface record.
MATERIAL_KINDS = (0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                  1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                  1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, -1, 0, 0, 0,
                  0, 0, 0, 0, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
MATERIAL_KEYS = (
    0x84EF7A70636ED529, 0x9182CCAD63479434, 0x49A5B1F124E53FDE, 0x49F167E3FC3A008B, 0xD7EFFA5849BB7B15,
    0x72B4ECCDC6CEE6E8, 0xAF8EAB3B0227FD48, 0x54D22F1336F8B796, 0x42CD19124AE613EB, 0x0613243A490D11EA,
    0xA4B6334D87D72CC7, 0x3738E9708EB6C776, 0x1BFF6E5CA982683A, 0x5BBDF4492AC7FB47, 0x22132549704E8733,
    0x1F2ACA29DEBE0729, 0x500227DC11D198AC, 0xB7DBFE813D021524, 0x6EAACF19DDD07B5A, 0x60EC16F48C0BE620,
    0x791C508A6E1205EA, 0x42337BA2D862B622, 0x10ED41289D47F052, 0xBD556D5B135BBF8E, 0xB74F55A0A96516A0,
    0x3B214D295DB514F7, 0xA7AB65A3C044B3DA, 0xE96D23CB66372699, 0xB062804C25EDD8A7, 0xA8EF0E67A39D62D9,
    0xF7141297FEB29B5D, 0x0DEB3D61CAED9567, 0x7AC77169773C0CE4, 0x0193A08E3EDA269B, 0xDBF3EC4C65A69F5D,
    0x3A43FEE3639BA301, 0x309033B5E5872675, 0xEF0C2293B7888864, 0xD807FA29ADE65957, 0x10017676688AA504,
    0xD8F132C02494531F, 0x5D4D49C598C7C2E3, 0xD3184F6BD8E629CC, 0xA227D8D1EB22C467, 0x7D5F7C90590CD76C,
    0xE351230372B8AA43, 0xC65BAF14769DFCEB, 0x13D19F33ABDEFDA4, 0x6B170B796C325537, 0x8640A18245382F66,
    0xC53FA0D15249C949, 0x9988214E2D3F25C2, 0x6A0D63DA93EF3459, 0x99433514E821A363, 0xF002CCA1F7FD6978,
    0x947A2EEC879CF0C4, 0xC5C3FCD994414A11, 0x45EF058BC984C7E8, 0x03745EEB6C08A0B7, 0xF3D78078D942C1F5,
    0x3E93846A0C0904EF, 0x71D3FF58545A7240, 0x36F1FB399593A42E, 0xCA39C5BF26B5A8CE, 0x98CD99EC1E257D5A,
    0x94BFC99C9D77FBE9, 0x3F4E33C9A0B9B05E, 0xDC7B09876FB19FFF, 0x8BD87DE72E1A3157, 0x0613243A490D11EA,
    0x0613243A490D11EA, 0x0613243A490D11EA, 0xBFBDAC657253E431, 0x73235D7F8A764EA3, 0x070B3A354E4B91E8,
    0x6C322F848110963C, 0x07FB54E5A776E0DD, 0x4EE7754C40081FFB, 0x59BA34C2182DFAED, 0x761C67A1D52C27D8,
    0x5AAA7F375D3FAFD7, 0x7CAF97EA114D54A9, 0xA029E9DED863C78E, 0xB13FD71EA972B2E7, 0x061A5C9D1EB44C60,
    0x0526D0B41AA7E7F3, 0xD7A4B6C19268884E, 0x0023C43AFE5425C2, 0x0B56CDEC643B3C5C, 0xA5C4BE35A6484D2A,
    0x44C45991DF83F528, 0x954AB2622DDDCDAE, 0xB2BD1F28DDE601B0, 0x09A0A000A6C314BE, 0x0000000000000000,
    0xF512E3A5DFD6C51C, 0x27CDE290C32867A9, 0x379CADECE541E342, 0xFC139EC967F75F74, 0xAB73644DAB95C51A,
    0x65AF5100E77A2982, 0x0DB9BC878EC6B280, 0xFB0158EFB8889A2A, 0x87684DAC4583AED5, 0xDC73596A59C3A8B9,
    0xF16BBF49DDEA88A9, 0xC83E4BE38A953FAA, 0xD2E3F99A952DC96B, 0x66153E29A9E4F5F0, 0xB025A0D5D09BAD53,
    0xC54DB3B091215CA0, 0xF2E9CB8F28FAED2D, 0x7410CAC4852F5168, 0x76535DC1C13DC342, 0x56AE4185FFB27F3B,
    0xBC46374D5FE945CC, 0x4E3F3F3D686C1376, 0xFD06F928C97B0C13, 0x272430E460312991, 0x8CDC59AF8D2FE8C0,
    0x3C39F714BDF14002, 0x582E3694A7D7A81C, 0xDAB71EE7131FB16F, 0x5C7F8A8CD61ADC6A, 0xD715DAADCCFE3707,
    0xD1104F0408894184, 0x0180D422774A2E76, 0x7EE4E115095A35FE, 0xE6ACC17E8C6E545D, 0x897D82A74C3DD55F,
    0x9322B76721A7E961, 0x88E70FFEEB920FAC, 0xE5E4636B15D921E1, 0xB2B199D7B0CC6E56, 0x361AF94AF4738607,
    0xBC8EB5FAC4FBFCAA, 0xDE485796A9BF0518, 0x4E988E099EB988FA, 0xBFA1E3CB2AC6A29F, 0xBA3A875662F7B1A3,
    0x90C5D36FD10D6A3C, 0x93046C79A53E24D9, 0x93610C96EB08CDAD,
)
MATERIAL_CLASS = 'Hash_D40CB4C0FFE45676'
# The sample ids per kind: [tier 2, tier 0 x class 0/1/2, tier 1 x class 0/1/2].
MATERIAL_IDS = (
    ('Hash_9203DF6FD029B377', 'Hash_BFABF634D2B1E45A', 'Hash_9ABFC64574AB2F9F', 'Hash_BCD5E888294F7B15',
     'Hash_EF9BD81F9CFF725F', 'Hash_A3ADCA7B19287B5D', 'Hash_C676C87F862C0490'),
    ('Hash_F54277A83E0170FD', 'Hash_66A95889604DED36', 'Hash_595537EBA0196BE7', 'Hash_79DD0E6659793D0E',
     'Hash_B722B88FE44B046E', 'Hash_1411108A7E9CC74A', 'Hash_50796F92F3DE449B'),
    ('Hash_3EA2579C2F3BB23B', 'Hash_137C683BFB506ECA', 'Hash_2A2830137430BB02', 'Hash_79BDE00B04DF51B9',
     'Hash_5432B35224E4B1C1', 'Hash_3FCBE0407F833721', 'Hash_53311C6761F135A1'),
)
MATERIAL_GAIN, MATERIAL_PITCH = 'Hash_875BA75341DC8391', 'Hash_C090F2C1F048F17B'
MATERIAL_WINDOWS, MATERIAL_BANDS = 'Hash_82B1451A90152514', 'Hash_E228508FE0F53970'
WINDOW_CLASS = 'Hash_13E20D398E385A56'
WINDOW_FIELDS = ('Hash_036F313CEBC664FD', 'Hash_8001982DA2E91D6A', 'Hash_E24D9CB4000A53AC', 'Hash_1A83AD0330976744',
                 'Hash_24B725E05CEB027E', 'Hash_CBBB19E302CE1A17', 'Hash_75DC915E876A9DC9', 'Hash_711F1F54903E76C9',
                 'Hash_C8DED1BC20B9D6A5', 'Hash_B8870D2001033E0F', 'Hash_41F2E2456A97752A', 'Hash_2638FF12C8FBBCCB',
                 'Hash_166BAB2FD5B60560', 'Hash_0D6EF57A39AF0C93')
WINDOW_SCALE = 'Hash_1A5F7E8CCABBB0A2'
BAND_CLASS = 'Hash_7DAFF70B3A91CD5D'
BAND_FIELDS = ('Hash_C8DED1BC20B9D6A5', 'Hash_B8870D2001033E0F', 'Hash_7D8DEDD338D45482', 'Hash_D660AC459139BDF4')
# The body poster (class 6EBA5BCD3E38A98A `default`): the per-region cooldown
# (frames) and the speed graph its impacts are scaled by.
BODY = 'Hash_6EBA5BCD3E38A98A'
BODY_COOLDOWN = 'Hash_6DD85F43C1B6E6AA'
BODY_SPEED_GRAPH = 'Hash_8B164823E008749C'
# Rolling surface (AudioSurfaceMap word 1) -> the mod's name for that ground.
ROLLING = {1: 'asphalt_rough', 2: 'concrete_rough', 3: 'asphalt_smooth', 4: 'concrete_smooth', 5: 'wood', 6: 'concrete_aggregate', 9: 'metal'}


def _words(field):
    """Signed 32-bit words of a field (arrays: one per item, first word)."""
    items = field['array']['items'] if 'array' in field else [field.get('data', '')]
    out = []
    for item in items:
        data = ''.join(item.split())
        if len(data) >= 8:
            out.append(struct.unpack('>i', bytes.fromhex(data[:8]))[0])
        elif data:
            out.append(int(data[:2], 16))
    return out


def _number(field):
    """A scalar field: float for Float types, else a signed word."""
    if field.get('type', '').endswith('Float'):
        data = ''.join(field.get('data', '').split())
        return struct.unpack('>f', bytes.fromhex(data[:8]))[0] if len(data) >= 8 else 0.0
    words = _words(field)
    return words[0] if words else 0


# The front-end ("fe") records: the interface sounds, each naming a sound in
# the sk8_menu bank (audio_export.frontend_sounds upstream).
FE_CLASSES = ('Hash_5831CB95F3E90598', 'fe')
FE_ID, FE_LEVEL = 'Hash_8FCC7EF9B9208858', 'Hash_875BA75341DC8391'
FE_NAMES = ('Hash_942AB8AEE4B414ED', 'Name')


def _text(field):
    data = field.get('data', '') if field else ''
    return data if isinstance(data, str) else ''


def frontend(by_class):
    """{record name: [sk8_menu sound id, level]} for every front-end record
    that plays something. Records without a name keep their key."""
    out = {}
    for cls in FE_CLASSES:
        records = by_class.get(cls, {})

        def resolve(key, field):
            seen = 0
            while key in records and seen < 32:
                if field in records[key]['fields']:
                    return records[key]['fields'][field]
                key, seen = records[key].get('parent', ''), seen + 1
            return None

        for key in records:
            sound, level = resolve(key, FE_ID), resolve(key, FE_LEVEL)
            sound = _words(sound)[0] if sound is not None and _words(sound) else 0
            level = _number(level) if level is not None else 1.0
            if sound < 1 or level <= 0:
                continue
            name = key if not key.startswith('Hash_') else next(
                (_text(f) for n in FE_NAMES if (f := resolve(key, n)) and _text(f)), key)
            out[name] = [sound, round(level, 4)]
    return out


def _floats(field):
    data = ''.join(field.get('data', '').split())
    return [struct.unpack('>f', bytes.fromhex(data[i:i + 8]))[0] for i in range(0, len(data) - 7, 8)]


def export(collections):
    """The table the mod's bail sounds read, or None when the vault doesn't
    hold the collision records."""
    if isinstance(collections, dict):
        collections = collections.get('collections', [])
    by_class = {}
    for c in collections:
        by_class.setdefault(c['class'], {})[c['key']] = c
    if MATERIAL_CLASS not in by_class:
        return None
    # Some records are keyed by name (head, torso, `default`) where the
    # material table names them by hash.
    for cls in (MATERIAL_CLASS, WINDOW_CLASS, BAND_CLASS):
        records = by_class.get(cls, {})
        for name in list(records):
            if not name.startswith('Hash_'):
                records.setdefault('Hash_%016X' % hash64(name), records[name])

    def resolve(cls, key, field):
        records, seen = by_class.get(cls, {}), 0
        while key in records and seen < 32:
            if field in records[key]['fields']:
                return records[key]['fields'][field]
            key, seen = records[key].get('parent', ''), seen + 1
        return None

    def word(cls, key, field, default=0):
        v = resolve(cls, key, field)
        return _words(v)[0] if v is not None and _words(v) else default

    def ref_key(field):
        data = ''.join(field.get('data', '').split()) if field else ''
        return 'Hash_' + data[16:32].upper() if len(data) >= 32 else None

    materials = []
    for m in range(143):
        kind, key = MATERIAL_KINDS[m], 'Hash_%016X' % MATERIAL_KEYS[m]
        row = {'kind': kind if key in by_class[MATERIAL_CLASS] else -1}
        if 0 <= kind < 3:
            row['ids'] = [word(MATERIAL_CLASS, key, f, -1) for f in MATERIAL_IDS[kind]]
        row['gain'] = max(0, min(32767, word(MATERIAL_CLASS, key, MATERIAL_GAIN)))
        row['pitch'] = word(MATERIAL_CLASS, key, MATERIAL_PITCH, 4096)
        windows = ref_key(resolve(MATERIAL_CLASS, key, MATERIAL_WINDOWS))
        if windows and windows in by_class.get(WINDOW_CLASS, {}):
            row['windows'] = [word(WINDOW_CLASS, windows, f) for f in WINDOW_FIELDS]
            scale = resolve(WINDOW_CLASS, windows, WINDOW_SCALE)
            row['scale'] = _number(scale) if scale is not None else 0.0
        bands = ref_key(resolve(MATERIAL_CLASS, key, MATERIAL_BANDS))
        if bands and bands in by_class.get(BAND_CLASS, {}):
            row['bands'] = [(_number(v) if (v := resolve(BAND_CLASS, bands, f)) is not None else 0.0) for f in BAND_FIELDS]
        materials.append(row)

    out = {'materials': materials}
    fe = frontend(by_class)
    if fe:
        out['frontend'] = fe
    holder = by_class.get(SURFACE_MAP[0], {}).get(SURFACE_MAP[1])
    if holder and SURFACE_MAP[2] in holder['fields']:
        surfaces = []
        for item in holder['fields'][SURFACE_MAP[2]]['array']['items']:
            data = ''.join(item.split())
            words = [struct.unpack('>i', bytes.fromhex(data[i:i + 8]))[0] for i in range(0, min(len(data), 144) - 7, 8)]
            words += [0] * (18 - len(words))
            # Rolling surface, footstep surface, collision class.
            surfaces.append([words[1], words[6], words[7]])
        out['surfaces'] = surfaces
        # A material for each kind of ground the mod tells apart: the first
        # world material (0..93) that rolls on that surface.
        grounds = {}
        for m, (rolling, _, _) in enumerate(surfaces[:94]):
            name = ROLLING.get(rolling)
            if name and name not in grounds and materials[m]['kind'] >= 0:
                grounds[name] = m
        out['grounds'] = grounds
    cooldown = resolve(BODY, 'default', BODY_COOLDOWN)
    if cooldown is not None:
        out['body_cooldown'] = _number(cooldown)
    graph = resolve(BODY, 'default', BODY_SPEED_GRAPH)
    if graph is not None:
        floats = _floats(graph)
        if len(floats) >= 20:
            out['body_speed'] = [floats[4:12], floats[12:20]]
    return out


def install(path, report=print):
    """export() of the collections file at `path`; None, with a note, when it
    can't be read."""
    path = Path(path)
    if not path.is_file():
        report('No converted vault next to the sounds: bails will use Half-Life 2 sounds.')
        return None
    try:
        table = export(json.loads(path.read_text(encoding='utf-8')))
    except (ValueError, KeyError, TypeError, struct.error) as error:
        report(f'Couldn\'t read the sound tuning ({error}): bails will use Half-Life 2 sounds.')
        return None
    if table is None:
        report('The vault has no collision sounds: bails will use Half-Life 2 sounds.')
        return None
    found = sum(1 for row in table['materials'] if row['kind'] >= 0)
    report(f'Read the collision sounds of {found} materials, grounds: {", ".join(sorted(table.get("grounds", {})))}; {len(table.get("frontend", {}))} interface sounds')
    return table
