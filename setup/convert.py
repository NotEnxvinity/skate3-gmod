"""Converts the Skate 3 data the skate mode reads from the player's own
extracted default.xex: animation banks, state graphs, input and physics
settings, and the skater model.

Runs the converters in the `tools` tree of SK8-ENGINE/skate-3-rust-engine at
the revision the skate host was built from. Nothing is downloaded from the
game and nothing from it is bundled. Adapted from the IW4L skate converter in
chasmlol/2010-rust-rewrite-mashup (Apache-2.0).

    python convert.py --engine <engine checkout> --xex <default.xex> --out <folder>

Writes <folder>/assets on success, replacing only that, with the log beside
it as <folder>/conversion.log; progress lines go to stdout.
"""
from pathlib import Path
import argparse, shutil, sys, tempfile, traceback

REQUIRED = [
    'data/big/miscload.big',
    'data/big/miscboot.big',
    'data/big/db.big',
    'data/content/createacharacter.big',
]
PRODUCED = [
    'private/skater.glb',
    'private/game.json',
    'private/stock/physics-skeletons.json',
    'private/stock/skater-collections.json',
]


def convert(engine, xex, out, report=None):
    xex = xex.resolve()
    if xex.suffix.lower() == '.iso':
        raise RuntimeError('Give the ISO to skate3_setup.py, which reads it directly, or select default.xex in an extracted copy.')
    if xex.name.lower() != 'default.xex' or not xex.is_file():
        raise RuntimeError(f'Select default.xex from an extracted Skate 3 (Xbox 360) game folder, not {xex.name}.')
    game = xex.parent
    missing = [path for path in REQUIRED if not (game / path).is_file()]
    if missing:
        raise RuntimeError('This folder is missing Skate 3 game data (' + ', '.join(missing) +
                           '). Keep the data folder beside default.xex.')

    sys.path.insert(0, str(engine.resolve()))
    from tools.asset_pipeline import asset_exports as exports

    out = out.resolve()
    stage = out.with_name(out.name + '.partial')
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)

    if report is None:
        def report(text):
            print(text, flush=True)

    with tempfile.TemporaryDirectory(prefix='skate3-gmod-', dir=stage.parent) as work, \
            (stage / 'conversion.log').open('w', encoding='utf-8') as log:
        work = Path(work)
        converted = exports.core(game, stage, work, report, log)
        exports.character(game, stage, work, report, log, converted)

    assets = stage / 'assets'
    for needed in PRODUCED:
        if not (assets / needed).is_file():
            raise RuntimeError(f'Conversion finished without {needed}. See {stage / "conversion.log"}.')
    # Swap in only the converted data: the mod keeps its own files (error
    # logs, saved rides) in the same folder.
    out.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(out / 'assets', ignore_errors=True)
    assets.rename(out / 'assets')
    (out / 'conversion.log').unlink(missing_ok=True)
    (stage / 'conversion.log').rename(out / 'conversion.log')
    shutil.rmtree(stage, ignore_errors=True)
    report(f'Skate 3 data ready in {out / "assets"}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine', type=Path, required=True)
    parser.add_argument('--xex', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    try:
        convert(args.engine, args.xex, args.out)
    except Exception as error:
        traceback.print_exc()
        print(f'ERROR: {error}', flush=True)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
