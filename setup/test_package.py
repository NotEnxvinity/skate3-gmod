"""The S3GM-setup folder package.py makes: only launchers and the README on
top, so players can't start the wrong file."""
from pathlib import Path
import os, sys, tempfile, unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package  # noqa: E402


class StageFolder(unittest.TestCase):
    def stage(self, names, platform=None):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        modules = tmp / 'modules'
        modules.mkdir()
        for name in names:
            (modules / name).write_bytes(b'module')
        out = tmp / 'S3GM-setup'
        package.stage_folder(modules, out, platform)
        return out

    def test_win_linux_zip_has_only_its_launchers_on_top(self):
        out = self.stage(['gmcl_skate3_win64.dll', 'gmcl_skate3_linux64.dll'])
        self.assertEqual(sorted(p.name for p in out.iterdir()),
                         ['README-S3GM.txt', 'S3GM-setup-Linux.sh', 'S3GM-setup-Windows.bat', 'setup-files'])
        files = out / 'setup-files'
        for name in ('skate3_setup.py', 'skate3-setup.sh', 'windows-setup.ps1', 'VERSION', 'LICENSE',
                     'NOTICE', 'README.txt', 'bin/gmcl_skate3_win64.dll', 'addon/addon.json'):
            self.assertTrue((files / name).exists(), name)
        self.assertFalse(list(out.rglob('__pycache__')))
        self.assertFalse(list(out.rglob('test_*.py')))
        if os.name != 'nt':
            self.assertTrue(os.access(out / 'S3GM-setup-Linux.sh', os.X_OK))

    def test_mac_zip_has_only_the_mac_launcher_and_module(self):
        out = self.stage(['gmcl_skate3_win64.dll', 'gmcl_skate3_linux64.dll', 'gmcl_skate3_osx64.dll'], 'mac')
        self.assertEqual(sorted(p.name for p in out.iterdir()),
                         ['README-S3GM.txt', 'S3GM-setup-Mac.command', 'setup-files'])
        self.assertEqual([p.name for p in (out / 'setup-files/bin').iterdir()], ['gmcl_skate3_osx64.dll'])
        self.assertFalse((out / 'setup-files/windows-setup.ps1').exists())
        self.assertTrue((out / 'setup-files/skate3-setup.sh').exists())


if __name__ == '__main__':
    unittest.main()
