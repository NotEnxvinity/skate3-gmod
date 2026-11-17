"""Builds a tiny front-end archive holding the two language tables and reads
the trick names back; needs the engine's tools (SKATE3_ENGINE)."""
from pathlib import Path
import json, os, struct, tempfile, unittest

import names
from test_audio import big

ENGINE = os.environ.get('SKATE3_ENGINE')


def table(strings):
    """A language table: 28-byte header, an 8-byte pool descriptor, then the
    null-separated strings (the count leaves out the two pool ends)."""
    pool = b'\0'.join(s.encode('latin-1') for s in strings)
    return struct.pack('<IIIII', 0, 0, len(strings) - 2, 28, 28).ljust(28, b'\0') + b'\0' * 8 + pool


@unittest.skipUnless(ENGINE, 'SKATE3_ENGINE not set')
class NamesTest(unittest.TestCase):
    def test_install(self):
        labels = table(['', 'ID_TRICK_FLIP_NOLLIE_KICKFLIP', 'ID_MENU_START', 'ID_TRICK_GRAB_MIRACLE_WHIP', 'ID_TRICK_EMPTY',
                        'ID_GESTURE_SPOCK', ''])
        english = table(['', 'Nollie Kickflip', 'Start', 'Miracle Whip ', '', 'Live Long', ''])
        with tempfile.TemporaryDirectory() as tmp:
            disc = Path(tmp) / 'disc/data/big'
            disc.mkdir(parents=True)
            (disc / 'fedata.big').write_bytes(big({names.LABELS: labels, names.ENGLISH: english}, slot=80))
            out = Path(tmp) / 'data/skate3'
            self.assertEqual(names.install(ENGINE, Path(tmp) / 'disc', out, lambda _: None), 2)
            self.assertEqual(json.loads((out / 'tricks.json').read_text(encoding='utf-8')),
                             {'ID_TRICK_FLIP_NOLLIE_KICKFLIP': 'Nollie Kickflip', 'ID_TRICK_GRAB_MIRACLE_WHIP': 'Miracle Whip'})
            self.assertEqual(json.loads((out / 'gestures.json').read_text(encoding='utf-8')), {'ID_GESTURE_SPOCK': 'Live Long'})

    def test_missing_tables(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(RuntimeError):
                names.install(ENGINE, tmp, Path(tmp) / 'out', lambda _: None)


if __name__ == '__main__':
    unittest.main()
