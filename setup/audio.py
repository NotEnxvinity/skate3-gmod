"""Turns the skate sounds on the player's own Skate 3 disc into WAV files
Garry's Mod can play, in garrysmod/sound/skate3.

Skate 3 keeps its audio in EA "EB" archives (data/audio/*.big). The sounds
inside are EA SNR streams (Xbox XMA), packed into banks; this cuts each one
out of its bank and has vgmstream decode it. Source plays 44.1 and 22.05 kHz
WAVs, so other rates are resampled here, looping sounds get the cue point
Source loops from, and the rolling recordings are cut into speed bands.

    python audio.py --game <extracted game folder> --out <garrysmod/sound/skate3>
"""
from pathlib import Path
from fractions import Fraction
import argparse, json, os, shutil, struct, subprocess, sys, tempfile, wave

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
LOOPS = {'spins'}
# The SPLC sound ids the mod plays, per bank folder. Skate 3 names these
# through its attribute vault; the values are retail's, as recovered by
# doriangironde/skate-3-rust-macos (docs/engine-defects.md, splice.rs):
# 0x447 the landing impact, 0x35C-0x35F the landing's soft/hard layer,
# 0x449-0x44B and 0x44F-0x451 the pops (soft, medium, hard) for the two
# surface categories, and 879/883 with metal 399/401 a rail grind's hit.
SOUND_IDS = {
    'collisions': (0x447, 0x35C, 0x35D, 0x35E, 0x35F, 0x449, 0x44A, 0x44B, 0x44F, 0x450, 0x451, 879, 883),
    'metal': (399, 401),
}
# Each rolling grain is one recording that speeds up from a crawl to flat out;
# Skate 3 plays the part for the board's speed. Setup cuts it into this many
# looping bands, which the mod crossfades by speed.
ROLL_BANDS = 8
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
    """A 16-bit PCM WAV; `loop`, a sample position or True for the start,
    adds the cue point Source loops from (to the end)."""
    channels = samples.shape[1]
    pcm = samples.tobytes()
    chunks = [b'fmt ' + struct.pack('<IHHIIHH', 16, 1, channels, rate, rate * channels * 2, channels * 2, 16)]
    if loop is not None and loop is not False:
        start = 0 if loop is True else int(loop)
        chunks.append(b'cue ' + struct.pack('<II', 28, 1) + struct.pack('<II4sIII', 0, start, b'data', 0, 0, start))
    chunks.append(b'data' + struct.pack('<I', len(pcm)) + pcm + b'\0' * (len(pcm) & 1))
    body = b'WAVE' + b''.join(chunks)
    Path(path).write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)


def splc(data):
    """An SPLC bank (the .bnk sound banks): its sample streams, in the order
    the bank numbers them, and what each sound id plays.

    Big-endian. A 60-byte header (+8 the sample table, from byte 60; +12
    records; +16 containers; +20 24-byte extras; +24 samples), 36-byte records
    (+4 id, +7 groups), 72-byte containers (+4 record ids, +68 their count),
    then each record's groups: a 12-byte header (+8 members) and 72-byte
    members (+0 sample, +8 gain). The sample table holds 12-byte entries
    (+0 start, +4 end) into the streams after it. A sound id names a record,
    or, from the record count up, a container that picks one of its ids.

    Returns (streams, play) with play(id) giving the alternatives for a
    sound: lists of groups, each a list of (sample, gain) to pick one from."""
    u32 = lambda at: struct.unpack_from('>I', data, at)[0]
    if data[:4] != b'SPLC' or u32(4) != 3:
        raise ValueError('not an SPLC v3 bank')
    table, records, containers, extras, count = 60 + u32(8), u32(12), u32(16), u32(20), u32(24)
    cursor = 60 + 36 * records + 72 * containers + 24 * extras
    groups = []
    for r in range(records):
        mine = []
        for _ in range(data[60 + 36 * r + 7]):
            members = data[cursor + 8]
            cursor += 12
            mine.append([(struct.unpack_from('>H', data, cursor + 72 * m)[0],
                          round(struct.unpack_from('>f', data, cursor + 72 * m + 8)[0], 4)) for m in range(members)])
            cursor += 72 * members
        groups.append(mine)
    if cursor != table or table + 12 * count > len(data):
        raise ValueError(f'SPLC layout not understood (groups end at {cursor:#x}, table at {table:#x})')
    streams_at = table + 12 * count
    streams = []
    for k in range(count):
        start, end = struct.unpack_from('>II', data, table + 12 * k)
        streams.append(data[streams_at + start:streams_at + end])
    picks = [[struct.unpack_from('>H', data, at + 4 + 2 * j)[0] for j in range(data[at + 68])]
             for at in (60 + 36 * records + 72 * c for c in range(containers))]

    def play(sound, depth=0):
        if sound < records:
            return [groups[sound]]
        if sound - records >= containers or depth > 8:
            return []
        return [alt for pick in picks[sound - records] for alt in play(pick, depth + 1)]
    return streams, play


def bands(samples, rate, count=ROLL_BANDS, fade=0.2):
    """`samples` cut into `count` equal parts, each made into a seamless loop
    by blending its last `fade` seconds into its start."""
    import numpy as np
    length = len(samples) // count
    blend = min(int(rate * fade), length // 2)
    ramp = np.linspace(0, 1, blend, dtype=np.float32)[:, None]
    out = []
    for k in range(count):
        part = samples[k * length:(k + 1) * length].astype(np.float32)
        body, tail = part[:length - blend].copy(), part[length - blend:]
        body[:blend] = body[:blend] * ramp + tail * (1 - ramp)
        out.append(np.clip(np.round(body), -32768, 32767).astype(np.int16))
    return out


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


def loop_start(clip):
    """Where an SNR sound loops from, in samples, or None if it doesn't."""
    if len(clip) < 12:
        return None
    h2, = struct.unpack_from('>I', clip, 4)
    if not (h2 >> 29) & 1:
        return None
    start, = struct.unpack_from('>I', clip, 8)
    return start if start < (h2 & 0x1FFFFFFF) else 0


def check(vgmstream):
    """Decodes a short generated tone, to prove vgmstream runs here."""
    samples = 480
    pcm = b''.join(struct.pack('>h', (i % 40 - 20) * 500) for i in range(samples))
    clip = struct.pack('>II', 0x02000000 | 48000, samples) + bytes([0x80]) + (8 + len(pcm)).to_bytes(3, 'big') + struct.pack('>I', samples) + pcm
    with tempfile.TemporaryDirectory() as work:
        path = Path(work) / 'check.snr'
        path.write_bytes(clip)
        decode(vgmstream, [path], lambda _: None)
        if read_wav(Path(f'{path}.wav'))[0].shape != (samples, 1):
            raise RuntimeError('vgmstream decoded the test sound wrongly')


def sounds(game, report, play=None):
    """(folder, name, snr bytes) for every sound setup installs. SPLC banks
    are numbered as the game numbers them, and `play`, if given, gets what
    their SOUND_IDS play, as {folder: {id: alternatives}}."""
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
                data = big.read(entry)
                if data[:4] == b'SPLC':
                    try:
                        streams, sound = splc(data)
                    except (ValueError, struct.error, IndexError) as error:
                        report(f'Reading {entry} the rough way: {error}')
                    else:
                        if play is not None:
                            play[folder] = {f'{i}': sound(i) for i in SOUND_IDS.get(folder, ())}
                        for i, clip in enumerate(streams):
                            yield folder, f'{i:04d}', clip
                        continue
                for i, clip in enumerate(carve(data)):
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
        made, loops, play = [], {}, {}
        for folder, name, clip in sounds(game, report, play):
            path = work / f'{folder}__{name}.snr'
            path.write_bytes(clip)
            made.append(path)
            loops[path] = loop_start(clip)
        if not made:
            raise RuntimeError('no sounds were found in the disc\'s audio archives')
        decode(vgmstream, made, report)
        staged = work / 'out'
        index, installed, looping = [], 0, {}
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
            loop = True if folder in LOOPS else loops[path]
            if loop is not None and loop is not True:
                loop = loop * target // rate
            write_wav(staged / folder / f'{name}.wav', samples, target, loop)
            index.append(f'{folder}/{name}.wav {len(samples) / target:.2f}s {rate}Hz' + (' loop' if loop is not None else ''))
            if loop is not None:
                looping.setdefault(folder, []).append(name)
            if folder == 'roll':
                for k, band in enumerate(bands(samples, target)):
                    write_wav(staged / folder / f'{name}_{k}.wav', band, target, True)
                    index.append(f'{folder}/{name}_{k}.wav {len(band) / target:.2f}s {rate}Hz')
            installed += 1
        (staged / 'index.txt').write_text('\n'.join(index) + '\n')
        # What the mod reads: the sound ids' samples and which sounds loop.
        (staged / 'sounds.json').write_text(json.dumps({'ids': play, 'loops': looping}))
        shutil.rmtree(out, ignore_errors=True)
        shutil.move(str(staged), str(out))
    report(f'Installed {installed} skate sounds in {out}')
    return installed


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--game', type=Path, required=True, help='extracted Skate 3 folder (holding default.xex and data/)')
    parser.add_argument('--out', type=Path, required=True, help='garrysmod/sound/skate3')
    args = parser.parse_args()
    install(args.game, args.out)


if __name__ == '__main__':
    main()
