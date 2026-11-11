"""Skate 3's own trick names. The engine names tricks by localisation ID, such
as ID_TRICK_FLIP_NOLLIE_KICKFLIP; the game's language tables on the disc say
what each one reads as. This pulls the trick entries out into
garrysmod/data/skate3/tricks.json for the score widget, and the D-pad
gestures' names (ID_GESTURE_*, as the Create-a-Skater gesture picker shows
them) into gestures.json, read with the engine's own front-end tools
(tools/vendor/skate3_ui)."""
from pathlib import Path
import json, sys, tempfile

# The front-end archives that can hold the tables; later ones win.
ARCHIVES = ('data/big/miscboot.big', 'data/big/fedata.big')
FROM_DISC = set(ARCHIVES)
LABELS = 'data/fe/languages/labels/language_labels_global_skate3ng.bin'
ENGLISH = 'data/fe/languages/english/language_english_global_skate3ng.bin'


def tables(engine, game):
    """The labels and English tables' bytes, from whichever archive has them."""
    sys.path.insert(0, str(Path(engine).resolve()))
    from tools.vendor.skate3_ui.big import BigArchive
    found = {}
    for name in ARCHIVES:
        path = Path(game) / name
        if not path.is_file():
            continue
        archive = BigArchive(path)
        for entry in archive.entries:
            key = entry.path.lower()
            if key in (LABELS, ENGLISH):
                found[key] = archive.read(entry)
    if len(found) < 2:
        raise RuntimeError("the disc's language tables weren't where they should be")
    return found[LABELS], found[ENGLISH]


def tricks(engine, labels, english, prefix='ID_TRICK_'):
    """ID_TRICK_ (or `prefix`) label to its English text."""
    from tools.vendor.skate3_ui.language import pair_language_tables
    with tempfile.TemporaryDirectory() as tmp:
        paths = Path(tmp) / 'labels.bin', Path(tmp) / 'english.bin'
        paths[0].write_bytes(labels)
        paths[1].write_bytes(english)
        pairs = pair_language_tables(*paths)
    out = {}
    for entry in pairs['entries']:
        label, value = entry['label'], entry['value']
        if label.startswith(prefix) and value and label not in out:
            out[label] = value.strip()
    return out


def install(engine, game, out, report):
    found = tables(engine, game)
    names = tricks(engine, *found)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'tricks.json').write_text(json.dumps(names, ensure_ascii=False, sort_keys=True), encoding='utf-8')
    report(f'Installed {len(names)} trick names')
    gestures = tricks(engine, *found, prefix='ID_GESTURE_')
    (out / 'gestures.json').write_text(json.dumps(gestures, ensure_ascii=False, sort_keys=True), encoding='utf-8')
    return len(names)
