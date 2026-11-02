"""The browser setup window: its server answers only its own address, lists
folders, runs the install hook and reports its log."""
from pathlib import Path
import http.client, json, tempfile, time, unittest

import setup_web


def hooks(problems=()):
    def install(picked, folder, report, with_addon=True, audio_engine=False):
        report('line one\nline two')
        return list(problems)
    return {'version': lambda: 'v9', 'garrysmod_in': lambda p: Path(p) if p and Path(p).is_dir() else None,
            'install': install, 'workshop_copy': lambda g: False, 'workshop_note': 'note'}


class WebSetupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.gm = Path(self.tmp.name) / 'garrysmod'
        self.gm.mkdir()
        (self.gm / '.hidden').mkdir()
        (self.gm / 'game.iso').write_bytes(b'x')
        (self.gm / 'notes.txt').write_bytes(b'x')
        self.state = setup_web.serve(self.gm, None, hooks(), show=False)
        self.addCleanup(self.state.server.shutdown)
        self.addCleanup(self.tmp.cleanup)
        self.port = self.state.server.server_address[1]
        self.base = self.state.url.split(str(self.port), 1)[1]

    def request(self, method, path, body=None, host=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        conn.request(method, path, json.dumps(body) if body is not None else None,
                     {'Host': host or f'127.0.0.1:{self.port}'})
        response = conn.getresponse()
        data = response.read()
        conn.close()
        return response.status, data

    def api(self, call, body=None):
        status, data = self.request('POST' if body is not None else 'GET', self.base + 'api/' + call, body)
        self.assertEqual(status, 200)
        return json.loads(data)

    def test_page_carries_its_own_fonts_and_nothing_external(self):
        status, data = self.request('GET', self.base)
        page = data.decode()
        self.assertEqual(status, 200)
        self.assertIn('font/woff2;base64', page)
        self.assertNotIn('http://', page.replace('http://127', ''))
        self.assertNotIn('https://', page)

    def test_wrong_secret_or_host_is_refused(self):
        self.assertEqual(self.request('GET', '/nope/')[0], 404)
        self.assertEqual(self.request('GET', '/nope/api/init')[0], 404)
        self.assertEqual(self.request('GET', self.base, host='evil.example')[0], 403)

    def test_init_and_folder_listing(self):
        init = self.api('init')
        self.assertEqual((init['version'], init['gmod']), ('v9', str(self.gm)))
        listing = self.api('ls?mode=file&path=' + str(self.gm))
        self.assertEqual([d['name'] for d in listing['dirs']], ['.hidden'])
        self.assertEqual([f['name'] for f in listing['files']], ['game.iso'])
        self.assertEqual([f['name'] for f in self.api('ls?mode=dir&path=' + str(self.gm))['files']], [])

    def test_install_reports_its_log_and_finishes(self):
        bad = self.api('install', {'gmod': str(self.gm), 'disc': str(self.gm / 'missing.iso'), 'engine': True})
        self.assertIn('disc image', bad['error'])
        self.assertIn('error', self.api('install', {'gmod': '', 'disc': str(self.gm / 'game.iso')}))
        self.assertTrue(self.api('install', {'gmod': str(self.gm), 'disc': str(self.gm / 'game.iso'), 'engine': True})['ok'])
        for _ in range(50):
            status = self.api('status?since=0')
            if status['state'] != 'running':
                break
            time.sleep(0.1)
        self.assertEqual(status['state'], 'done')
        self.assertEqual([l['text'] for l in status['lines']], ['line one', 'line two'])
        self.assertIn('v9', status['message'])


if __name__ == '__main__':
    unittest.main()
