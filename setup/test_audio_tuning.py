"""Reads Skate 3's collision tuning from a small vault shaped like the
conversion's skater-collections.json."""
import json, struct, tempfile, unittest
from pathlib import Path

import audio_tuning as t


def i32(v):
    return {'type': 'Attrib::Types::Int32', 'data': struct.pack('>i', v).hex()}


def f32(v):
    return {'type': 'Attrib::Types::Float', 'data': struct.pack('>f', v).hex()}


def ref(key):
    return {'type': 'Attrib::RefSpec', 'data': '0' * 16 + key[5:].lower()}


def vault():
    """Every material with ids 1000 + 7m.., one window and band record, an
    AudioSurfaceMap where material 2 rolls on smooth concrete, 3 on wood and
    8 on metal, and the head's record keyed by its name."""
    out = []
    windows, bands = 'Hash_00000000000000AA', 'Hash_00000000000000BB'
    for m in range(143):
        kind = t.MATERIAL_KINDS[m]
        if kind < 0:
            continue
        fields = {f: i32(1000 + m * 7 + j) for j, f in enumerate(t.MATERIAL_IDS[kind])}
        fields.update({t.MATERIAL_GAIN: i32(30000), t.MATERIAL_PITCH: i32(4096),
                       t.MATERIAL_WINDOWS: ref(windows), t.MATERIAL_BANDS: ref(bands)})
        key = 'head' if m == 97 else 'Hash_%016X' % t.MATERIAL_KEYS[m]
        out.append({'class': t.MATERIAL_CLASS, 'key': key, 'parent': '', 'fields': fields})
    out.append({'class': t.WINDOW_CLASS, 'key': windows, 'parent': '',
                'fields': {**{f: i32(8000 + 2000 * j) for j, f in enumerate(t.WINDOW_FIELDS)}, t.WINDOW_SCALE: f32(0.5)}})
    out.append({'class': t.BAND_CLASS, 'key': bands, 'parent': '',
                'fields': {f: f32(v) for f, v in zip(t.BAND_FIELDS, (1.85, 5.0, 1.0, 0.05))}})
    rows = []
    for m in range(95):
        words = [0] * 18
        words[1] = {2: 4, 3: 5, 8: 9}.get(m, 1)
        words[6] = 3 if m == 2 else 1
        words[7] = 1 if m == 8 else 0
        rows.append(''.join(struct.pack('>i', w).hex() for w in words))
    out.append({'class': t.SURFACE_MAP[0], 'key': t.SURFACE_MAP[1], 'parent': '',
                'fields': {t.SURFACE_MAP[2]: {'type': 'Sk8::AudioSurface', 'array': {'items': rows}}}})
    # Front-end records: one keyed by name, one hashed with a name field, one
    # inheriting its sound from the first, one silent.
    text = lambda v: {'type': 'Attrib::Types::Text', 'data': v}
    out.append({'class': t.FE_CLASSES[0], 'key': 'score_multiplier_x2', 'parent': '',
                'fields': {t.FE_ID: i32(77), t.FE_LEVEL: f32(0.5)}})
    out.append({'class': t.FE_CLASSES[0], 'key': 'Hash_00000000000000CC', 'parent': 'score_multiplier_x2',
                'fields': {t.FE_NAMES[0]: text('score_multiplier_x3'), t.FE_ID: i32(78)}})
    out.append({'class': t.FE_CLASSES[0], 'key': 'quiet', 'parent': '', 'fields': {t.FE_ID: i32(0), t.FE_LEVEL: f32(1.0)}})
    out.append({'class': t.BODY, 'key': 'default', 'parent': '', 'fields': {t.BODY_COOLDOWN: f32(12.0)}})
    # The HUD's multiplier events, keyed by their names' hashes.
    for name, sound in zip(t.MULTIPLIER_EVENTS, (91, 92)):
        out.append({'class': t.FE_CLASSES[0], 'key': 'Hash_%016X' % t.hash64(name), 'parent': '',
                    'fields': {t.FE_ID: i32(sound), t.FE_LEVEL: f32(0.75)}})
    array = lambda values: {'type': 'Attrib::Array', 'array': {'items': [struct.pack('>i', v).hex() for v in values]}}
    board = {t.POP_IDS[0]: array([0x449, 0x44A, 0x44B]), t.POP_IDS[1]: array([0x44F, 0x450, 0x451]),
             t.POP_LEVELS[0]: f32(0.9), t.POP_LEVELS[1]: f32(0.4)}
    for k, (speed, sound) in enumerate(t.WHOOSHES):
        board[speed], board[sound] = f32(3.0 + 3 * (2 - k)), array([500 + k])
    for k, (ids, levels) in enumerate(zip(t.LANDING_IDS, t.LANDING_LEVELS)):
        board[ids] = array([0x35C + 12 * k + j for j in range(12)])
        board[levels] = {'type': 'Attrib::Array', 'data': ''.join(struct.pack('>f', 0.5 + j / 100).hex() for j in range(12))}
    out.append({'class': t.BOARD, 'key': 'default', 'parent': '', 'fields': board})
    return {'collections': out}


class AudioTuningTest(unittest.TestCase):
    def test_hash64(self):
        # The head's record key in retail's material table.
        self.assertEqual(t.hash64('head'), t.MATERIAL_KEYS[97])

    def test_export(self):
        table = t.export(vault())
        head = table['materials'][97]
        self.assertEqual(head['ids'], [1000 + 97 * 7 + j for j in range(7)])
        self.assertEqual((head['gain'], head['pitch']), (30000, 4096))
        self.assertEqual(head['windows'], [8000 + 2000 * j for j in range(14)])
        self.assertAlmostEqual(head['scale'], 0.5)
        self.assertEqual([round(b, 2) for b in head['bands']], [1.85, 5.0, 1.0, 0.05])
        self.assertEqual(table['materials'][94]['kind'], -1)
        self.assertEqual(table['surfaces'][2], [4, 3, 0])
        self.assertEqual(table['grounds'], {'asphalt_rough': 0, 'concrete_smooth': 2, 'wood': 3, 'metal': 8})
        self.assertEqual(table['body_cooldown'], 12.0)
        fe = table['frontend']
        self.assertEqual((fe['score_multiplier_x2'], fe['score_multiplier_x3']), ([77, 0.5], [78, 0.5]))
        self.assertNotIn('quiet', fe)

    def test_surface_rows_keep_every_word(self):
        table = t.export(vault())
        self.assertEqual(len(table['rows']), 95)
        self.assertEqual(len(table['rows'][2]), 18)
        self.assertEqual(table['rows'][2][1], 4)

    def test_multiplier_events_named_from_their_hashes(self):
        fe = t.export(vault())['frontend']
        self.assertEqual(fe['multiplyer_2'], [91, 0.75])
        self.assertEqual(fe['multiplyer_3'], [92, 0.75])

    def test_board_tables(self):
        board = t.export(vault())['board']
        self.assertEqual(board['pop'], [[0x449, 0x44A, 0x44B], [0x44F, 0x450, 0x451]])
        self.assertEqual(board['pop_levels'], [0.9, 0.4])
        # Fastest first, as the vault's thresholds are paired.
        self.assertEqual(board['whooshes'], [[9.0, 500], [6.0, 501], [3.0, 502]])
        self.assertEqual(len(board['landing']), 4)
        self.assertEqual(board['landing'][1]['ids'][0], 0x35C + 12)
        self.assertEqual(len(board['landing'][0]['levels']), 12)
        self.assertAlmostEqual(board['landing'][0]['levels'][3], 0.53, places=4)

    def test_board_tables_are_optional(self):
        v = vault()
        v['collections'] = [c for c in v['collections'] if c['class'] != t.BOARD]
        self.assertNotIn('board', t.export(v))

    def test_without_collision_records(self):
        self.assertIsNone(t.export({'collections': []}))

    def test_install_reads_the_file(self):
        notes = []
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(t.install(Path(tmp) / 'missing.json', notes.append))
            path = Path(tmp) / 'skater-collections.json'
            path.write_text(json.dumps(vault()))
            self.assertEqual(t.install(path, notes.append)['grounds']['wood'], 3)
            path.write_text('{')
            self.assertIsNone(t.install(path, notes.append))
        self.assertEqual(len(notes), 3)


if __name__ == '__main__':
    unittest.main()
