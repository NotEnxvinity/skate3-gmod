"""Setup installs the addon it carries into garrysmod/addons/skate3, replacing
an older copy whole; --no-addon removes an old copy instead."""
from pathlib import Path
import tempfile, unittest

import skate3_setup


class AddonTest(unittest.TestCase):
    def test_removes_old_copy(self):
        with tempfile.TemporaryDirectory() as gmod:
            old = Path(gmod) / 'addons/skate3/lua/skate3'
            old.mkdir(parents=True)
            (old / 'cl_skate3.lua').write_text('-- old')
            skate3_setup.install_addon(Path(gmod), False, lambda _: None)
            self.assertFalse((Path(gmod) / 'addons/skate3').exists())

    def test_leaves_other_folders(self):
        with tempfile.TemporaryDirectory() as gmod:
            other = Path(gmod) / 'addons/skate3/models'
            other.mkdir(parents=True)
            skate3_setup.install_addon(Path(gmod), False, lambda _: None)
            self.assertTrue(other.is_dir())

    def test_with_addon(self):
        with tempfile.TemporaryDirectory() as gmod:
            skate3_setup.install_addon(Path(gmod), True, lambda _: None)
            self.assertTrue((Path(gmod) / 'addons/skate3/lua/autorun').is_dir())

    def test_replaces_old_copy(self):
        with tempfile.TemporaryDirectory() as gmod:
            stale = Path(gmod) / 'addons/skate3/lua/skate3/cl_gone.lua'
            stale.parent.mkdir(parents=True)
            stale.write_text('-- removed in an update')
            skate3_setup.install_addon(Path(gmod), True, lambda _: None)
            self.assertFalse(stale.exists())
            self.assertTrue((Path(gmod) / 'addons/skate3/addon.json').is_file())
            self.assertTrue((Path(gmod) / 'addons/skate3/lua/skate3/cl_skate3.lua').is_file())


if __name__ == '__main__':
    unittest.main()
