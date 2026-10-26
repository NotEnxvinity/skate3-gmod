"""Builds a tiny disc's audio cache with a stand-in decoder, and the tuning
blobs from a small vault."""
from pathlib import Path
import json, os, stat, struct, tempfile, unittest

import audio_blobs as blobs
import audio_cache as cache
from test_audio import big, snr, splc_bank

FAKE = """#!/bin/sh
case "$1" in
  --continuous) while read name rest; do printf 'pcm' > "$4/$name.xma16"; done < "$3" ;;
  --snr) printf 'pcm' > "$4" ;;
  *) exit 2 ;;
esac
"""


def header(channels, rate, samples, looped=False):
    return struct.pack('>II', (3 << 24) | ((channels - 1) << 18) | rate, samples | (int(looped) << 29))


def abk(samples):
    """A bank whose table at 0x28 holds offsets to SNR headers, past three
    words of its own."""
    table = 0x28
    body = b''
    offsets = []
    start = table + 4 * (3 + len(samples))
    for s in samples:
        offsets.append(start + len(body) - table)
        body += s + b'\0' * 8
    return (b'ABKC'.ljust(32, b'\0') + struct.pack('>I', table) + b'\0' * 4
            + b'\0' * 12 + b''.join(struct.pack('>I', o) for o in offsets) + body)


def disc(folder):
    audio = Path(folder) / 'data/audio'
    audio.mkdir(parents=True)
    bank = abk([header(1, 44100, 1024), header(2, 22050, 2048, True), header(4, 44100, 512)])
    splice = splc_bank([[[(0, 1.0)]]], [[0]], [header(1, 44100, 1024) + b'\0' * 8])
    (audio / 'audiofiles.big').write_bytes(big({'GRINDS.abk': bank, 'Skate_Metal.bnk': splice, 'SK8_AEMS_skateboard.csi': b'csi'}))
    (audio / 'grains.big').write_bytes(big({'wood.grain': struct.pack('>If', 8, 1.0) + snr(441)}))
    (audio / 'wheels.big').write_bytes(big({'spin.snr': snr(480)}))
    (audio / 'MixMapSK8.mxb').write_bytes(b'mix')


def decoder(folder):
    path = Path(folder) / 'skate-xma'
    path.write_text(FAKE)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


@unittest.skipIf(os.name == 'nt', 'the stand-in decoder is a shell script')
class CacheTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        disc(self.root / 'game')
        self.decoder = decoder(self.root)
        self.out = self.root / 'cache'

    def build(self, **kw):
        return cache.build(self.root / 'game', self.out, lambda *_: None, decoder=self.decoder, **kw)

    def test_jobs_name_samples_by_table_index(self):
        data = abk([header(1, 44100, 1024), header(2, 22050, 2048, True)])
        jobs = cache.abk_jobs(data, 'GRINDS')
        self.assertEqual([j.split()[0] for j in jobs], ['GRINDS_0', 'GRINDS_1'])
        # Looped sounds have a loop word before the data; channels and rate come from the header.
        self.assertEqual(jobs[0].split()[2:], ['1024', '1', '44100'])
        self.assertEqual(jobs[1].split()[2:], ['2048', '2', '22050'])
        self.assertEqual(int(jobs[1].split()[1]) - int(jobs[0].split()[1]) , 16 + 4)

    def test_unpacks_and_decodes_everything(self):
        manifest = self.build()
        self.assertTrue(manifest['complete'])
        self.assertEqual(manifest['archives'], {'audiofiles.big': 3, 'grains.big': 1, 'wheels.big': 1})
        self.assertEqual((self.out / 'raw/audiofiles/SK8_AEMS_skateboard.csi').read_bytes(), b'csi')
        self.assertTrue((self.out / 'pcm/audiofiles/GRINDS_0.xma16').is_file())
        self.assertTrue((self.out / 'pcm/audiofiles/GRINDS_1.xma16').is_file())
        # The four-channel sample is not played, so not decoded.
        self.assertFalse((self.out / 'pcm/audiofiles/GRINDS_2.xma16').exists())
        self.assertTrue((self.out / 'pcm/audiofiles/Skate_Metal_0.xma16').is_file())
        self.assertTrue((self.out / 'pcm/grains/wood.xma16').is_file())
        self.assertTrue((self.out / 'pcm/wheels/spin.xma16').is_file())
        self.assertEqual((self.out / 'MixMapSK8.mxb').read_bytes(), b'mix')
        self.assertEqual(json.loads((self.out / 'manifest.json').read_text())['format'], 'skatev-audio-cache')

    def test_reuses_a_current_cache_and_rebuilds_a_damaged_one(self):
        self.build()
        stamp = self.out / 'pcm/audiofiles/GRINDS_0.xma16'
        stamp.write_bytes(b'kep')
        self.build()
        self.assertEqual(stamp.read_bytes(), b'kep')  # current: not decoded again
        stamp.write_bytes(b'different size')
        self.build()
        self.assertEqual(stamp.read_bytes(), b'pcm')

    def test_a_changed_disc_rebuilds(self):
        self.build()
        (self.out / 'raw/audiofiles/stale.abk').write_bytes(b'old')
        (self.root / 'game/data/audio/MixMapSK8.mxb').write_bytes(b'new mix')
        self.build()
        self.assertFalse((self.out / 'raw/audiofiles/stale.abk').exists())
        self.assertEqual((self.out / 'MixMapSK8.mxb').read_bytes(), b'new mix')

    def test_decoder_failures_are_reported(self):
        bad = self.root / 'bad'
        bad.write_text('#!/bin/sh\nexit 3\n')
        bad.chmod(0o755)
        manifest = cache.build(self.root / 'game', self.out, lambda *_: None, decoder=bad)
        self.assertFalse(manifest['complete'])
        self.assertTrue(manifest['problems'])

    def test_missing_disc_or_decoder(self):
        with self.assertRaises(RuntimeError):
            cache.build(self.root / 'nowhere', self.out, lambda *_: None, decoder=self.decoder)
        with tempfile.TemporaryDirectory() as empty, self.assertRaises(RuntimeError):
            old = os.environ.get('SKATE3_XMA'), os.environ.get('PATH')
            try:
                os.environ.pop('SKATE3_XMA', None)
                os.environ['PATH'] = empty
                if cache.find_decoder() is not None:
                    self.skipTest('a skate-xma is built next to the repo')
                cache.build(self.root / 'game', self.out, lambda *_: None)
            finally:
                os.environ['PATH'] = old[1]

    def test_unsafe_archive_member(self):
        audio = self.root / 'game/data/audio'
        (audio / 'wheels.big').write_bytes(big({'../evil.snr': snr(480)}))
        with self.assertRaises(ValueError):
            self.build()


def text(value):
    return {'type': 'EA::Reflection::Text', 'data': value}


def number(kind, packed):
    return {'type': 'EA::Reflection::' + kind, 'data': packed.hex()}


def vault_for_blobs():
    collections = []
    for class_key, key in sorted(set(blobs.ROOTS.values()) - {('7AB23C11B6ADA2DE', 'default')}):
        collections.append({'class': 'Hash_' + class_key, 'key': key, 'parent': '',
                            'fields': {'Hash_0000000000000001': number('Int32', struct.pack('>i', 5))}})
    fields = {'Hash_2C073BF8BC45063B': text('wood.grain'),
              'Hash_A985FBAA9326718D': {'type': 'x', 'data': (b'\1' * 64).hex()},
              'Hash_D18D1174735E5CDE': {'type': 'x', 'array': {'element_size': 20, 'items': [(b'\2' * 20).hex()] * 2}},
              'Hash_00000000000000F1': number('Float', struct.pack('>f', 1.5))}
    fields.update({'Hash_' + k: {'type': 'x', 'data': b'\3\3\3\3'.hex()} for k in blobs.CURVE})
    collections.append({'class': blobs.CLASS, 'key': 'default', 'parent': '', 'fields': fields})
    collections.append({'class': blobs.CLASS, 'key': 'Hash_0000000000001234', 'parent': 'default', 'fields': {}})
    return {'version': 1, 'collections': collections}


class BlobTest(unittest.TestCase):
    def test_default_collection_id(self):
        self.assertEqual(blobs.identity('default'), blobs.DEFAULT)
        self.assertEqual(blobs.identity('Hash_00000000000000FF'), 255)

    def test_grain_tuning(self):
        data = blobs.encode_grains(vault_for_blobs())
        self.assertEqual(data[:4], b'SVGT')
        self.assertEqual(struct.unpack_from('>II', data, 4), (1, 2))
        self.assertIn(b'wood', data)

    def test_grain_names_must_be_plain(self):
        vault = vault_for_blobs()
        vault['collections'][-2]['fields']['Hash_2C073BF8BC45063B'] = text('../x.grain')
        with self.assertRaises(ValueError):
            blobs.encode_grains(vault)

    def test_inheritance_cycles_are_refused(self):
        vault = vault_for_blobs()
        vault['collections'][-2]['parent'] = 'Hash_0000000000001234'
        with self.assertRaises(ValueError):
            blobs.encode_grains(vault)

    def test_component_tuning_without_the_executable_tables(self):
        data = blobs.encode_components(vault_for_blobs(), None)
        self.assertEqual(data[:4], b'SVAT')
        count, roots, fixed = struct.unpack_from('>III', data, 8)
        self.assertEqual((roots, fixed), (len(blobs.ROOTS), 0))
        self.assertGreaterEqual(count, len(set(blobs.ROOTS.values())))

    def test_component_tuning_needs_every_root(self):
        vault = vault_for_blobs()
        vault['collections'].pop(0)
        with self.assertRaises(ValueError):
            blobs.encode_components(vault, None)

    def test_unknown_executables_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            xex = Path(folder) / 'default.xex'
            xex.write_bytes(b'XEX2' + b'\0' * 64)
            with self.assertRaises(ValueError):
                blobs.image_from_xex(xex)


if __name__ == '__main__':
    unittest.main()
