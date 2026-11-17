"""Packages the setup app with PyInstaller: skate3_setup.py plus the engine's
converters (at the revision the skate host was built from), both skate
modules and vgmstream (which decodes the disc's sounds), as one executable for
the platform it runs on.

    python setup/package.py --engine <engine checkout> --modules <folder> --vgmstream <folder> --out <folder>
    python setup/package.py --folder --modules <folder> --out <folder>

--folder makes the plain S3GM-setup folder instead (see stage_folder): the
launchers and README on top, everything else in setup-files. The launcher
fetches a Python, the engine's converters and vgmstream on the player's
machine. The --modules folder decides which launchers go in: pass only the
Mac module for the Mac zip.

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


# Which launcher each skate module calls for: a zip only carries the
# launchers of the platforms it has a module for, so the Windows/Linux zip
# has no Mac launcher and the Mac zip has only the Mac one.
LAUNCHERS = {
    'gmcl_skate3_win64.dll': 'S3GM-setup-Windows.bat',
    'gmcl_skate3_linux64.dll': 'S3GM-setup-Linux.sh',
    'gmcl_skate3_osx64.dll': 'S3GM-setup-Mac.command',
}
# Everything but the launchers and the README goes in here, so a player
# opening S3GM-setup sees only what to double-click.
FILES = 'setup-files'
FILES_NOTE = """Nothing in this folder needs opening or double-clicking.

Go back up one folder (S3GM-setup) and double-click the setup for your computer:
  Windows:          S3GM-setup-Windows.bat
  Linux / SteamOS:  S3GM-setup-Linux.sh
  Mac:              S3GM-setup-Mac.command (in the Mac download)

The launcher fetches its own Python and the converters, then runs what is in
here. Starting skate3_setup.py or skate3-setup.sh yourself skips that.
"""


# The modules each download carries ('winlinux' is the main zip).
PLATFORMS = {
    'winlinux': ('gmcl_skate3_win64.dll', 'gmcl_skate3_linux64.dll'),
    'mac': ('gmcl_skate3_osx64.dll',),
}


def stage_folder(modules, out, platform=None):
    """The S3GM-setup folder players get:

        S3GM-setup/
            README-S3GM.txt
            S3GM-setup-Windows.bat, S3GM-setup-Linux.sh    (Windows/Linux zip)
            S3GM-setup-Mac.command                          (Mac zip)
            setup-files/    the setup's scripts, modules, addon and licences

    platform 'winlinux' or 'mac' picks that download's modules and launchers
    from `modules`; None takes every module there.
    """
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    files = out / FILES
    files.mkdir()
    wanted = PLATFORMS[platform] if platform else MODULES
    shipped = [m for m in MODULES if m in wanted and (modules / m).is_file()]
    launchers = [LAUNCHERS[m] for m in shipped]
    if not launchers:
        raise SystemExit(f'no skate module in {modules}, so no launcher to ship')
    for name in launchers + ['README-S3GM.txt']:
        shutil.copy2(HERE / name, out / name)
    for path in HERE.glob('*.py'):
        if not path.name.startswith('test_') and path.name not in ('package.py', 'bspmap.py', 'physbox.py'):
            shutil.copy2(path, files / path.name)
    # skate3-setup.sh runs the setup on Linux and Mac, windows-setup.ps1 on Windows.
    helpers = ['VERSION']
    if 'S3GM-setup-Linux.sh' in launchers or 'S3GM-setup-Mac.command' in launchers:
        helpers.append('skate3-setup.sh')
    if 'S3GM-setup-Windows.bat' in launchers:
        helpers.append('windows-setup.ps1')
    for name in helpers:
        shutil.copy2(HERE / name, files / name)
    (files / 'README.txt').write_text(FILES_NOTE, encoding='utf-8')
    for name in ('LICENSE', 'NOTICE'):
        if (HERE.parent / name).is_file():
            shutil.copy2(HERE.parent / name, files / name)
    if (HERE.parent / 'LICENSES').is_dir():
        shutil.copytree(HERE.parent / 'LICENSES', files / 'LICENSES')
    shutil.copytree(HERE / 'skate3_formats', files / 'skate3_formats',
                    ignore=shutil.ignore_patterns('__pycache__'))
    (files / 'bin').mkdir()
    for m in shipped:
        # A download carries only its own platforms' modules (the Mac zip only the Mac one).
        shutil.copy2(modules / m, files / 'bin' / m)
    # The audio cache's decoder and executable reader (one per platform), when built.
    for tool in ('skate-xma', 'skate-xex'):
        for name in (tool, tool + '.exe'):
            if (modules / name).is_file():
                shutil.copy2(modules / name, files / 'bin' / name)
    # An Apple-silicon Mac's setup Python can't load the Intel module: it loads this.
    if 'gmcl_skate3_osx64.dll' in shipped and (modules / ARM_TOOLS).is_file():
        shutil.copy2(modules / ARM_TOOLS, files / 'bin' / ARM_TOOLS)
    ignore = shutil.ignore_patterns('__pycache__', '.DS_Store')
    for part in ('lua', 'materials', 'resource', 'maps'):
        shutil.copytree(HERE.parent / 'addon' / part, files / 'addon' / part, ignore=ignore)
    shutil.copy2(HERE.parent / 'addon/addon.json', files / 'addon/addon.json')
    for launcher in launchers:
        if launcher.endswith(('.sh', '.command')):
            (out / launcher).chmod(0o755)
    if (files / 'skate3-setup.sh').exists():
        (files / 'skate3-setup.sh').chmod(0o755)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine', type=Path)
    parser.add_argument('--modules', type=Path, required=True)
    parser.add_argument('--vgmstream', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--folder', action='store_true')
    parser.add_argument('--platform', choices=sorted(PLATFORMS),
                        help="with --folder: which download to make (default: every module given)")
    args = parser.parse_args()
    if args.folder and args.platform == 'mac':
        stage_folder(args.modules, args.out.resolve(), 'mac')
        return
    # The Mac module is built by hand on a Mac, not in CI, so a download or
    # executable made without it is fine: only Windows and Linux are required.
    for m in MODULES[:2]:
        if not (args.modules / m).is_file():
            raise SystemExit(f'missing {args.modules / m}')
    if args.folder:
        stage_folder(args.modules, args.out.resolve(), args.platform)
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
