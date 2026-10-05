"""Skate 3 for Garry's Mod setup: pick your own Skate 3 (Xbox 360) disc image
or extracted game, and this finds Garry's Mod, installs the skate module into
garrysmod/lua/bin and converts the game data the mod needs into
garrysmod/data/skate3. Run it once, and again after an update.

Nothing from the game is downloaded or bundled: everything comes off the disc
you pick, on your own machine.

    skate3-gmod-setup                    the setup window
    skate3-gmod-setup --game <iso|xex>   the same without a window
          [--gmod <garrysmod folder>]
"""
from pathlib import Path
import argparse, os, queue, re, runpy, shutil, sys, tempfile, threading, traceback

FROZEN = getattr(sys, 'frozen', False)
# The packaged app carries the engine's converters and the modules here.
ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

import convert, xdvdfs  # noqa: E402

MODULES = ('gmcl_skate3_win64.dll', 'gmcl_skate3_linux64.dll')
# What the converters read off the disc, so an ISO needs only these copied out.
FROM_DISC = {
    'default.xex',
    'data/big/miscload.big',
    'data/big/miscboot.big',
    'data/big/db.big',
    'data/content/createacharacter.big',
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


def steam_roots():
    roots = []
    if os.name == 'nt':
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam') as key:
                roots.append(Path(winreg.QueryValueEx(key, 'SteamPath')[0]))
        except OSError:
            pass
        roots += [Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Steam']
    else:
        home = Path.home()
        roots += [home / '.local/share/Steam', home / '.steam/steam', home / '.steam/root',
                  home / '.var/app/com.valvesoftware.Steam/.local/share/Steam']
    return [r for r in roots if r.is_dir()]


def libraries(root):
    found = [root]
    vdf = root / 'steamapps/libraryfolders.vdf'
    if vdf.is_file():
        text = vdf.read_text(encoding='utf-8', errors='replace')
        found += [Path(p.replace('\\\\', '\\')) for p in re.findall(r'"path"\s+"([^"]+)"', text)]
    return found


def find_gmod():
    """The garrysmod folder of the first Garry's Mod install found, or None."""
    for root in steam_roots():
        for library in libraries(root):
            folder = library / 'steamapps/common/GarrysMod/garrysmod'
            if folder.is_dir():
                return folder
    return None


def module_dir():
    """Where the skate modules come from: inside the app, or beside setup in
    the CI download (skate3-gmod/garrysmod/lua/bin)."""
    for folder in (ROOT / 'bin', HERE.parent / 'garrysmod/lua/bin'):
        if all((folder / m).is_file() for m in MODULES):
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
    raise RuntimeError('The Skate 3 engine converters are missing from this setup.')


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


def install(selected, gmod, report):
    gmod = Path(gmod)
    if not (gmod / 'gameinfo.txt').is_file() and not (gmod / 'lua').is_dir():
        raise RuntimeError(f"{gmod} doesn't look like a garrysmod folder.")
    modules = module_dir()
    if modules is None:
        raise RuntimeError('The skate modules are missing from this setup.')
    bin_dir = gmod / 'lua/bin'
    bin_dir.mkdir(parents=True, exist_ok=True)
    for m in MODULES:
        shutil.copy2(modules / m, bin_dir / m)
    report(f'Installed the skate module in {bin_dir}')

    data = gmod / 'data/skate3'
    data.parent.mkdir(parents=True, exist_ok=True)
    # Beside the output, so a disc image's files land on the same drive.
    with tempfile.TemporaryDirectory(prefix='skate3-setup-', dir=data.parent) as work:
        xex = game_folder(selected, Path(work), report)
        convert.convert(engine_dir(), xex, data, report)
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
    print(f'self-test ok: {len(converter_modules(engine))} converter modules')


def window(gmod):
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
    root = tk.Tk()
    root.title('Skate 3 for Garry\'s Mod setup')
    root.geometry('720x520')
    root.minsize(560, 420)
    frame = ttk.Frame(root, padding=20)
    frame.pack(fill='both', expand=True)
    ttk.Label(frame, text='Skate 3 for Garry\'s Mod', font=('TkDefaultFont', 18, 'bold')).pack(anchor='w')
    ttk.Label(frame, justify='left', wraplength=620, text=(
        'Pick your own Skate 3 (Xbox 360) disc image (.iso), or default.xex in an extracted copy. '
        'Setup installs the skate module and converts what the mod needs from your disc. '
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

        def work():
            try:
                install(picked, target.get(), lambda text: messages.put(('log', text)))
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
    parser = argparse.ArgumentParser(description='Skate 3 for Garry\'s Mod setup')
    parser.add_argument('--game', type=Path, help='your Skate 3 disc image (.iso) or extracted default.xex')
    parser.add_argument('--gmod', type=Path, help='the garrysmod folder (found automatically if left out)')
    parser.add_argument('--self-test', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    gmod = args.gmod or find_gmod()
    if args.game is None:
        window(gmod)
        return 0
    if gmod is None:
        print('error: Garry\'s Mod not found; pass --gmod <garrysmod folder>', file=sys.stderr)
        return 2
    try:
        install(args.game, gmod, lambda text: print(text, flush=True))
    except Exception as error:
        traceback.print_exc()
        print(f'error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
