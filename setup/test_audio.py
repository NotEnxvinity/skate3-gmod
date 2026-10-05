"""Builds tiny EA audio archives holding PCM sounds and reads them back; with
vgmstream-cli available (SKATE3_VGMSTREAM or PATH) it runs the whole install."""
from pathlib import Path
import json, math, os, struct, tempfile, unittest, wave

import audio


def snr(samples, rate=48000, block_id=0x80):
    """An in-memory EA SNR sound, codec PCM16BE (vgmstream decodes it without
    FFmpeg): header, then one block."""
    pcm = b''.join(struct.pack('>h', int(8000 * math.sin(i / 7))) for i in range(samples))
    return (struct.pack('>II', 0x02000000 | rate, samples)
            + bytes([block_id]) + (8 + len(pcm)).to_bytes(3, 'big') + struct.pack('>I', samples) + pcm)


def looped(samples):
    """An SNR sound with the loop flag, looping whole (vgmstream only takes a
    partway loop from the compressed codecs)."""
    plain = snr(samples)
    return plain[:4] + struct.pack('>II', (1 << 29) | samples, 0) + plain[8:]


def splc_bank(records, containers, streams):
    """An SPLC v3 bank: `records` lists each record's groups, each a list of
    (sample, gain); `containers` lists record ids per container."""
    head = struct.pack('>4sI', b'SPLC', 3)
    body = b''.join(struct.pack('>IHBB', 0, i, 0, len(groups)).ljust(36, b'\0') for i, groups in enumerate(records))
    body += b''.join((struct.pack('>I', 0) + b''.join(struct.pack('>H', i) for i in ids)).ljust(68, b'\0')
                     + bytes([len(ids), 0, 0, 0]) for ids in containers)
    for groups in records:
        for members in groups:
            body += struct.pack('>QBB', 0, len(members), 0).ljust(12, b'\0')
            body += b''.join(struct.pack('>HHIf', sample, 0, 0, gain).ljust(72, b'\0') for sample, gain in members)
    table, data = b'', b''
    for stream in streams:
        table += struct.pack('>III', len(data), len(data) + len(stream), 0)
        data += stream + b'\0' * 5
    header = head + struct.pack('>IIIII', len(body), len(records), len(containers), 0, len(streams))
    return header.ljust(60, b'\0') + body + table + data


def big(files, slot=40, shift=4):
    names = list(files)
    count = len(names)
    names_at = (0x30 + 16 * count + 15) // 16 * 16 + 16
    data_at = (names_at + slot * count + 15) // 16 * 16
    table, blob, at = b'', b'', data_at
    for name in names:
        table += struct.pack('>IIII', at >> shift, 0, len(files[name]), 0)
        padded = files[name] + b'\0' * (-len(files[name]) % (1 << shift))
        blob += padded
        at += len(padded)
    head = (b'EB\0\3' + struct.pack('>I', count) + bytes([0, 0x10, shift, 0]) + struct.pack('>II', names_at, 0x30 + 16 * count)
            + bytes([slot, 2, 0, 1]) + b'\0' * 4 + struct.pack('>I', at))
    head = head.ljust(0x30, b'\0') + table
    head = head.ljust(names_at, b'\0') + b''.join((b'\0\0' + n.encode()).ljust(slot, b'\0') for n in names)
    return head.ljust(data_at, b'\0') + blob


def game(folder):
    # Odd gaps: banks don't keep sounds on any alignment.
    bank = b'SPLC' + b'\0' * 61 + snr(480) + b'\0' * 23 + snr(960, 22050, 0) + b'\0' * 3 + snr(250)
    grain = struct.pack('>If', 0x10, 17.5) + b'\0' * 8 + snr(4410, 44100)
    audio_dir = Path(folder) / 'data/audio'
    audio_dir.mkdir(parents=True)
    metal = splc_bank([[[(1, 0.5)]], [[(0, 1.0), (1, 0.8)], [(1, 0.25)]]], [[0, 1]], [snr(120), snr(240, 22050)])
    (audio_dir / 'audiofiles.big').write_bytes(big({'Skate_Collisions.bnk': bank, 'Skate_Metal.bnk': metal,
                                                    'GRINDS.abk': b'ABKC' + snr(300) + looped(900)}))
    (audio_dir / 'grains.big').write_bytes(big({'wood_ramp_soft.grain': grain}))
    (audio_dir / 'wheels.big').write_bytes(big({'Whls_spins_Jump_1.sek': b'\0' * 87, 'Whls_spins_Jump_1.snr': snr(4800)}, slot=24))


class AudioTest(unittest.TestCase):
    def test_reads_archives_and_cuts_out_sounds(self):
        with tempfile.TemporaryDirectory() as tmp:
            game(tmp)
            found = {(folder, name): clip for folder, name, clip in audio.sounds(tmp, lambda _: None)}
            self.assertEqual(sorted(found), [('collisions', '000'), ('collisions', '001'), ('collisions', '002'),
                                             ('grinds', '000'), ('grinds', '001'), ('metal', '0000'), ('metal', '0001'),
                                             ('roll', 'wood_ramp_soft'), ('spins', 'whls_spins_jump_1')])
            self.assertEqual(found['metal', '0001'], snr(240, 22050))
            self.assertEqual(found['collisions', '001'], snr(960, 22050, 0))
            self.assertEqual(found['roll', 'wood_ramp_soft'], snr(4410, 44100))

    def test_splc_numbers_samples_and_resolves_sounds(self):
        bank = splc_bank([[[(1, 0.5)]], [[(0, 1.0), (1, 0.8)], [(1, 0.25)]]], [[0, 1]], [snr(120), snr(240)])
        streams, play = audio.splc(bank)
        self.assertEqual(streams, [snr(120), snr(240)])
        self.assertEqual(play(0), [[[(1, 0.5)]]])
        self.assertEqual(play(1), [[[(0, 1.0), (1, 0.8)], [(1, 0.25)]]])
        # A container offers each of its records.
        self.assertEqual(play(2), play(0) + play(1))
        self.assertEqual(play(3), [])
        with self.assertRaises(ValueError):
            audio.splc(bank[:60] + bank[61:])

    def test_loop_start(self):
        self.assertIsNone(audio.loop_start(snr(100)))
        self.assertEqual(audio.loop_start(looped(100)), 0)
        partway = looped(100)[:8] + struct.pack('>I', 40) + looped(100)[12:]
        self.assertEqual(audio.loop_start(partway), 40)

    def test_ignores_lookalikes(self):
        clip = snr(100)
        broken = clip[:8] + b'\x44' + clip[9:]
        self.assertEqual(audio.carve(b'\0' * 12 + broken), [])

    def test_resamples_to_source_rates(self):
        import numpy as np
        tone = (np.sin(np.arange(48000) * 2 * np.pi * 1000 / 48000) * 10000).astype(np.int16)[:, None]
        out = audio.resample(tone, 48000, 44100)
        self.assertEqual(len(out), 44100)
        middle = out[1000:-1000, 0].astype(float)
        self.assertAlmostEqual(np.abs(middle).max(), 10000, delta=150)
        peak = np.argmax(np.abs(np.fft.rfft(middle)))
        self.assertAlmostEqual(peak * 44100 / len(middle), 1000, delta=2)

    def test_roll_bands_loop_seamlessly(self):
        import numpy as np
        ramp = np.arange(80000, dtype=np.int16)[:, None] // 4
        parts = audio.bands(ramp, 1000, count=4, fade=1.0)
        self.assertEqual([len(p) for p in parts], [19000] * 4)
        for k, part in enumerate(parts):
            # The loop's end runs straight on into its start.
            self.assertLessEqual(abs(int(part[0, 0]) - int(ramp[k * 20000 + 19000, 0])), 1)
            self.assertEqual(part[-1, 0], ramp[k * 20000 + 18999, 0])

    def test_loop_cue(self):
        import numpy as np
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'loop.wav'
            audio.write_wav(path, np.zeros((11, 1), dtype=np.int16), 44100, True)
            data = path.read_bytes()
            self.assertIn(b'cue ', data)
            with wave.open(str(path)) as w:
                self.assertEqual((w.getframerate(), w.getnframes()), (44100, 11))

    @unittest.skipUnless(audio.find_vgmstream(), 'vgmstream-cli not available')
    def test_check(self):
        audio.check(audio.find_vgmstream())

    @unittest.skipUnless(audio.find_vgmstream(), 'vgmstream-cli not available')
    def test_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            game(tmp)
            out = Path(tmp) / 'garrysmod/sound/skate3'
            self.assertEqual(audio.install(tmp, out, lambda _: None), 9)
            with wave.open(str(out / 'collisions/000.wav')) as w:
                self.assertEqual((w.getframerate(), w.getnframes()), (44100, 441))
            with wave.open(str(out / 'collisions/001.wav')) as w:
                self.assertEqual((w.getframerate(), w.getnframes()), (22050, 960))
            self.assertNotIn(b'cue ', (out / 'roll/wood_ramp_soft.wav').read_bytes())
            for k in range(audio.ROLL_BANDS):
                self.assertIn(b'cue ', (out / f'roll/wood_ramp_soft_{k}.wav').read_bytes())
            self.assertNotIn(b'cue ', (out / 'grinds/000.wav').read_bytes())
            self.assertIn('spins/whls_spins_jump_1.wav', (out / 'index.txt').read_text())
            manifest = json.loads((out / 'sounds.json').read_text())
            self.assertEqual(manifest['loops']['grinds'], ['001'])
            self.assertEqual(manifest['ids']['metal'], {'399': [], '401': []})
            self.assertIn(b'cue ', (out / 'grinds/001.wav').read_bytes())


if __name__ == '__main__':
    unittest.main()
