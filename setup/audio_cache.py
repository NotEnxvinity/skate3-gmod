"""The player's Skate 3 audio, unpacked and decoded for the native audio engine
(the port of retail's AEMS runtime), in garrysmod/data/skate3/audio-cache:

  raw/<archive>/   the EB archives' files byte for byte (.csi symbol files, .abk
                   and .bnk banks, .grain and .snr streams)
  pcm/<archive>/   every bank sample and stream decoded once, as big-endian
                   PCM16 (<bank>_<index>.xma16, <name>.xma16)
  MixMapSK8.mxb    the mix map
  grain-tuning.bin, component-tuning.bin   from audio_blobs.py
  manifest.json    what was read and made, so a rerun can tell it is current

It is the player's own game audio, decoded on their machine and never shipped.
The layout and the decoding steps follow SK8V's tools/prepare-skate-audio.py
(https://github.com/becaring/SK8V, Apache-2.0); the decoder is native/skate-xma
(LGPL-2.1-or-later, from the same project). The gameplay sounds in
garrysmod/sound/skate3 (audio.py) stay as they are: the mod plays them when
this cache isn't there.

    python audio_cache.py --game <extracted game folder> --out <audio-cache>
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, struct, subprocess, sys, tempfile

from audio import ARCHIVES, MIX_MAP, Big
import audio_blobs
import native_tools

FORMAT = 'skatev-audio-cache'
VERSION = 2  # 2: splice (.bnk) bank samples are decoded too
GRAIN_TUNING = 'grain-tuning.bin'
COMPONENT_TUNING = 'component-tuning.bin'
HERE = Path(__file__).resolve().parent
NOTE = "User's own Skate 3 audio, decoded locally. Do not redistribute."


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def job(name, offset, h1, h2):
    """One decoder job line (NAME DATA_OFFSET SAMPLES CHANNELS RATE) from an
    SNR header's two words."""
    looped = (h2 >> 29) & 1
    return f'{name} {offset + (12 if looped else 8)} {h2 & 0x1FFFFFFF} {((h1 >> 18) & 0x3F) + 1} {h1 & 0x3FFFF}\n'


def abk_jobs(abk, stem):
    """One decoder job per sample of an AEMS bank, by the table index the game
    uses."""
    if len(abk) < 36:
        return []
    table = struct.unpack_from('>I', abk, 32)[0]
    out, i = [], 0
    while table and table + 4 * (3 + i) + 4 <= len(abk):
        offset = table + struct.unpack_from('>I', abk, table + 4 * (3 + i))[0]
        if offset + 12 > len(abk):
            break
        h1, h2 = struct.unpack_from('>2I', abk, offset)
        if (h1 >> 24) & 0xF != 3 or h1 >> 28 != 0:
            break
        out.append(job(f'{stem}_{i}', offset, h1, h2))
        i += 1
    return out


def bnk_jobs(bnk, stem):
    """The samples of a splice (SPLC) bank, by sample-table index: the table
    follows the sound data at align4(0x3C + size), and each entry's first word
    is the SNR header's offset from the sample data's base."""
    if bnk[:4] != b'SPLC' or len(bnk) < 0x3C:
        return []
    size, _sounds, _groups, _extra, count = struct.unpack_from('>5I', bnk, 8)
    table = (0x3C + size + 3) & ~3
    base = (table + 12 * count + 3) & ~3
    out = []
    for i in range(count):
        if table + 12 * i + 12 > len(bnk):
            break
        offset = base + struct.unpack_from('>I', bnk, table + 12 * i)[0]
        if offset + 12 > len(bnk):
            break
        h1, h2 = struct.unpack_from('>2I', bnk, offset)
        if (h1 >> 24) & 0xF != 3 or h1 >> 28 != 0:
            continue
        out.append(job(f'{stem}_{i}', offset, h1, h2))
    return out


def unpack(archive, dest):
    """Writes every file of the EB archive into `dest`; returns [(name, size)]."""
    dest.mkdir(parents=True, exist_ok=True)
    made = []
    with Big(archive) as big:
        for name in big.files:
            target = (dest / name).resolve()
            if not target.is_relative_to(dest.resolve()):
                raise ValueError(f'{Path(archive).name}: unsafe archive member {name}')
            target.parent.mkdir(parents=True, exist_ok=True)
            blob = big.read(name)
            target.write_bytes(blob)
            made.append((name, len(blob)))
    return made


def decode_banks(banks, jobs_for, tools, out_dir, scratch, problems):
    """Decodes every bank's samples into out_dir; returns how many."""
    out_dir.mkdir(parents=True, exist_ok=True)
    samples = 0
    for bank in banks:
        # Four-channel (two-stream) samples are not played.
        jobs = [j for j in jobs_for(bank.read_bytes(), bank.stem) if int(j.split()[3]) <= 2]
        if not jobs:
            continue
        scratch.write_text(''.join(jobs))
        code, why = tools.jobs(bank, scratch, out_dir)
        if code != 0:
            problems.append(f'{bank.name}: decoder exit {code}: {why[-200:]}')
            continue
        for line in jobs:
            name = line.split()[0]
            if (out_dir / f'{name}.xma16').is_file():
                samples += 1
            else:
                problems.append(f'{name}: not decoded')
    scratch.unlink(missing_ok=True)
    return samples


def decode_streams(raw, pcm, tools, problems):
    """The standalone SNR streams: the rolling grains (the stream starts at
    the u32 stored at byte 0) and the wheel spins."""
    streams = 0
    for archive, pattern in (('grains', '*.grain'), ('wheels', '*.snr')):
        out = pcm / archive
        out.mkdir(parents=True, exist_ok=True)
        for path in sorted((raw / archive).glob(pattern)):
            offset = struct.unpack_from('>I', path.read_bytes(), 0)[0] if path.suffix == '.grain' else 0
            code, why = tools.snr(path, offset, out / f'{path.stem}.xma16')
            if code != 0:
                problems.append(f'{archive}/{path.name}: decoder exit {code}: {why[-200:]}')
            else:
                streams += 1
    return streams


def find_file(folder, name):
    """`name` in `folder`, whatever case the disc spelled it in."""
    exact = Path(folder) / name
    if exact.is_file():
        return exact
    for path in Path(folder).iterdir():
        if path.name.lower() == name.lower() and path.is_file():
            return path
    return exact


def audio_folder(game):
    for folder in (Path(game) / 'data' / 'audio', Path(game) / 'audio'):
        if (folder / ARCHIVES[0]).is_file():
            return folder
    return None


def sizes(root):
    return {p.relative_to(root).as_posix(): p.stat().st_size for tree in ('raw', 'pcm') for p in sorted((root / tree).rglob('*')) if p.is_file()}


def current(manifest, inputs, decoder_hash, root):
    """Reuse only when the discs' files, the decoder and every output (by size)
    are what the last run made."""
    if not (isinstance(manifest, dict) and manifest.get('format') == FORMAT and manifest.get('version') == VERSION
            and manifest.get('inputs') == inputs and manifest.get('decoder_sha256') == decoder_hash
            and manifest.get('complete') and isinstance(manifest.get('outputs'), dict)):
        return False
    for name, size in manifest['outputs'].items():
        path = (root / name).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file() or path.stat().st_size != size:
            return False
    return (root / MIX_MAP).is_file()


def build(game, out, report=print, decoder=None, force=False):
    """Unpacks and decodes the disc's gameplay audio into `out`. Returns the
    manifest. Raises RuntimeError when the disc or the decoder is missing."""
    out = Path(out)
    audio = audio_folder(game)
    if audio is None:
        raise RuntimeError(f'{game} has no data/audio/audiofiles.big')
    tools = native_tools.load(decoder)
    if tools is None:
        raise RuntimeError(native_tools.LOAD_ERROR or 'the audio decoder is missing from this setup (it lives in '
                           + native_tools.module_name() + ' in the bin folder beside setup)')
    sources = {}
    inputs = {}
    for name in (*ARCHIVES, MIX_MAP):
        path = find_file(audio, name)
        if not path.is_file():
            raise RuntimeError(f'{name} is missing from the disc\'s audio folder ({audio})')
        sources[name] = path
        inputs[name] = {'bytes': path.stat().st_size, 'sha256': digest(path)}
    decoder_hash = digest(tools.path)
    manifest_path = out / 'manifest.json'
    if manifest_path.is_file() and not force:
        try:
            old = json.loads(manifest_path.read_text())
        except (ValueError, OSError):
            old = None
        if current(old, inputs, decoder_hash, out):
            report(f'The audio cache is current ({old.get("samples")} samples)')
            return old
    # Start clean: a half-done earlier run must not leave stale samples behind.
    for tree in ('raw', 'pcm'):
        shutil.rmtree(out / tree, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)
    counts, members = {}, {}
    for name in ARCHIVES:
        made = unpack(sources[name], out / 'raw' / Path(name).stem)
        counts[name] = len(made)
        members[name] = hashlib.sha256(''.join(f'{n}:{s};' for n, s in made).encode()).hexdigest()
        report(f'Unpacked {name}: {len(made)} files')
    problems = []
    scratch = out / 'jobs.txt'
    banks = out / 'raw' / 'audiofiles'
    pcm = out / 'pcm'
    report('Decoding the banks')
    samples = decode_banks(sorted(banks.glob('*.abk')), abk_jobs, tools, pcm / 'audiofiles', scratch, problems)
    samples += decode_banks(sorted(banks.glob('*.bnk')), bnk_jobs, tools, pcm / 'audiofiles', scratch, problems)
    report('Decoding the rolling and wheel recordings')
    streams = decode_streams(out / 'raw', pcm, tools, problems)
    shutil.copyfile(sources[MIX_MAP], out / MIX_MAP)
    if digest(out / MIX_MAP) != inputs[MIX_MAP]['sha256']:
        raise RuntimeError('the mix map changed while the cache was made')
    report(f'Decoded {samples} bank samples and {streams} streams; {len(problems)} problems')
    for line in problems[:10]:
        report('  ' + line)
    manifest = {
        'format': FORMAT, 'version': VERSION,
        'decoder_sha256': decoder_hash,
        'inputs': inputs, 'archives': counts, 'archive_members_sha256': members,
        'outputs': sizes(out),
        'samples': samples, 'streams': streams,
        'problems': problems, 'complete': not problems,
        'note': NOTE,
    }
    manifest_path.write_text(json.dumps(manifest, indent=1))
    return manifest


def tuning(game, collections, out, report=print, xex_tool=None):
    """Writes grain-tuning.bin (and, with the disc's default.xex, component-
    tuning.bin) beside the cache. Returns the names of the files written."""
    out = Path(out)
    document = json.loads(Path(collections).read_text(encoding='utf-8'))
    out.mkdir(parents=True, exist_ok=True)
    written = []
    grains = audio_blobs.encode_grains(document)
    (out / GRAIN_TUNING).write_bytes(grains)
    written.append(GRAIN_TUNING)
    xex = Path(game) / 'default.xex'
    if not xex.is_file():
        report('No default.xex next to the audio: the component tuning needs it.')
        return written
    image, image_hash = audio_blobs.image_from_xex(xex, xex_tool)
    components = audio_blobs.encode_components(document, image)
    (out / COMPONENT_TUNING).write_bytes(components)
    written.append(COMPONENT_TUNING)
    (out / 'tuning.json').write_text(json.dumps({
        'collections_sha256': audio_blobs.sha256(Path(collections).read_bytes()),
        'xex_sha256': audio_blobs.sha256_file(xex), 'image_sha256': image_hash,
        'grain_sha256': audio_blobs.sha256(grains), 'component_sha256': audio_blobs.sha256(components),
        'note': NOTE}, indent=1))
    return written


def install(game, out, collections, report=print):
    """The whole cache: audio, then tuning. Returns True when the engine has
    everything it reads."""
    manifest = build(game, out, report)
    files = tuning(game, collections, out, report)
    return bool(manifest.get('complete')) and COMPONENT_TUNING in files


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--game', type=Path, required=True, help='extracted Skate 3 folder (holding default.xex and data/)')
    parser.add_argument('--out', type=Path, required=True, help='garrysmod/data/skate3/audio-cache')
    parser.add_argument('--collections', type=Path, help='skater-collections.json, for the tuning files')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    manifest = build(args.game, args.out, force=args.force)
    if args.collections:
        tuning(args.game, args.collections, args.out)
    return 0 if manifest.get('complete') else 1


if __name__ == '__main__':
    sys.exit(main())
