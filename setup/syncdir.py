"""Copy only what changed. A setup run that deletes a folder and writes it
again hands Garry's Mod thousands of brand new files, and the first launch
after it sits on the loading screen indexing them. sync_tree leaves a file
alone when its bytes already match, so a rerun with the same data touches
nothing."""
from pathlib import Path
import os, shutil

CHUNK = 1 << 20


def same_bytes(a, b):
    """True when both files hold the same bytes."""
    a, b = Path(a), Path(b)
    try:
        if a.stat().st_size != b.stat().st_size:
            return False
        with a.open('rb') as fa, b.open('rb') as fb:
            while True:
                block = fa.read(CHUNK)
                if block != fb.read(len(block)):
                    return False
                if not block:
                    return True
    except OSError:
        return False


def write_if_changed(path, data):
    """Writes `data` (bytes) to path unless it already holds exactly that.
    Returns True when it wrote."""
    path = Path(path)
    try:
        if path.is_file() and path.stat().st_size == len(data) and path.read_bytes() == data:
            return False
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return True


def sync_tree(src, dst, move=False):
    """Makes folder `dst` hold exactly what `src` holds, writing only files
    that are new or different and deleting what `src` lacks. Returns
    (written, kept, removed) file counts.

    With move=True, `src` is a scratch folder the caller throws away: when
    `dst` doesn't exist yet it is simply renamed into place (no copying)."""
    src, dst = Path(src), Path(dst)
    count = sum(1 for p in src.rglob('*') if p.is_file())
    if move and not dst.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.replace(src, dst)
            return count, 0, 0
        except OSError:
            pass  # another drive: copy instead
    if dst.exists() and not dst.is_dir():
        dst.unlink()
    dst.mkdir(parents=True, exist_ok=True)
    files, folders = set(), set()
    written = kept = 0
    for path in sorted(src.rglob('*')):
        rel = path.relative_to(src)
        target = dst / rel
        if path.is_dir():
            folders.add(rel)
            if target.exists() and not target.is_dir():
                target.unlink()
            target.mkdir(parents=True, exist_ok=True)
            continue
        files.add(rel)
        if target.is_dir():
            shutil.rmtree(target)
        if target.is_file() and same_bytes(path, target):
            kept += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        written += 1
    removed = 0
    # Deepest first, so a folder is empty by the time it is looked at.
    for path in sorted(dst.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        rel = path.relative_to(dst)
        if path.is_dir() and not path.is_symlink():
            if rel not in folders:
                shutil.rmtree(path, ignore_errors=True)
        elif rel not in files:
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass
    return written, kept, removed
