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
from native_tools import ARM_TOOLS  # noqa: E402
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
        if not path.name.startswith('test_') and path.name not in ('package.py', 'bspmap.py', 'physbox.py'):
            shutil.copy2(path, out / path.name)
    for name in ('skate3-setup.sh', 'S3GM-setup-Linux.sh', 'S3GM-setup-Mac.command', 'S3GM-setup-Windows.bat',
                 'windows-setup.ps1', 'VERSION', 'README-S3GM.txt'):
        if (HERE / name).is_file():
            shutil.copy2(HERE / name, out / name)
    shutil.copytree(HERE / 'skate3_formats', out / 'skate3_formats',
                    ignore=shutil.ignore_patterns('__pycache__'))
    (out / 'bin').mkdir()
    for m in MODULES:
        # A download can lack one platform's module (no Mac build yet).
        if (modules / m).is_file():
            shutil.copy2(modules / m, out / 'bin' / m)
    # The audio cache's decoder and executable reader (one per platform), when built.
    for tool in ('skate-xma', 'skate-xex'):
        for name in (tool, tool + '.exe'):
            if (modules / name).is_file():
                shutil.copy2(modules / name, out / 'bin' / name)
    # An Apple-silicon Mac's setup Python can't load the Intel module: it loads this.
    if (modules / ARM_TOOLS).is_file():
        shutil.copy2(modules / ARM_TOOLS, out / 'bin' / ARM_TOOLS)
    shutil.copytree(HERE.parent / 'addon/lua', out / 'addon/lua')
    shutil.copytree(HERE.parent / 'addon/materials', out / 'addon/materials')
    shutil.copytree(HERE.parent / 'addon/resource', out / 'addon/resource')
    shutil.copytree(HERE.parent / 'addon/maps', out / 'addon/maps')
    shutil.copy2(HERE.parent / 'addon/addon.json', out / 'addon/addon.json')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine', type=Path)
    parser.add_argument('--modules', type=Path, required=True)
    parser.add_argument('--vgmstream', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--folder', action='store_true')
    args = parser.parse_args()
    # The Mac module is built by hand on a Mac, not in CI, so a download or
    # executable made without it is fine: only Windows and Linux are required.
    for m in MODULES[:2]:
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
            if (args.modules / m).is_file():
                shutil.copy2(args.modules / m, bin_dir / m)
        # The audio cache's decoder and executable reader, when built.
        for tool in ('skate-xma', 'skate-xex'):
            for name in (tool, tool + '.exe'):
                if (args.modules / name).is_file():
                    shutil.copy2(args.modules / name, bin_dir / name)
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
            '--add-data', f'{HERE.parent / "addon/materials"}{sep}addon/materials',
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
