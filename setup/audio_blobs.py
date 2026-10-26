"""The two tuning blobs the native audio engine reads, built from the vault
(the skater-collections.json the conversion writes) and the player's own
default.xex:

  SVGT  grain tuning: which rolling recording each ground uses and how its
        speed curve runs.
  SVAT  component tuning: every AEMS component record, the roots the engine
        binds them to, and two tables that live in the executable (the 14
        grind surfaces and the 143-row impact material table).

The layouts, class keys and root offsets are retail's, as recovered by SK8V
(https://github.com/becaring/SK8V, Apache-2.0, tools/prepare-audio-tuning.py);
this is that importer ported to this setup: hashing from audio_tuning.py, the
executable decoded by native/skate-xex. The output is the player's own data
and stays on their machine.
"""
import hashlib, os, struct, subprocess, sys, tempfile
from pathlib import Path

import audio_tuning

HERE = Path(__file__).resolve().parent


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


CLASS = 'Hash_7AB23C11B6ADA2DE'
DEFAULT = 0xD7EDBD362D7D2152
CURVE = ['4890392C91829954', 'CEC749561306022A', 'D380D303C64CF6F8',
         '1F459FC797B2C6BA', '5C9AA28695C17004', '145D8340A9440DA3']

# Native root offsets, class and collection identities. These are bindings,
# not tuning values. Every value/record is read from the owned collection dump.
ROOTS = {
    4: ('7AB23C11B6ADA2DE', 'default'),
    24: ('C26949FCB638A2CA', 'default'),
    28: ('7242F32831ED3332', 'default'),
    40: ('049861E8F9A8D16B', 'default'),
    44: ('B29C3B2C13D96482', 'default'),
    48: ('4CDD7CDC1A955D5C', 'Hash_DFDFFAD67CCBA322'),
    52: ('4CDD7CDC1A955D5C', 'Hash_C6290FFCB9E84CD9'),
    60: ('C1831BDB6CB1B1EA', 'Hash_55D801EDE7E338B6'),
    68: ('C1831BDB6CB1B1EA', 'Hash_EE7B8A8A893A4E30'),
    72: ('C1831BDB6CB1B1EA', 'Hash_1FA8AC006CABEF59'),
    76: ('C1831BDB6CB1B1EA', 'Hash_A7BCD60FF7ECDE26'),
    80: ('C1831BDB6CB1B1EA', 'Hash_03B710C80E1AC13E'),
    84: ('C1831BDB6CB1B1EA', 'Hash_BA9837A6CF4C26ED'),
    88: ('C1831BDB6CB1B1EA', 'Hash_BA0152E2B687BF9F'),
    96: ('C1831BDB6CB1B1EA', 'Hash_621090620F4F936A'),
    100: ('C1831BDB6CB1B1EA', 'Hash_0848917DC9CE302A'),
    104: ('C1831BDB6CB1B1EA', 'Hash_03148322DE1F6329'),
    # Board foley splice tables (catch, skeleton edges, trick 38).
    108: ('923CCB46EF5BF5BA', 'Hash_F1647BFB782BE97F'),
    112: ('923CCB46EF5BF5BA', 'Hash_E0C3B44AB44F7B90'),
    116: ('923CCB46EF5BF5BA', 'Hash_2738D2A24DFBA28D'),
    36: ('6EBA5BCD3E38A98A', 'default'),
    56: ('C1831BDB6CB1B1EA', 'Hash_7B0ED922C779B74C'),
    64: ('C1831BDB6CB1B1EA', 'Hash_C489459A0C07D154'),
    92: ('C1831BDB6CB1B1EA', 'Hash_1ABD2984D7248589'),
    132: ('6E878344774A7999', 'default'),
    136: ('A867FBE3454326FF', 'default'),
    140: ('42AFE160E647167C', 'default'),
}
COMPONENT_CLASSES = {int(c, 16) for c, _ in ROOTS.values()} | {
    0x049861E8F9A8D16B, 0x11A631878B239355, 0x7242F32831ED3332,
    0x7AB23C11B6ADA2DE,
    # Impact materials, their levels and thresholds (0x82482580, 0x82496C58).
    0xD40CB4C0FFE45676, 0x13E20D398E385A56, 0x7DAFF70B3A91CD5D,
    # Footstep filter envelopes (0x824E9FD8 via 0x82493448).
    0x370AF2704BFA6866,
    # Frontend sound events (0x824955B8 via 0x82489A20): the combo
    # multiplier sounds (0x82666BC0).
    0x5831CB95F3E90598,
}
# Impact material table (0x8302D6E8): 143 rows of splice slot word, pad,
# material collection key.
MATERIAL_TABLE, MATERIAL_ROWS, MATERIAL_CLASS = 0x8302D6E8, 143, 0xD40CB4C0FFE45676


# Known base-disc executables: XEX SHA-256 -> where the two tables sit in its
# decoded image (the importer reads them at their TU3 addresses) and their hashes.
XEX_PROFILES = {
    '1db39496585c521d17a2137804f42cf73ebed2b32cac166ec42dbf772f4dcf7f': {
        'grind': 0x82244F60, 'impact': 0x82FD1930,
        'grind_sha256': '53fa0d38856ea03f5a8ef1dd6ed55ce240a31b88845df7b97f49f057a2162e1c',
        'impact_sha256': '01c865ef1d1530b4e4433c721ca3188d63a43b55d4c599b383f6dc4e2b94a956',
    },
}
GRIND_TABLE = 0x82249F90


def find_xex_tool(given=None):
    """skate-xex: bundled in the app, from SKATE3_XEX, a cargo build, or on PATH."""
    name = 'skate-xex.exe' if os.name == 'nt' else 'skate-xex'
    root = Path(getattr(sys, '_MEIPASS', HERE))
    candidates = [given, root / 'bin' / name, os.environ.get('SKATE3_XEX')]
    candidates += [HERE.parent / 'target' / 'release' / name]
    if os.environ.get('CARGO_TARGET_DIR'):
        candidates.append(Path(os.environ['CARGO_TARGET_DIR']) / 'release' / name)
    candidates.append(__import__('shutil').which('skate-xex'))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise FileNotFoundError('skate-xex not found (cargo build --release -p skate-xex, or set SKATE3_XEX)')


def image_from_xex(xex, tool=None):
    """Decode a known base default.xex and return (canonical-address image, decoded image sha256).

    Only the two tables are copied, at the TU3 addresses encode_components reads."""
    digest = sha256_file(xex)
    profile = XEX_PROFILES.get(digest)
    if profile is None:
        raise ValueError(f'unsupported Skate 3 executable {digest}')
    with tempfile.TemporaryDirectory() as temp:
        decoded = Path(temp) / 'image.bin'
        subprocess.run([str(find_xex_tool(tool)), str(xex), str(decoded)], check=True, capture_output=True)
        base = decoded.read_bytes()
    image = bytearray(MATERIAL_TABLE + MATERIAL_ROWS * 16 - 0x82000000)
    for name, size, target in (('grind', 14 * 8, GRIND_TABLE), ('impact', MATERIAL_ROWS * 16, MATERIAL_TABLE)):
        at = profile[name] - 0x82000000
        span = base[at:at + size]
        if len(span) != size or sha256(span) != profile[name + '_sha256']:
            raise ValueError(f'decoded {name} table does not match the known profile')
        image[target - 0x82000000:target - 0x82000000 + size] = span
    return bytes(image), sha256(base)


def identity(name):
    """The vault's id for a key: Hash_<16 hex> as is, a name hashed."""
    if name.startswith('Hash_'):
        if len(name) != 21:
            raise ValueError('invalid numeric identity: ' + name)
        return int(name[5:], 16)
    return audio_tuning.hash64(name)


def resolved_components(document, classes=COMPONENT_CLASSES):
    """Same-class inheritance with numeric/name alias normalization."""
    if document.get('version', 1) != 1:
        raise ValueError('unsupported collection export version')
    source = {}
    for item in document['collections']:
        class_key = identity(item['class'])
        if class_key not in classes:
            continue
        key = (class_key, identity(item['key']))
        if key in source:
            raise ValueError('duplicate component collection identity')
        fields = {}
        for name, value in item['fields'].items():
            field = identity(name)
            if field in fields:
                raise ValueError('duplicate component field identity')
            fields[field] = value
        source[key] = (identity(item['parent']), fields)
    done = {}

    def resolve(key, chain):
        if key in done:
            return done[key]
        if key in chain:
            raise ValueError('component collection inheritance cycle')
        if key not in source:
            raise ValueError('missing component collection parent')
        parent, own = source[key]
        fields = dict(resolve((key[0], parent), chain | {key})) if parent else {}
        fields.update(own)
        done[key] = fields
        return fields

    for key in source:
        resolve(key, set())
    return done


def field_bytes(field):
    """Return stride/count/payload; arrays retain their complete raw records."""
    array = field.get('array')
    if array is not None:
        size = array['element_size']
        if not isinstance(size, int) or not 0 < size <= 65536:
            raise ValueError('invalid component array stride')
        records = [bytes.fromhex(value) for value in array['items']]
        if len(records) > 65536 or any(len(value) != size for value in records):
            raise ValueError('invalid component array records')
        return size, len(records), b''.join(records)
    if field['type'] == 'EA::Reflection::Text':
        if '\0' in field['data']:
            raise ValueError('embedded NUL in component text')
        data = field['data'].encode('utf-8') + b'\0'
    else:
        data = bytes.fromhex(field['data'])
    if not 0 < len(data) <= 65536:
        raise ValueError('invalid component field size')
    return len(data), 1, data


def encode_components(document, guest_image, roots=ROOTS, classes=COMPONENT_CLASSES):
    """SVAT v1: resolved records, root bindings, then immutable TU3 table words.

    The image is an owned executable image based at 0x82000000, not a heap.
    Only the 14 grind surface collection identities and the 143-row impact
    material table (splice slot words and collection identities) are
    consumed from it.
    """
    collections = resolved_components(document, classes)
    bindings = [(root, int(c, 16), identity(k)) for root, (c, k) in sorted(roots.items())]
    if any((c, k) not in collections for _, c, k in bindings):
        raise ValueError('missing required component root collection')
    fixed = []
    if guest_image is not None:
        offset = GRIND_TABLE - 0x82000000
        table = guest_image[offset:offset + 14 * 8]
        if len(table) != 14 * 8:
            raise ValueError('owned image lacks grind collection table')
        for index, (key,) in enumerate(struct.iter_unpack('>Q', table)):
            if (0x049861E8F9A8D16B, key) not in collections:
                raise ValueError('owned grind table does not match converted collections')
            fixed.extend([(GRIND_TABLE + index * 8, key >> 32),
                          (GRIND_TABLE + 4 + index * 8, key & 0xFFFFFFFF)])
        offset = MATERIAL_TABLE - 0x82000000
        table = guest_image[offset:offset + MATERIAL_ROWS * 16]
        if len(table) != MATERIAL_ROWS * 16:
            raise ValueError('owned image lacks impact material table')
        for index, (slot, pad, key) in enumerate(struct.iter_unpack('>IIQ', table)):
            if key and (MATERIAL_CLASS, key) not in collections:
                raise ValueError('owned material table does not match converted collections')
            at = MATERIAL_TABLE + index * 16
            fixed.extend([(at, slot), (at + 4, pad), (at + 8, key >> 32), (at + 12, key & 0xFFFFFFFF)])
    out = bytearray(b'SVAT' + struct.pack('>IIII', 1, len(collections), len(bindings), len(fixed)))
    for (class_key, collection_key), fields in sorted(collections.items()):
        out += struct.pack('>QQI', class_key, collection_key, len(fields))
        for key, value in sorted(fields.items()):
            stride, count, payload = field_bytes(value)
            out += struct.pack('>QII', key, stride, count) + payload
    for root, class_key, collection_key in bindings:
        out += struct.pack('>IQQ', root, class_key, collection_key)
    for address, word in fixed:
        out += struct.pack('>II', address, word)
    return bytes(out)


def inherited(collections):
    """Resolve same-class inheritance; reject missing parents and cycles."""
    by_key = {}
    for c in collections:
        if c['class'] != CLASS:
            continue
        if c['key'] in by_key:
            raise ValueError('duplicate grain collection')
        by_key[c['key']] = c
    done = {}

    def resolve(key, chain):
        if key in done:
            return done[key]
        if key in chain:
            raise ValueError('grain collection inheritance cycle')
        if key not in by_key:
            raise ValueError('missing grain parent: ' + key)
        c = by_key[key]
        fields = dict(resolve(c['parent'], chain | {key})) if c['parent'] else {}
        fields.update(c['fields'])
        done[key] = fields
        return fields

    for key in by_key:
        resolve(key, set())
    return done


def encode_grains(document):
    if document.get('version', 1) != 1:
        raise ValueError('unsupported collection export version')
    collections = inherited(document['collections'])
    if not collections or 'default' not in collections:
        raise ValueError('grain tuning class/default absent')
    out = bytearray(b'SVGT' + struct.pack('>II', 1, len(collections)))
    for key, fields in sorted(collections.items()):
        def raw(k, size):
            b = bytes.fromhex(fields['Hash_' + k]['data'])
            if len(b) != size:
                raise ValueError('wrong field size: ' + k)
            return b
        collection = DEFAULT if key == 'default' else int(key.removeprefix('Hash_'), 16)
        filename = fields['Hash_2C073BF8BC45063B']['data']
        # Retail default collection selects recording zero in 824C8370.
        name = filename.removesuffix('.grain') if filename else 'asphalt_rough_hard'
        if not name or not all(c.isascii() and (c.isalnum() or c == '_') for c in name):
            raise ValueError('unsafe grain name')
        name = name.encode('ascii')
        curve = raw('A985FBAA9326718D', 64) + b'\0' * 4 + b''.join(raw(k, 4) for k in CURVE)
        params = fields['Hash_D18D1174735E5CDE']['array']
        if params['element_size'] != 20 or len(params['items']) != 2:
            raise ValueError('invalid grain player parameters')
        players = b''.join(bytes.fromhex(item) for item in params['items'])
        if len(players) != 40:
            raise ValueError('invalid grain player parameter size')
        scalar = [(int(k.removeprefix('Hash_'), 16), bytes.fromhex(v['data']))
                  for k, v in fields.items() if v['type'] in
                  ('EA::Reflection::Float', 'EA::Reflection::Int32', 'EA::Reflection::UInt32')]
        if any(len(v) != 4 for _, v in scalar):
            raise ValueError('invalid scalar size')
        out += struct.pack('>QHH', collection, len(name), len(scalar)) + name + curve + players
        for k, value in sorted(scalar):
            out += struct.pack('>Q', k) + value
    return bytes(out)
