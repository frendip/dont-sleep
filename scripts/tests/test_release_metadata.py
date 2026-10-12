import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'release_metadata.py'


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(), 'Release metadata validator is not implemented')
        spec = importlib.util.spec_from_file_location('release_metadata', MODULE)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'Resources').mkdir()
        (self.root / 'docs').mkdir()
        (self.root / 'docs/installation.txt').write_text('Первый запуск: Open Anyway.\n')
        self.plist = self.root / 'Resources/Info.plist'
        self.plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.2',
                                             'CFBundleVersion': '3'}))
        self.notes = self.root / 'CHANGELOG.md'
        self.notes.write_text('# История\n\n## 0.1.2 — 2026-10-12\n\n- Новый выпуск.\n\n'
                              '## 0.1.1 — 2026-10-10\n\n- Старый выпуск.\n')

    def test_notes_contain_only_selected_release_and_installation_instructions(self):
        result = self.module.release_notes(self.root, 'v0.1.2')
        self.assertIn('Новый выпуск', result)
        self.assertNotIn('Старый выпуск', result)
        self.assertIn('Open Anyway', result)
        self.assertIn('Developer ID', result)
        self.assertIn('3', result)

    def test_rejects_tag_version_mismatch_and_malformed_tags(self):
        for tag in ['v0.1.1', '0.1.2', 'v0.1.2-beta.1', 'v00.1.2', 'v0.1.2\n', 'v0.1.2; echo bad']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.module.release_notes(self.root, tag)

    def test_rejects_pending_empty_wrong_version_or_invalid_date_notes(self):
        for text in ['## 0.1.2 — готовится\n\n- Pending\n',
                     '## 0.1.2 — 2026-10-12\n\n',
                     '## 0.1.3 — 2026-10-12\n\n- Other\n',
                     '## 0.1.2 — 2026-02-31\n\n- Wrong date\n']:
            self.notes.write_text(text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.module.release_notes(self.root, 'v0.1.2')

    def test_bundle_must_match_product_and_build_versions(self):
        app = self.root / 'Don’t Sleep.app'
        (app / 'Contents').mkdir(parents=True)
        bundle_plist = app / 'Contents/Info.plist'
        for version, build in [('0.1.1', '3'), ('0.1.2', '2')]:
            bundle_plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': version,
                                                   'CFBundleVersion': build}))
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                self.module.verify_app(self.root, app)
        bundle_plist.write_bytes(self.plist.read_bytes())
        self.assertEqual(self.module.verify_app(self.root, app), ('0.1.2', '3'))

    def test_invalid_build_number_is_rejected(self):
        for build in ['0', '-1', '2.1', '', 3]:
            self.plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.2',
                                                 'CFBundleVersion': build}))
            with self.subTest(build=build), self.assertRaises(ValueError):
                self.module.release_notes(self.root, 'v0.1.2')


if __name__ == '__main__':
    unittest.main()
