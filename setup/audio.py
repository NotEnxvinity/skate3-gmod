"""Turns the skate sounds on the player's own Skate 3 disc into WAV files
Garry's Mod can play, in garrysmod/sound/skate3.

Skate 3 keeps its audio in EA "EB" archives (data/audio/*.big). The sounds
inside are EA SNR streams (Xbox XMA), packed into banks; this cuts each one
out of its bank and has vgmstream decode it. Source plays 44.1 and 22.05 kHz
WAVs, so other rates are resampled here, and looping sounds get the cue point
Source loops from.

    python audio.py --game <extracted game folder> --out <garrysmod/sound/skate3>
"""
from pathlib import Path
from fractions import Fraction
import argparse, os, shutil, struct, subprocess, sys, tempfile, wave

ARCHIVES = ('audiofiles.big', 'grains.big', 'wheels.big')
FROM_DISC = tuple('data/audio/' + name for name in ARCHIVES)

# Output folder: (archive, file in it). Loop folders get a loop cue point.
BANKS = {
    'collisions': ('audiofiles.big', 'Skate_Collisions.bnk'),
    'metal': ('audiofiles.big', 'Skate_Metal.bnk'),
    'foley': ('audiofiles.big', 'sk8_foley.bnk'),
    'whooshes': ('audiofiles.big', 'Sk82_Whsh_Bys.bnk'),
    'grinds': ('audiofiles.big', 'GRINDS.abk'),
    'flips': ('audiofiles.big', 'Sk8_Air_Flip_Tricks.abk'),
    'scrapes': ('audiofiles.big', 'board_scrapes.abk'),
    'bodyslide': ('audiofiles.big', 'Bodyslide.abk'),
    'footdrag': ('audiofiles.big', 'FOOT_DRAG.abk'),
    'seams': ('audiofiles.big', 'Seams_Bank.abk'),
    'rattles': ('audiofiles.big', 'Rolling_Rattles.abk'),
    'skids': ('audiofiles.big', 'WHEEL_SKID_BANK.abk'),
    'surfaces': ('audiofiles.big', 'PatchBank_Rolling_Surfaces.abk'),
    'squeaks': ('audiofiles.big', 'Brd_Squeaks.abk'),
    'footsteps': ('audiofiles.big', 'fstep_skateshoe1_sm.abk'),
    'wind': ('audiofiles.big', 'sense_of_speed.abk'),
    'spins': ('wheels.big', '.snr'),
    'roll': ('grains.big', '.grain'),
}
LOOPS = {'roll', 'spins'}
RATES = {48000, 44100, 32000, 24000, 22050, 16000, 11025}
SOURCE_RATES = {44100, 22050}


class Big:
    """An EA "EB" v3 archive, big-endian: a 0x30-byte header, then 16 bytes
    per file (offset >> shift, 0, size, name hash), then a table of
    fixed-size name slots in the same order (two bytes, then the name)."""

    def __init__(self, path):
        self.file = open(path, 'rb')
        head = self.file.read(0x30)
        if head[:2] != b'EB' or len(head) < 0x30:
            self.file.close()
            raise RuntimeError(f'{Path(path).name} is not a Skate 3 audio archive')
        count, = struct.unpack_from('>I', head, 4)
        shift, slot = head[0x0A], head[0x14]
        names_at, = struct.unpack_from('>I', head, 0x0C)
        size = os.fstat(self.file.fileno()).st_size
        self.file.seek(0x30)
        table = self.file.read(16 * count)
        self.file.seek(names_at)
        names = self.file.read(slot * count)
        self.files = {}
        for i in range(count):
            offset, _, length, _ = struct.unpack_from('>IIII', table, 16 * i)
            offset <<= shift
            name = names[slot * i + 2:slot * (i + 1)].split(b'\0')[0].decode('latin-1')
            if offset + length > size:
                raise RuntimeError(f'{Path(path).name} is damaged: {name} runs past its end')
            self.files[name] = (offset, length)

    def read(self, name):
        offset, length = self.files[name]
        self.file.seek(offset)
        return self.file.read(length)

    def close(self):
        self.file.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def carve(data):
    """Every in-memory EA SNR sound in `data`: an 8-byte header (codec,
    channels, rate; type, loop flag, sample count), an optional loop start,
    then one data block whose own header agrees with it. Returns the bytes of
    each, header and block together, which vgmstream reads as a .snr.

    Banks pack sounds at any byte offset, so candidates come from searching
    for the sample rate's bytes rather than stepping through the data."""
    candidates = set()
    for rate in RATES:
        low = (rate & 0xFFFF).to_bytes(2, 'big')
        at = data.find(low, 2)
        while at != -1:
            candidates.add(at - 2)
            at = data.find(low, at + 1)
    found, end = [], 0
    for at in sorted(candidates):
        if at < end or at + 16 > len(data):
            continue
        clip = sound_at(data, at)
        if clip:
            found.append(data[at:clip])
            end = clip
    return found


def sound_at(data, at):
    """Where the SNR sound starting at `at` ends, or None if it isn't one."""
    h1, h2 = struct.unpack_from('>II', data, at)
    codec, channels, rate = h1 >> 24, (h1 >> 18) & 0x3F, h1 & 0x3FFFF
    kind, loop, samples = h2 >> 30, (h2 >> 29) & 1, h2 & 0x1FFFFFFF
    if kind != 0 or codec not in (2, 3, 4, 5, 6, 7) or channels >= 8 or rate not in RATES or not 0 < samples < rate * 600:
        return None
    block = at + 8 + 4 * loop
    if block + 8 > len(data):
        return None
    block_id, block_size = data[block], int.from_bytes(data[block + 1:block + 4], 'big')
    block_samples, = struct.unpack_from('>I', data, block + 4)
    end = block + block_size
    if block_id not in (0, 0x80) or block_size <= 8 or end > len(data) or not 0 < block_samples <= samples:
        return None
    # A sound looping from partway through has a second block.
    if loop and block_samples < samples and end + 8 <= len(data) and data[end] in (0, 0x80):
        end += int.from_bytes(data[end + 1:end + 4], 'big')
    return end if end <= len(data) else None


def kaiser_table(ratio, taps=48, beta=8.0):
    """Windowed-sinc filters for each output phase of an up/down resample by
    `ratio` (out rate / in rate), low-passed below the lower Nyquist."""
    import numpy as np
    cutoff = min(1.0, float(ratio)) * 0.94
    phases = ratio.numerator
    offsets = np.arange(taps) - taps // 2 + 1
    table = np.empty((phases, taps), dtype=np.float32)
    for p in range(phases):
        frac = (p * ratio.denominator % phases) / phases
        x = offsets - frac
        h = cutoff * np.sinc(cutoff * x) * np.kaiser(taps, beta)
        table[p] = h / h.sum()
    return table, offsets


def resample(samples, rate, target):
    """Mono or interleaved int16 samples from `rate` to `target`."""
    import numpy as np
    if rate == target:
        return samples
    ratio = Fraction(target, rate)
    table, offsets = kaiser_table(ratio)
    channels = samples.shape[1]
    count = len(samples) * ratio.numerator // ratio.denominator
    padded = np.pad(samples.astype(np.float32), ((len(offsets), len(offsets)), (0, 0)))
    out = np.empty((count, channels), dtype=np.float32)
    for start in range(0, count, 65536):
        n = np.arange(start, min(start + 65536, count))
        position = n * ratio.denominator
        base = position // ratio.numerator
        phase = n % ratio.numerator
        index = base[:, None] + offsets[None, :] + len(offsets)
        for c in range(channels):
            out[n, c] = (padded[index, c] * table[phase]).sum(axis=1)
    return np.clip(np.round(out), -32768, 32767).astype(np.int16)


def write_wav(path, samples, rate, loop):
    """A 16-bit PCM WAV; `loop` adds the cue point Source loops from."""
    channels = samples.shape[1]
    pcm = samples.tobytes()
    chunks = [b'fmt ' + struct.pack('<IHHIIHH', 16, 1, channels, rate, rate * channels * 2, channels * 2, 16)]
    if loop:
        chunks.append(b'cue ' + struct.pack('<II', 28, 1) + struct.pack('<II4sIII', 0, 0, b'data', 0, 0, 0))
    chunks.append(b'data' + struct.pack('<I', len(pcm)) + pcm + b'\0' * (len(pcm) & 1))
    body = b'WAVE' + b''.join(chunks)
    Path(path).write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)


def read_wav(path):
    import numpy as np
    with wave.open(str(path)) as w:
        if w.getsampwidth() != 2:
            raise RuntimeError(f'{path.name}: expected 16-bit audio from vgmstream')
        frames = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2')
        return frames.reshape(-1, w.getnchannels()), w.getframerate()


def find_vgmstream():
    """vgmstream-cli: bundled in the app, from SKATE3_VGMSTREAM, or on PATH."""
    name = 'vgmstream-cli.exe' if os.name == 'nt' else 'vgmstream-cli'
    root = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
    for candidate in (root / 'vgmstream' / name, os.environ.get('SKATE3_VGMSTREAM'), shutil.which('vgmstream-cli')):
        if candidate and Path(candidate).is_file():
            path = Path(candidate)
            if os.name != 'nt' and not os.access(path, os.X_OK):
                path.chmod(0o755)
            return path
    return None


def decode(vgmstream, inputs, report):
    """Runs vgmstream over the .snr files, writing <name>.wav beside each."""
    flags = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
    for start in range(0, len(inputs), 64):
        batch = inputs[start:start + 64]
        result = subprocess.run([str(vgmstream), '-i', '-o', '?f.wav', *map(str, batch)],
                                capture_output=True, text=True, **flags)
        if result.returncode != 0 and not any(Path(f'{p}.wav').is_file() for p in batch):
            raise RuntimeError('vgmstream could not decode the sounds: ' + (result.stderr or result.stdout).strip()[-400:])
        report(f'Decoded {min(start + 64, len(inputs))} of {len(inputs)} sounds')


def sounds(game, report):
    """(folder, name, snr bytes) for every sound setup installs."""
    audio = Path(game) / 'data/audio'
    missing = [name for name in ARCHIVES if not (audio / name).is_file()]
    if missing:
        raise RuntimeError(f'the disc\'s data/audio folder is missing {", ".join(missing)}')
    archives = {name: Big(audio / name) for name in ARCHIVES}
    try:
        for folder, (archive, entry) in BANKS.items():
            big = archives[archive]
            if entry.startswith('.'):
                for name in sorted(big.files):
                    if name.endswith(entry):
                        for clip in carve(big.read(name))[:1]:
                            yield folder, Path(name).stem.lower(), clip
            elif entry in big.files:
                for i, clip in enumerate(carve(big.read(entry))):
                    yield folder, f'{i:03d}', clip
            else:
                report(f'Skipping {entry}: not on this disc')
    finally:
        for big in archives.values():
            big.close()


def install(game, out, report=print):
    """Writes the skate sounds from the extracted `game` folder into `out`
    (garrysmod/sound/skate3), replacing what an earlier setup put there.
    Returns how many sounds were installed."""
    vgmstream = find_vgmstream()
    if vgmstream is None:
        raise RuntimeError('vgmstream-cli is missing from this setup')
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='skate3-audio-', dir=out.parent) as work:
        work = Path(work)
        report('Reading the skate sounds off your disc')
        made = []
        for folder, name, clip in sounds(game, report):
            path = work / f'{folder}__{name}.snr'
            path.write_bytes(clip)
            made.append(path)
        if not made:
            raise RuntimeError('no sounds were found in the disc\'s audio archives')
        decode(vgmstream, made, report)
        staged = work / 'out'
        index = []
        for path in made:
            folder, name = path.stem.split('__')
            decoded = Path(f'{path}.wav')
            if not decoded.is_file():
                report(f'Skipping {folder}/{name}: vgmstream could not decode it')
                continue
            samples, rate = read_wav(decoded)
            target = rate if rate in SOURCE_RATES else (22050 if rate < 22050 else 44100)
            samples = resample(samples, rate, target)
            (staged / folder).mkdir(parents=True, exist_ok=True)
            write_wav(staged / folder / f'{name}.wav', samples, target, folder in LOOPS)
            index.append(f'{folder}/{name}.wav {len(samples) / target:.2f}s {rate}Hz')
        (staged / 'index.txt').write_text('\n'.join(index) + '\n')
        shutil.rmtree(out, ignore_errors=True)
        shutil.move(str(staged), str(out))
    report(f'Installed {len(index)} skate sounds in {out}')
    return len(index)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--game', type=Path, required=True, help='extracted Skate 3 folder (holding default.xex and data/)')
    parser.add_argument('--out', type=Path, required=True, help='garrysmod/sound/skate3')
    args = parser.parse_args()
    install(args.game, args.out)


if __name__ == '__main__':
    main()
