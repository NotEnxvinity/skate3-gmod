"""Real fonts for the setup window on Linux.

The Linux setup runs on python-build-standalone's Python, whose Tk is built
without Xft: it can only draw the X server's own "core" fonts. Those used to
include proper scalable ones, but after a SteamOS/KDE update XWayland only
offers its built-in bitmap fonts, so the window fell back to a pixel font
(and looked broken). Tk can't load font files itself, so this hands the X
server a folder holding the desktop's own TrueType fonts (DejaVu, Noto or
Liberation, whichever is installed) for as long as the window is open; Tk
then lists them like any other font, and the window looks like it used to.

Nothing is installed: the folder is in setup's cache, the X server only reads
it, and the old font path is put back when setup closes.
"""
from pathlib import Path
import atexit, ctypes, ctypes.util, os, shutil, sys

# (family as Tk will list it, regular file, bold file), best first.
SANS = [
    ('dejavu sans', 'DejaVuSans.ttf', 'DejaVuSans-Bold.ttf'),
    ('noto sans', 'NotoSans-Regular.ttf', 'NotoSans-Bold.ttf'),
    ('liberation sans', 'LiberationSans-Regular.ttf', 'LiberationSans-Bold.ttf'),
]
MONO = [
    ('dejavu sans mono', 'DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf'),
    ('noto sans mono', 'NotoSansMono-Regular.ttf', 'NotoSansMono-Bold.ttf'),
    ('liberation mono', 'LiberationMono-Regular.ttf', 'LiberationMono-Bold.ttf'),
]
FONT_DIRS = ['/usr/share/fonts', '/usr/local/share/fonts', '~/.local/share/fonts', '~/.fonts']


def find_files(names, dirs=FONT_DIRS):
    """name -> path for each of `names` found under the font folders."""
    wanted, found = set(names), {}
    for top in dirs:
        top = os.path.expanduser(top)
        if not os.path.isdir(top):
            continue
        for folder, _, files in os.walk(top):
            for name in wanted.intersection(files):
                found.setdefault(name, os.path.join(folder, name))
    return found


def pick(found):
    """The first sans and mono families with both their files: [(family, regular, bold)]."""
    chosen = []
    for choices in (SANS, MONO):
        for family, regular, bold in choices:
            if regular in found and bold in found:
                chosen.append((family, found[regular], found[bold]))
                break
    return chosen


def fonts_dir_text(entries):
    """A fonts.dir the X server reads: one scalable XLFD per file."""
    lines = []
    for family, regular, bold in entries:
        spacing = 'm' if 'mono' in family else 'p'
        for path, weight in ((regular, 'medium'), (bold, 'bold')):
            lines.append(f'{Path(path).name} -s3gm-{family}-{weight}-r-normal--0-0-0-0-{spacing}-0-iso10646-1')
    return f'{len(lines)}\n' + '\n'.join(lines) + '\n'


def make_folder(entries, folder):
    """The folder handed to the X server: the font files (linked, else copied) and fonts.dir."""
    if folder.exists():
        shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    for _, regular, bold in entries:
        for path in (regular, bold):
            link = folder / Path(path).name
            try:
                link.symlink_to(path)
            except OSError:
                shutil.copy2(path, link)
    (folder / 'fonts.dir').write_text(fonts_dir_text(entries), encoding='ascii')
    return folder


_keep = []  # the error handler callback must outlive the call


def add_font_path(folder):
    """Append `folder` to the X server's font path; puts the old path back at
    exit. False when there is no X display or the server refused it."""
    if not os.environ.get('DISPLAY'):
        return False
    name = ctypes.util.find_library('X11') or 'libX11.so.6'
    try:
        x = ctypes.CDLL(name)
    except OSError:
        return False
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XGetFontPath.restype = ctypes.POINTER(ctypes.c_char_p)
    x.XGetFontPath.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    x.XFreeFontPath.argtypes = [ctypes.POINTER(ctypes.c_char_p)]
    x.XSetFontPath.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
    x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    handler_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
    x.XSetErrorHandler.restype = ctypes.c_void_p
    x.XSetErrorHandler.argtypes = [handler_type]
    errors = []
    # Xlib's own handler ends the process on an error; ours just notes it.
    handler = handler_type(lambda display, event: errors.append(1) or 0)
    _keep.append(handler)
    display = x.XOpenDisplay(None)
    if not display:
        return False
    old_handler = x.XSetErrorHandler(handler)
    count = ctypes.c_int()
    listed = x.XGetFontPath(display, ctypes.byref(count))
    old = [listed[i] for i in range(count.value)] if listed else []
    if listed:
        x.XFreeFontPath(listed)
    entry = str(folder).rstrip('/').encode() + b'/'
    if entry in old:
        x.XSetErrorHandler(old_handler)
        x.XCloseDisplay(display)
        return True

    def set_path(path):
        array = (ctypes.c_char_p * len(path))(*path)
        x.XSetFontPath(display, array, len(path))
        x.XSync(display, 0)

    set_path(old + [entry])
    if errors:
        errors.clear()
        set_path(old)
        x.XSetErrorHandler(old_handler)
        x.XCloseDisplay(display)
        return False

    def restore():
        try:
            set_path(old)
            x.XCloseDisplay(display)
        except Exception:
            pass
    atexit.register(restore)
    x.XSetErrorHandler(old_handler)
    return True


def install(cache=None):
    """Give the X server the desktop's TrueType fonts, before Tk starts.
    Returns the families now offered (sans first), or [] if nothing changed."""
    if not sys.platform.startswith('linux') or not os.environ.get('DISPLAY'):
        return []
    try:
        names = [n for family in SANS + MONO for n in family[1:]]
        entries = pick(find_files(names))
        if not entries:
            return []
        base = Path(cache or os.environ.get('XDG_CACHE_HOME') or Path.home() / '.cache') / 'skate3-gmod'
        folder = make_folder(entries, base / 'xfonts')
        return [family for family, _, _ in entries] if add_font_path(folder) else []
    except Exception:
        return []
