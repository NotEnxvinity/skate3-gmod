"""The audio decoder and the executable reader, for setup.

They live in the skate module every download already carries (gmcl_skate3_*,
exported as plain C functions: native/gmod-skate/src/tools.rs), so setup loads
the module for its own platform and calls them. Stand-alone programs built
from the same code (skate-xma, skate-xex) work too, when given or found."""
import ctypes, os, platform, shutil, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Why the last module wouldn't load, for the message setup shows.
LOAD_ERROR = ''
# An Apple-silicon Mac runs Garry's Mod, and so the skate module, as Intel code
# under Rosetta, but setup's Python is native and can't load Intel code: it
# loads this small arm64 build of just the decoder instead.
ARM_TOOLS = 's3gm_tools_osx_arm64.dylib'


def native_mac_python():
    return sys.platform == 'darwin' and platform.machine() == 'arm64'


def module_name():
    if native_mac_python():
        return ARM_TOOLS
    if os.name == 'nt':
        return 'gmcl_skate3_win64.dll'
    return 'gmcl_skate3_osx64.dll' if sys.platform == 'darwin' else 'gmcl_skate3_linux64.dll'


def find_module(given=None):
    """This computer's skate module: bundled in the app, beside setup in the
    download, from SKATE3_MODULE, or a cargo build."""
    root = Path(getattr(sys, '_MEIPASS', HERE))
    lib = {'nt': 'gmcl_skate3.dll', 'darwin': 'libgmcl_skate3.dylib'}.get(
        os.name if os.name == 'nt' else sys.platform, 'libgmcl_skate3.so')
    candidates = [given, os.environ.get('SKATE3_MODULE'), root / 'bin' / module_name(),
                  HERE.parent / 'garrysmod/lua/bin' / module_name(), HERE.parent / 'target/release' / lib]
    if os.environ.get('CARGO_TARGET_DIR'):
        candidates.append(Path(os.environ['CARGO_TARGET_DIR']) / 'release' / lib)
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    return None


def find_program(name, given=None, env=None):
    exe = name + ('.exe' if os.name == 'nt' else '')
    root = Path(getattr(sys, '_MEIPASS', HERE))
    candidates = [given, os.environ.get(env) if env else None, root / 'bin' / exe,
                  HERE.parent / 'target/release' / exe]
    if os.environ.get('CARGO_TARGET_DIR'):
        candidates.append(Path(os.environ['CARGO_TARGET_DIR']) / 'release' / exe)
    candidates.append(shutil.which(name))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            path = Path(candidate)
            if os.name != 'nt' and not os.access(path, os.X_OK):
                path.chmod(0o755)
            return path
    return None


def _run(command):
    flags = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    return subprocess.run([str(c) for c in command], capture_output=True, text=True, **flags)


class Programs:
    """skate-xma and skate-xex as programs."""

    def __init__(self, xma=None, xex=None):
        self.xma, self.xex = xma, xex
        self.path = xma or xex

    def jobs(self, bank, jobs, outdir):
        r = _run([self.xma, '--continuous', bank, jobs, outdir])
        return r.returncode, r.stderr.strip() or r.stdout.strip()

    def snr(self, stream, offset, out):
        r = _run([self.xma, '--snr', stream, offset, out])
        return r.returncode, r.stderr.strip() or r.stdout.strip()

    def xex_image(self, xex, out):
        if self.xex is None:
            return 1, 'skate-xex is missing'
        r = _run([self.xex, xex, out])
        return r.returncode, r.stderr.strip() or r.stdout.strip()


class Module:
    """The decoder and reader inside the skate module."""

    def __init__(self, path):
        self.path = Path(path)
        self.lib = ctypes.CDLL(str(self.path))
        for name in ('s3gm_xma_jobs', 's3gm_xma_snr', 's3gm_xex_image', 's3gm_last_error'):
            getattr(self.lib, name)
        self.lib.s3gm_xma_snr.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.c_char_p]
        self.lib.s3gm_last_error.restype = ctypes.c_size_t
        self.lib.s3gm_last_error.argtypes = [ctypes.c_char_p, ctypes.c_size_t]

    def _message(self):
        buffer = ctypes.create_string_buffer(4096)
        n = self.lib.s3gm_last_error(buffer, len(buffer))
        return buffer.raw[:n].decode('utf-8', 'replace')

    def _call(self, function, *args):
        code = function(*[a if isinstance(a, int) else os.fsencode(str(a)) for a in args])
        return code, self._message()

    def jobs(self, bank, jobs, outdir):
        return self._call(self.lib.s3gm_xma_jobs, bank, jobs, outdir)

    def snr(self, stream, offset, out):
        return self._call(self.lib.s3gm_xma_snr, stream, int(offset), out)

    def xex_image(self, xex, out):
        return self._call(self.lib.s3gm_xex_image, xex, out)


def _open(path):
    global LOAD_ERROR
    try:
        return Module(path)
    except (OSError, AttributeError) as error:
        # A module from before the tools were put in it, or one that won't load.
        LOAD_ERROR = f'{Path(path).name} would not load: {error}'
        return None


def load(xma=None, xex=None, module=None):
    """Whatever can decode on this computer, the given or found programs first,
    then the module. None when nothing can."""
    program = find_program('skate-xma', xma, 'SKATE3_XMA')
    if program is not None:
        return Programs(program, find_program('skate-xex', xex, 'SKATE3_XEX'))
    path = find_module(module)
    if path is None:
        return None
    return _open(path)


def xex_reader(xex=None, module=None):
    """Whatever can read the disc's default.xex: skate-xex, else the module."""
    program = find_program('skate-xex', xex, 'SKATE3_XEX')
    if program is not None:
        return Programs(None, program)
    path = find_module(module)
    if path is None:
        return None
    return _open(path)
