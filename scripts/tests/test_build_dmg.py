import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'build-dmg.py'
sys.path.insert(0, str(MODULE.parent))


class DmgCleanupTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('build_dmg', MODULE)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.output = Path(self.tmp.name).resolve()
        self.previous = self.output / 'DontSleep-macos-arm64.dmg'
        self.previous.write_bytes(b'previous valid image')

    def fail_during_attach(self, fail_detach):
        def fake_run(*args):
            if args[0] == '/usr/bin/hdiutil':
                if args[1] == 'create':
                    Path(args[-1]).write_bytes(b'new unverified image')
                elif args[1] == 'attach':
                    raise OSError('attach failed after mounting')
                elif args[1] == 'detach' and fail_detach:
                    raise subprocess.CalledProcessError(1, ['hdiutil', 'detach'])
        with patch.object(self.module, 'verify_app', return_value=('0.1.2', '3')), \
                patch.object(self.module, 'verify_bundle'), \
                patch.object(self.module, 'run', side_effect=fake_run), \
                patch.object(self.module.os.path, 'ismount', return_value=True):
            self.module.build(self.output / 'app', self.output)

    def test_failed_detach_retains_staging_and_previous_image(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.fail_during_attach(fail_detach=True)
        stages = list(self.output.glob('.dmg-build.*'))
        self.assertEqual(len(stages), 1)
        self.assertEqual((stages[0] / 'DontSleep-macos-arm64.dmg').read_bytes(), b'new unverified image')
        self.assertEqual(self.previous.read_bytes(), b'previous valid image')

    def test_successful_detach_cleans_failed_build_without_replacing_previous_image(self):
        with self.assertRaisesRegex(OSError, 'attach failed'):
            self.fail_during_attach(fail_detach=False)
        self.assertEqual(list(self.output.glob('.dmg-build.*')), [])
        self.assertEqual(self.previous.read_bytes(), b'previous valid image')


if __name__ == '__main__':
    unittest.main()
