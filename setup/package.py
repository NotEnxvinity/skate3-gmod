"""Packages the setup app with PyInstaller: skate3_setup.py plus the engine's
converters (at the revision the skate host was built from), both skate
modules and vgmstream (which decodes the disc's sounds), as one executable for
the platform it runs on.

    python setup/package.py --engine <engine checkout> --modules <folder> --vgmstream <folder> --out <folder>
    python setup/package.py --folder --modules <folder> --out <folder>

--folder makes a plain folder of our own source instead, run by
skate3-setup.sh with the system's Python; the launcher fetches the engine's
converters and vgmstream on the player's machine.

`--modules` holds gmcl_skate3_win64.dll and gmcl_skate3_linux64.dll;
`--vgmstream` holds that platform's vgmstream-cli release, with its licence.
"""
from pathlib import Path
import argparse, os, shutil, subprocess, sys, tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from skate3_setup import MODULES, converter_modules  # noqa: E402

KEEP = {'.py', '.json', '.txt', '.md', '.toml', '.rs'}


def stage_tools(engine, stage):
    """The engine's tools tree without tests, Blender scripts or the parts
    setup never runs."""
    tools = engine / 'tools'
    for path in tools.rglob('*'):
        rel = path.relative_to(tools)
        if not path.is_file() or '__pycache__' in rel.parts:
            continue
        if path.suffix not in KEEP and path.name != 'LICENSE':
            continue
        if rel.parts[0] == 'mixamo_to_skate' or 'blender' in rel.as_posix():
            continue
        out = stage / 'tools' / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, out)


def stage_folder(modules, out):
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    for path in HERE.glob('*.py'):
        if not path.name.startswith('test_') and path.name != 'package.py':
            shutil.copy2(path, out / path.name)
    shutil.copy2(HERE / 'skate3-setup.sh', out / 'skate3-setup.sh')
    (out / 'bin').mkdir()
    for m in MODULES:
        shutil.copy2(modules / m, out / 'bin' / m)
    shutil.copytree(HERE.parent / 'addon/lua', out / 'addon/lua')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine', type=Path)
    parser.add_argument('--modules', type=Path, required=True)
    parser.add_argument('--vgmstream', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--folder', action='store_true')
    args = parser.parse_args()
    for m in MODULES:
        if not (args.modules / m).is_file():
            raise SystemExit(f'missing {args.modules / m}')
    if args.folder:
        stage_folder(args.modules, args.out.resolve())
        return
    if args.engine is None or args.vgmstream is None:
        parser.error('--engine and --vgmstream are needed for the executable')
    if not any((args.vgmstream / name).is_file() for name in ('vgmstream-cli', 'vgmstream-cli.exe')):
        raise SystemExit(f'missing vgmstream-cli in {args.vgmstream}')
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp) / 'stage'
        stage_tools(args.engine.resolve(), stage)
        bin_dir = Path(tmp) / 'bin'
        bin_dir.mkdir()
        for m in MODULES:
            shutil.copy2(args.modules / m, bin_dir / m)
        sep = os.pathsep
        command = [
            sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onefile',
            '--name', 'skate3-gmod-setup',
            '--paths', str(HERE), '--paths', str(stage), '--paths', str(stage / 'tools'),
            '--hidden-import', 'numpy', '--hidden-import', 'PIL.Image', '--hidden-import', 'tkinter',
            '--exclude-module', 'bpy', '--exclude-module', 'mathutils',
            '--copy-metadata', 'numpy', '--copy-metadata', 'Pillow',
            '--add-data', f'{stage / "tools"}{sep}tools',
            '--add-data', f'{bin_dir}{sep}bin',
            '--add-data', f'{HERE.parent / "addon/lua"}{sep}addon/lua',
            '--add-data', f'{args.vgmstream.resolve()}{sep}vgmstream',
            '--distpath', str(args.out.resolve()),
            '--workpath', str(Path(tmp) / 'work'), '--specpath', str(Path(tmp) / 'spec'),
        ]
        for name in converter_modules(stage):
            command += ['--hidden-import', name]
        command.append(str(HERE / 'skate3_setup.py'))
        subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
