"""The desktop fonts handed to a no-Xft Tk on Linux."""
from pathlib import Path
import sys, tempfile, unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import xfonts  # noqa: E402


class XFonts(unittest.TestCase):
    def test_picks_first_family_with_both_files(self):
        found = {'NotoSans-Regular.ttf': '/f/a', 'NotoSans-Bold.ttf': '/f/b', 'DejaVuSans.ttf': '/f/c',
                 'LiberationMono-Regular.ttf': '/f/d', 'LiberationMono-Bold.ttf': '/f/e'}
        self.assertEqual(xfonts.pick(found), [('noto sans', '/f/a', '/f/b'), ('liberation mono', '/f/d', '/f/e')])

    def test_fonts_dir_lists_scalable_names(self):
        text = xfonts.fonts_dir_text([('dejavu sans', '/x/DejaVuSans.ttf', '/x/DejaVuSans-Bold.ttf')])
        self.assertEqual(text.splitlines(), [
            '2',
            'DejaVuSans.ttf -s3gm-dejavu sans-medium-r-normal--0-0-0-0-p-0-iso10646-1',
            'DejaVuSans-Bold.ttf -s3gm-dejavu sans-bold-r-normal--0-0-0-0-p-0-iso10646-1'])

    def test_folder_and_finding(self):
        with tempfile.TemporaryDirectory() as tmp:
            fonts = Path(tmp) / 'fonts/TTF'
            fonts.mkdir(parents=True)
            for name in ('DejaVuSans.ttf', 'DejaVuSans-Bold.ttf'):
                (fonts / name).write_bytes(b'ttf')
            found = xfonts.find_files(['DejaVuSans.ttf', 'DejaVuSans-Bold.ttf', 'NotoSans-Regular.ttf'], [str(Path(tmp) / 'fonts')])
            folder = xfonts.make_folder(xfonts.pick(found), Path(tmp) / 'cache/xfonts')
            self.assertEqual((folder / 'DejaVuSans.ttf').read_bytes(), b'ttf')
            self.assertTrue((folder / 'fonts.dir').read_text().startswith('2\n'))

    def test_nothing_without_a_display(self):
        import os
        saved = os.environ.pop('DISPLAY', None)
        try:
            self.assertEqual(xfonts.install(), [])
        finally:
            if saved is not None:
                os.environ['DISPLAY'] = saved


if __name__ == '__main__':
    unittest.main()
