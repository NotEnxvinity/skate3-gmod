"""The board's other looks, from the player's own disc: every deck, truck and
wheel texture Skate 3's create-a-skater offers for the board the mod draws.

Skate 3 keeps them in createacharacter.big, catalogued in its CAS database
(SK8-ENGINE's customisation_catalog reads that). Only looks for the same
meshes the mod already draws are exported, since a texture made for another
deck shape wouldn't line up. Writes assets/boards/<slot>/<material>.png and
assets/boards/boards.json, which the settings list. Nothing here is
distributed: it is made on the player's machine from their disc.
"""
from pathlib import Path
import importlib.util, json, re, sys, tempfile

SLOTS = ('SkateBoard', 'SkateTruck', 'SkateWheel')
# The board the mod draws (the engine's default skater recipe).
MANIFEST = 'tools/default_skater_retail_manifest.json'
# Retail marks scuffed versions with a "_d" (dirty) part in their names.
WORN = re.compile(r'(?:^|[_ ])d(?:[_ ]|\d|$)|dirty|worn|used', re.I)


def label(name):
    text = re.sub(r'(?:0x)?[0-9a-f]{8,}', '', name, flags=re.I)
    text = re.sub(r'(?i)\b(diffuse|tga|mat|skateboard|instance|board|d|dirty)\b', '', text.replace('_', ' '))
    return re.sub(r'\s+', ' ', text).strip(' -').title() or 'Original'


def rx2_decoder(engine):
    """The engine's RX2 texture decoder with its fast paths, loaded the way
    its extract_default_skater does."""
    utt = engine / 'tools/vendor/utt'
    def load(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    module = load('skate3_boards_rx2_parser', utt / 'rx2_parser.py')
    fast = load('skate3_boards_rx2_fast', utt / 'rx2_fast.py')
    for name in ('decode_dxt1', 'decode_dxt1_normal', 'decode_dxt3', 'decode_dxt5',
                 'decode_ati2', '_untile360', '_decode_raw_a8r8g8b8',
                 '_decode_raw_b5g6r5', '_decode_raw_a8'):
        setattr(module, name, getattr(fast, name))
    return module


def export(engine, game, out, report):
    """Writes out/boards; returns how many looks it found."""
    engine = Path(engine).resolve()
    sys.path.insert(0, str(engine))
    from tools.owned_game.big import BigArchive
    from tools.asset_pipeline.customisation_catalog import parse_catalog, CATALOG_PATH

    archive = BigArchive(Path(game) / 'data/content/createacharacter.big')
    entries = {e.path.lower(): e for e in archive.entries}
    catalog = parse_catalog(archive.read(entries[CATALOG_PATH.lower()]), set(entries))
    recipe = json.loads((engine / MANIFEST).read_text())
    default = {c['slot']: c for c in recipe['components'] if c['slot'] in SLOTS}
    rx2 = rx2_decoder(engine)

    boards = {'version': 1, 'slots': {}}
    found = 0
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for component in catalog['components']:
            slot = component['slot']
            if slot not in SLOTS or slot not in default:
                continue
            mesh = default[slot]['model_id'].lower()
            looks = []
            for model in component['models']:
                lod = next((l for l in model['lods'] if l['index'] == 0), None)
                if not lod or lod['model_id'] != mesh or len(lod['material_instances']) != 1:
                    continue
                for variant in lod['material_instances'][0]:
                    textures = catalog['materials'][variant['id']]['textures']
                    diffuse = next((t for t in textures if t['channel'] == 'diffuse' and t['in_archive']), None)
                    if not diffuse:
                        continue
                    raw = tmp / (variant['id'] + '.rx2')
                    raw.write_bytes(archive.read(entries[diffuse['path'].lower()]))
                    png = out / slot / (variant['id'] + '.png')
                    try:
                        parsed = rx2.parse_rx2(raw)
                        png.parent.mkdir(parents=True, exist_ok=True)
                        parsed.textures[0].save_png(png)
                    except Exception as e:  # one bad texture shouldn't sink the rest
                        report(f'  skipped a {slot} look ({variant["name"]}): {e}')
                        continue
                    looks.append({'id': variant['id'], 'name': label(variant['name']),
                                  'source': variant['name'], 'model': model['name'],
                                  'worn': bool(WORN.search(variant['name'])),
                                  'default': variant['id'] == default[slot]['material_id'].lower(),
                                  'channels': [t['channel'] for t in textures]})
            looks.sort(key=lambda l: (not l['default'], l['name']))
            boards['slots'][slot] = looks
            found += len(looks)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'boards.json').write_text(json.dumps(boards, indent=1))
    report(f'Found {found} board looks on your disc: ' +
           ', '.join(f'{len(v)} {k[5:].lower()}' for k, v in boards['slots'].items()))
    return found
