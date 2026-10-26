"""Setup installs the addon it carries into garrysmod/addons/skate3, replacing
an older copy whole; --no-addon removes an old copy instead."""
from pathlib import Path
import os, tempfile, unittest

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


class ModuleCopyTest(unittest.TestCase):
    """An old skate module that is read-only (a Mac install left one) must not
    stop setup."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.src = Path(self.dir.name) / 'new.dll'
        self.src.write_bytes(b'new module')
        self.dst = Path(self.dir.name) / 'old.dll'

    def tearDown(self):
        self.dir.cleanup()

    def test_fresh_copy(self):
        skate3_setup.put_module(self.src, self.dst)
        self.assertEqual(self.dst.read_bytes(), b'new module')

    @unittest.skipIf(os.name == 'nt', 'POSIX permissions')
    def test_read_only_old_copy_is_replaced(self):
        self.dst.write_bytes(b'old module')
        self.dst.chmod(0o444)
        skate3_setup.put_module(self.src, self.dst)
        self.assertEqual(self.dst.read_bytes(), b'new module')
        self.assertTrue(os.access(self.dst, os.W_OK))

    @unittest.skipIf(os.name == 'nt', 'POSIX permissions')
    def test_unchanged_read_only_copy_is_left_alone(self):
        self.dst.write_bytes(b'new module')
        self.dst.chmod(0o444)
        skate3_setup.put_module(self.src, self.dst)
        self.assertEqual(self.dst.read_bytes(), b'new module')

    def test_locked_old_copy_is_removed_then_replaced(self):
        # As if the old file refuses a write even after chmod: setup deletes it.
        from unittest import mock
        self.dst.write_bytes(b'old module')
        real = skate3_setup.shutil.copyfile
        calls = []

        def refuse_while_old_exists(a, b, *args, **kwargs):
            calls.append(Path(b).exists())
            if Path(b).exists():
                raise PermissionError(13, 'Permission denied', str(b))
            return real(a, b, *args, **kwargs)

        with mock.patch.object(skate3_setup.shutil, 'copyfile', refuse_while_old_exists):
            skate3_setup.put_module(self.src, self.dst)
        self.assertEqual(self.dst.read_bytes(), b'new module')
        self.assertEqual(calls, [True, True, False])

    def test_stuck_old_copy_gets_a_plain_message(self):
        from unittest import mock
        self.dst.write_bytes(b'old module')

        def always_refuse(a, b, *args, **kwargs):
            raise PermissionError(13, 'Permission denied', str(b))

        with mock.patch.object(skate3_setup.shutil, 'copyfile', always_refuse):
            with self.assertRaises(RuntimeError) as caught:
                skate3_setup.put_module(self.src, self.dst)
        self.assertIn('Close Garry', str(caught.exception))


class MacDecoderTest(unittest.TestCase):
    """Setup's Python on an Apple-silicon Mac is native and can't load the
    Intel skate module; it must look for the arm64 decoder library instead."""

    def test_native_mac_python_wants_the_arm64_library(self):
        import native_tools
        from unittest import mock
        with mock.patch.object(native_tools.sys, 'platform', 'darwin'), \
                mock.patch.object(native_tools.platform, 'machine', return_value='arm64'):
            self.assertEqual(native_tools.module_name(), native_tools.ARM_TOOLS)
        with mock.patch.object(native_tools.sys, 'platform', 'darwin'), \
                mock.patch.object(native_tools.platform, 'machine', return_value='x86_64'):
            self.assertEqual(native_tools.module_name(), 'gmcl_skate3_osx64.dll')

    def test_a_library_that_will_not_load_says_why(self):
        import native_tools
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / 'gmcl_skate3_osx64.dll'
            bad.write_bytes(b'not a library')
            self.assertIsNone(native_tools.xex_reader(module=bad))
        self.assertIn('would not load', native_tools.LOAD_ERROR)
