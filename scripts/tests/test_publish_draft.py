import importlib.util
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'publish-draft.py'
sys.path.insert(0, str(MODULE.parent))


class PublishDraftTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(), 'Draft publisher is not implemented')
        spec = importlib.util.spec_from_file_location('publish_draft', MODULE)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.dmg = self.root / 'DontSleep-macos-arm64.dmg'
        self.dmg.write_bytes(b'test disk image')
        digest = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        (self.root / 'SHA256SUMS').write_text(digest + '  ' + self.dmg.name + '\n')
        (self.root / 'release-notes.md').write_text('Release notes and first launch instructions')

    def test_creates_only_draft_with_existing_tag_and_exact_assets(self):
        with patch.object(self.module, 'gh', side_effect=['[[]]', 'https://github.com/test/repo/releases/1']) as gh:
            url = self.module.publish('test/repo', 'v0.1.2', self.root)
        self.assertIn('/releases/1', url)
        args = gh.call_args_list[1].args
        self.assertEqual(args[:3], ('release', 'create', 'v0.1.2'))
        self.assertIn('--draft', args)
        self.assertIn('--verify-tag', args)
        self.assertIn('--notes-file', args)
        self.assertIn(str(self.dmg), args)
        self.assertIn(str(self.root / 'SHA256SUMS'), args)
        self.assertEqual(gh.call_count, 2)

    def test_refuses_any_existing_release_including_draft_without_mutation(self):
        for draft in ['true', 'false']:
            with self.subTest(draft=draft), patch.object(self.module, 'gh', return_value=
                    '[[{"tag_name":"v0.1.2","draft":' + draft + '}]]') as gh:
                with self.assertRaisesRegex(ValueError, 'already exists'):
                    self.module.publish('test/repo', 'v0.1.2', self.root)
                self.assertEqual(gh.call_count, 1)

    def test_corrupted_asset_is_rejected_before_any_github_call(self):
        self.dmg.write_bytes(b'corrupted')
        with patch.object(self.module, 'gh') as gh:
            with self.assertRaisesRegex(ValueError, 'checksum'):
                self.module.publish('test/repo', 'v0.1.2', self.root)
            gh.assert_not_called()

    def test_invalid_tag_is_rejected_before_any_github_call(self):
        with patch.object(self.module, 'gh') as gh:
            with self.assertRaises(ValueError):
                self.module.publish('test/repo', 'v0.1.2-beta.1', self.root)
            gh.assert_not_called()

    def test_github_read_failure_does_not_attempt_creation(self):
        with patch.object(self.module, 'gh', side_effect=subprocess.CalledProcessError(1, 'gh')) as gh:
            with self.assertRaises(subprocess.CalledProcessError):
                self.module.publish('test/repo', 'v0.1.2', self.root)
            self.assertEqual(gh.call_count, 1)


if __name__ == '__main__':
    unittest.main()
