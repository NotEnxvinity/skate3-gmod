"""Skate 3 for Garry's Mod setup: pick your own Skate 3 (Xbox 360) disc image
or extracted game, and this finds Garry's Mod, installs the skate module into
garrysmod/lua/bin, converts the game data the mod needs into
garrysmod/data/skate3 and the skate sounds into garrysmod/sound/skate3. Run it
once, and again after an update.
The Lua addon itself comes from the Steam Workshop.

Nothing from the game is downloaded or bundled: everything comes off the disc
you pick, on your own machine.

    skate3-gmod-setup                    the setup window
    skate3-gmod-setup --game <iso|xex>   the same without a window
          [--gmod <garrysmod folder>]
          [--with-addon]                 also install the Lua addon, for
                                         testing a build the Workshop
                                         doesn't have yet
"""
from pathlib import Path
import argparse, os, queue, re, runpy, shutil, sys, tempfile, threading, traceback

FROZEN = getattr(sys, 'frozen', False)
# The packaged app carries the engine's converters and the modules here.
ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

import audio, convert, names, xdvdfs  # noqa: E402

MODULES = ('gmcl_skate3_win64.dll', 'gmcl_skate3_linux64.dll', 'gmcl_skate3_osx64.dll')
# What the converters read off the disc, so an ISO needs only these copied out.
FROM_DISC = {
    'default.xex',
    'data/big/miscload.big',
    'data/big/miscboot.big',
    'data/big/db.big',
    'data/content/createacharacter.big',
    *audio.FROM_DISC,
    *names.FROM_DISC,
}
FROM_DISC_FOLDERS = ('data/anim/',)
# The engine's top-level scripts the converters run as steps, and the ones
# those import as siblings.
TASK_SCRIPTS = ('prepare_runtime_huds', 'prepare_hud', 'extract_session_marker',
                'install_prepared_hud', 'extract_default_skater')


def converter_modules(engine):
    """Module names of every engine file the conversion can load. The
    packager bundles these and the self-test imports them."""
    tools = engine / 'tools'
    names = []
    for path in sorted(tools.rglob('*.py')):
        rel = path.relative_to(tools)
        parts = rel.with_suffix('').parts
        if parts[-1].startswith('test_') or parts[-1] == '__init__':
            continue
        if len(parts) == 1 and parts[0] not in TASK_SCRIPTS:
            continue
        if parts[0] == 'mixamo_to_skate' or parts[:2] == ('vendor', 'university'):
            continue
        if parts[:2] == ('asset_pipeline', 'build_map') or parts[:2] == ('asset_pipeline', 'finish_character'):
            continue
        names.append('tools.' + '.'.join(parts))
    return names


def windows_drives():
    """Every local hard drive and removable drive letter (C:\\, D:\\, ...)."""
    import ctypes
    kernel = ctypes.windll.kernel32
    kernel.SetErrorMode(1)  # an empty card reader must not pop up "no disk"
    mask = kernel.GetLogicalDrives()
    drives = []
    for i in range(26):
        if mask & (1 << i):
            drive = f'{chr(65 + i)}:\\'
            if kernel.GetDriveTypeW(drive) in (2, 3):
                drives.append(Path(drive))
    return drives


def steam_roots():
    roots = []
    if os.name == 'nt':
        try:
            import winreg
            for hive, key_name, value in ((winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam', 'SteamPath'),
                                          (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'),
                                          (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\Valve\Steam', 'InstallPath')):
                try:
                    with winreg.OpenKey(hive, key_name) as key:
                        roots.append(Path(winreg.QueryValueEx(key, value)[0]))
                except OSError:
                    pass
        except ImportError:
            pass
        roots += [Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Steam']
        # Steam itself or a game library can sit on any drive, under any of the usual names.
        try:
            drives = windows_drives()
        except Exception:
            drives = []
        for drive in drives:
            roots += [drive / name for name in ('Steam', 'SteamLibrary', 'Steam Library', 'Program Files (x86)/Steam',
                                                 'Program Files/Steam', 'Games/Steam', 'Games/SteamLibrary',
                                                 'Games/Steam Library')]
    else:
        home = Path.home()
        roots += [home / 'Library/Application Support/Steam', home / '.local/share/Steam', home / '.steam/steam', home / '.steam/root',
                  home / '.var/app/com.valvesoftware.Steam/.local/share/Steam']
    return [r for r in roots if r.is_dir()]


def libraries(root):
    found = [root]
    for vdf in (root / 'steamapps/libraryfolders.vdf', root / 'config/libraryfolders.vdf'):
        if vdf.is_file():
            text = vdf.read_text(encoding='utf-8', errors='replace')
            # New format: "path" "D:\\SteamLibrary"; old format: "1" "D:\\SteamLibrary".
            paths = re.findall(r'"path"\s+"([^"]+)"', text) + re.findall(r'"\d+"\s+"([^"]*[\\/][^"]*)"', text)
            found += [Path(p.replace('\\\\', '\\')) for p in paths]
    return found


def gmod_install_names(library):
    """GarrysMod, or whatever folder name the library's Gmod manifest says."""
    names = ['GarrysMod']
    manifest = library / 'steamapps/appmanifest_4000.acf'
    if manifest.is_file():
        match = re.search(r'"installdir"\s+"([^"]+)"', manifest.read_text(encoding='utf-8', errors='replace'))
        if match and match.group(1) not in names:
            names.insert(0, match.group(1))
    return names


def is_garrysmod(folder):
    return (folder / 'gameinfo.txt').is_file() or ((folder / 'lua').is_dir() and (folder / 'addons').is_dir())


def garrysmod_in(picked):
    """The garrysmod folder for whatever the player picked: the garrysmod folder
    itself, the GarrysMod folder, a Steam library or its steamapps/common, or a
    whole drive. None if there's no Gmod in there."""
    picked = Path(picked)
    for candidate in (picked, picked / 'garrysmod', picked / 'GarrysMod/garrysmod', picked / 'common/GarrysMod/garrysmod',
                      picked / 'steamapps/common/GarrysMod/garrysmod'):
        if candidate.is_dir() and is_garrysmod(candidate):
            return candidate
    if picked.name.lower() == 'garrysmod' and picked.is_dir():
        return picked
    roots = [picked] + [picked / name for name in ('Steam', 'SteamLibrary', 'Steam Library', 'Program Files (x86)/Steam',
                                                   'Program Files/Steam', 'Games/Steam', 'Games/SteamLibrary')]
    libraries_found = [library for root in roots if (root / 'steamapps').is_dir() for library in libraries(root)]
    for library in libraries_found:
        for name in gmod_install_names(library):
            folder = library / 'steamapps/common' / name / 'garrysmod'
            if folder.is_dir():
                return folder
    return None


def find_gmod():
    """The garrysmod folder of the first Garry's Mod install found, or None."""
    seen = set()
    for root in steam_roots():
        for library in libraries(root):
            key = str(library).lower().rstrip('\\/')
            if key in seen:
                continue
            seen.add(key)
            for name in gmod_install_names(library):
                folder = library / 'steamapps/common' / name / 'garrysmod'
                if folder.is_dir():
                    return folder
    return None


def own_module():
    """This computer's skate module (the Mac download carries only its own)."""
    if os.name == 'nt':
        return 'gmcl_skate3_win64.dll'
    return 'gmcl_skate3_osx64.dll' if sys.platform == 'darwin' else 'gmcl_skate3_linux64.dll'


def module_dir():
    """Where the skate modules come from: inside the app, or beside setup in
    the CI download (skate3-gmod/garrysmod/lua/bin)."""
    for folder in (ROOT / 'bin', HERE.parent / 'garrysmod/lua/bin'):
        if (folder / own_module()).is_file():
            return folder
    return None


def addon_dir():
    """The Lua addon: inside the app, in a source checkout, or in the CI
    download (skate3-gmod/garrysmod/addons/skate3/lua)."""
    for folder in (ROOT / 'addon/lua', HERE.parent / 'addon/lua', HERE.parent / 'garrysmod/addons/skate3/lua'):
        if (folder / 'autorun').is_dir():
            return folder
    return None


def engine_dir():
    """The engine's converters: bundled in the app, or SKATE3_ENGINE when
    running from source (the Linux script fetches them there)."""
    if (ROOT / 'tools/asset_pipeline').is_dir():
        return ROOT
    env = os.environ.get('SKATE3_ENGINE')
    if env and (Path(env) / 'tools/asset_pipeline').is_dir():
        return Path(env)
    if env:
        # Started by the launcher, so it fetched them, yet they aren't there:
        # say where it looked, so a broken download can be deleted.
        raise RuntimeError(f'The Skate 3 engine converters are missing from {env} (no tools/asset_pipeline in it). '
                           f'Delete the folder {Path(env).parent} and run {launcher()} again; '
                           'if it keeps happening, an antivirus may be removing files there.')
    raise RuntimeError('The Skate 3 engine converters are missing: start the setup with '
                       + launcher() + ', not skate3_setup.py itself. It fetches the converters and its own Python.')


def launcher():
    """The script that fetches the converters and starts this, for this OS."""
    if os.name == 'nt':
        return 'S3GM-setup-Windows.bat'
    return 'S3GM-setup-Mac.command' if sys.platform == 'darwin' else 'skate3-setup.sh'


def relaunch():
    """Started straight from skate3_setup.py (a double-click opens .py files
    with whatever Python is installed): hand over to the launcher, which
    fetches the converters and a Python they work with. Returns its exit code,
    or None when this run is already the launcher's."""
    if FROZEN or os.environ.get('SKATE3_ENGINE') or (ROOT / 'tools/asset_pipeline').is_dir():
        return None
    import subprocess
    if os.name == 'nt':
        script = HERE / 'windows-setup.ps1'
        command = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)]
    else:
        script = HERE / 'skate3-setup.sh'
        command = ['bash', str(script)]
    if not script.is_file():
        return None
    print(f'Starting {script.name}, which fetches what the setup needs...', flush=True)
    return subprocess.call(command + sys.argv[1:])


def game_folder(selected, work, report):
    """An extracted game folder for what the player picked: the folder
    holding default.xex, or the needed files copied out of an ISO."""
    selected = Path(selected)
    if selected.is_dir():
        selected = selected / 'default.xex'
    if selected.suffix.lower() == '.iso':
        report('Reading your Skate 3 disc image')
        out = work / 'disc'
        with xdvdfs.Image(selected) as disc:
            disc.extract(out, lambda p: p in FROM_DISC or p.startswith(FROM_DISC_FOLDERS), report)
        return out / 'default.xex'
    return selected


def install_addon(gmod, wanted, report):
    """The Lua normally comes from the Workshop. A copy in addons/skate3 (from
    an older setup, or a test build) would load instead of it, so it's only
    kept when asked for."""
    local = gmod / 'addons/skate3'
    if not wanted:
        if (local / 'lua/skate3').is_dir():
            shutil.rmtree(local, ignore_errors=True)
            report(f'Removed the old addon copy in {local}; the Workshop one is used now')
        report('Subscribe to "S3GM: Skate 3 in Gmod" on the Steam Workshop if you haven\'t yet: '
               'steamcommunity.com/sharedfiles/filedetails/?id=3814357793')
        return
    addon = addon_dir()
    if addon is None:
        raise RuntimeError('The Lua addon is missing from this setup.')
    # Replaced whole, so files an update removed don't linger.
    shutil.rmtree(local / 'lua', ignore_errors=True)
    shutil.copytree(addon, local / 'lua')
    # The spawn menu and weapon switcher icons sit beside the Lua.
    if (addon.parent / 'materials').is_dir():
        shutil.rmtree(local / 'materials', ignore_errors=True)
        shutil.copytree(addon.parent / 'materials', local / 'materials')
    report(f'Installed the addon in {local}; it loads instead of the Workshop one until setup runs without it')


def install(selected, gmod, report, with_addon=False):
    gmod = garrysmod_in(gmod) or Path(gmod)
    if not (gmod / 'gameinfo.txt').is_file() and not (gmod / 'lua').is_dir():
        raise RuntimeError(f"{gmod} doesn't look like a garrysmod folder.")
    modules = module_dir()
    if modules is None:
        raise RuntimeError('The skate modules are missing from this setup.')
    bin_dir = gmod / 'lua/bin'
    bin_dir.mkdir(parents=True, exist_ok=True)
    for m in MODULES:
        if (modules / m).is_file():
            shutil.copy2(modules / m, bin_dir / m)
    report(f'Installed the skate module in {bin_dir}')
    install_addon(gmod, with_addon, report)

    data = gmod / 'data/skate3'
    data.parent.mkdir(parents=True, exist_ok=True)
    # Beside the output, so a disc image's files land on the same drive.
    with tempfile.TemporaryDirectory(prefix='skate3-setup-', dir=data.parent) as work:
        xex = game_folder(selected, Path(work), report)
        convert.convert(engine_dir(), xex, data, report)
        # Without these the score widget spells the trick IDs out itself.
        try:
            names.install(engine_dir(), xex.parent, data, report)
        except Exception as error:
            traceback.print_exc()
            report(f'Couldn\'t read the trick names ({error}); the score widget will spell them out.')
        # The mod plays Half-Life 2 sounds without these, so a problem here
        # doesn't undo the rest.
        try:
            audio.install(xex.parent, gmod / 'sound/skate3', report,
                          collections=data / 'assets/private/stock/skater-collections.json')
        except Exception as error:
            traceback.print_exc()
            report(f'Couldn\'t install the skate sounds ({error}); the mod will use Half-Life 2 sounds.')
    report('All set. Start Garry\'s Mod, load a map and equip the Skateboard.')


def run_task():
    """`--task <script> args`: the engine's converters run some steps as their
    own process, and in the packaged app that process is this executable."""
    script = Path(sys.argv[2])
    if not script.is_absolute():
        script = ROOT / script
    script = script.resolve()
    if not script.is_relative_to((ROOT / 'tools').resolve()):
        raise RuntimeError('Invalid conversion script')
    sys.path.insert(0, str(script.parent))
    sys.argv = [str(script), *sys.argv[3:]]
    runpy.run_path(str(script), run_name='__main__')


def self_test():
    """Imports everything the converters use, to prove the packaged app
    carries it. CI runs this; it needs no game data."""
    import importlib
    engine = engine_dir()
    sys.path.insert(0, str(engine / 'tools'))
    for name in converter_modules(engine):
        try:
            importlib.import_module(name)
        except ImportError as error:
            raise RuntimeError(f'{name}: {error}') from error
    if module_dir() is None:
        raise RuntimeError('skate modules missing')
    if addon_dir() is None:
        raise RuntimeError('Lua addon missing')
    vgmstream = audio.find_vgmstream()
    if vgmstream is None:
        raise RuntimeError('vgmstream-cli missing')
    audio.check(vgmstream)
    print(f'self-test ok: {len(converter_modules(engine))} converter modules')


def window(gmod, with_addon_default=False):
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
    root = tk.Tk()
    root.title('S3GM setup')
    root.geometry('720x520')
    root.minsize(560, 420)
    frame = ttk.Frame(root, padding=20)
    frame.pack(fill='both', expand=True)
    ttk.Label(frame, text='S3GM: Skate 3 in Garry\'s Mod', font=('TkDefaultFont', 18, 'bold')).pack(anchor='w')
    ttk.Label(frame, justify='left', wraplength=620, text=(
        'Pick your own Skate 3 (Xbox 360) disc image (.iso), or default.xex in an extracted copy. '
        'Setup installs the skate engine and converts what it needs from your disc; '
        'the addon itself comes from the Steam Workshop. '
        'Nothing is downloaded from the game. It takes a few minutes and runs once.')).pack(anchor='w', pady=(6, 12))

    target = tk.StringVar(value=str(gmod) if gmod else '')
    row = ttk.Frame(frame)
    row.pack(fill='x')
    ttk.Label(row, text='Garry\'s Mod:').pack(side='left')
    ttk.Entry(row, textvariable=target).pack(side='left', fill='x', expand=True, padx=6)

    def browse_gmod():
        picked = filedialog.askdirectory(parent=root, title='Select the garrysmod folder (inside GarrysMod)')
        if picked:
            target.set(picked)
    ttk.Button(row, text='Change...', command=browse_gmod).pack(side='left')

    with_addon = tk.BooleanVar(value=with_addon_default)
    ttk.Checkbutton(frame, variable=with_addon, text=(
        'Also install the Lua addon (only for testing a build that isn\'t on the Workshop yet)')).pack(anchor='w', pady=(10, 0))

    # Above the log, so a short window can't push it out of sight.
    button = ttk.Button(frame, text='Select your Skate 3 disc...')
    button.pack(anchor='w', pady=(12, 0))
    log = tk.Text(frame, height=10, state='disabled', wrap='word')
    log.pack(fill='both', expand=True, pady=12)
    progress = ttk.Progressbar(frame, mode='indeterminate')
    progress.pack(fill='x')
    messages = queue.Queue()

    def say(text):
        log.configure(state='normal')
        log.insert('end', text + '\n')
        log.see('end')
        log.configure(state='disabled')

    def start():
        if not target.get():
            messagebox.showerror('Setup', 'Garry\'s Mod wasn\'t found. Use Change... to pick its garrysmod folder.')
            return
        picked = filedialog.askopenfilename(parent=root, title='Select your Skate 3 disc image or default.xex',
                                            filetypes=[('Skate 3', '*.iso *.xex'), ('All files', '*')])
        if not picked:
            return
        button.configure(state='disabled')
        progress.start()
        wanted = with_addon.get()

        def work():
            try:
                install(picked, target.get(), lambda text: messages.put(('log', text)), wanted)
                messages.put(('done', None))
            except Exception as error:
                traceback.print_exc()
                messages.put(('error', str(error)))
        threading.Thread(target=work, daemon=True).start()

    def poll():
        while not messages.empty():
            kind, text = messages.get()
            if kind == 'log':
                say(text)
            else:
                progress.stop()
                button.configure(state='normal')
                if kind == 'done':
                    messagebox.showinfo('Setup', 'All set! Start Garry\'s Mod, load a map and equip the Skateboard.')
                else:
                    say('ERROR: ' + text)
                    messagebox.showerror('Setup', text)
        root.after(100, poll)

    button.configure(command=start)
    if not gmod:
        say('Garry\'s Mod wasn\'t found automatically. Use Change... to pick its garrysmod folder.')
    poll()
    root.mainloop()


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--task':
        run_task()
        return 0
    relaunched = relaunch()
    if relaunched is not None:
        return relaunched
    parser = argparse.ArgumentParser(description='S3GM setup')
    parser.add_argument('--game', type=Path, help='your Skate 3 disc image (.iso) or extracted default.xex')
    parser.add_argument('--gmod', type=Path, help='the garrysmod folder (found automatically if left out)')
    parser.add_argument('--with-addon', action='store_true',
                        help='also install the Lua addon, for testing a build the Workshop doesn\'t have yet')
    parser.add_argument('--self-test', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.gmod is not None:
        gmod = garrysmod_in(args.gmod)
        if gmod is None:
            print(f"error: no Garry's Mod found in {args.gmod}; pick the garrysmod folder inside GarrysMod", file=sys.stderr)
            return 2
    else:
        gmod = find_gmod()
    if args.game is None:
        window(gmod, args.with_addon)
        return 0
    if gmod is None:
        print('error: Garry\'s Mod not found; pass --gmod <garrysmod folder>', file=sys.stderr)
        return 2
    try:
        install(args.game, gmod, lambda text: print(text, flush=True), args.with_addon)
    except Exception as error:
        traceback.print_exc()
        print(f'error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
