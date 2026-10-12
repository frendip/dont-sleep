import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'prepare-release.py'


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo'
        self.root.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        self.git('init', '-b', 'main')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'tag.gpgsign', 'false')
        (self.root / 'scripts').mkdir()
        if SCRIPT.exists():
            shutil.copy2(SCRIPT, self.root / 'scripts/prepare-release.py')
        (self.root / 'Resources').mkdir()
        self.plist = self.root / 'Resources/Info.plist'
        self.plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.1',
                                             'CFBundleVersion': '2', 'CFBundleName': 'Don’t Sleep'}))
        self.changelog = self.root / 'CHANGELOG.md'
        self.changelog.write_text('# История изменений\n\n## 0.1.1 — готовится\n\n'
                                  '- Исправление меню.\n'
                                  '- Кандидат: версия `0.1.1`, сборка `2`.\n\n'
                                  '## 0.1.0 — исходная локальная версия\n\n- Старые изменения.\n')
        self.git('add', '.')
        self.git('commit', '-m', 'Initial fixture')
        self.initial = self.git('rev-parse', 'HEAD').stdout.strip()
        remote = Path(self.tmp.name) / 'remote.git'
        self.git('init', '--bare', str(remote))
        self.git('remote', 'add', 'origin', str(remote))
        self.git('push', '-u', 'origin', 'main')

    def git(self, *args, check=True):
        return subprocess.run(['git', *args], cwd=self.root, env=self.env,
                              text=True, capture_output=True, check=check)

    def prepare(self, *args):
        return subprocess.run([sys.executable, str(self.root / 'scripts/prepare-release.py'),
                               *args], cwd=self.root, env=self.env, text=True, capture_output=True)

    def assert_unchanged(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.initial)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())['CFBundleVersion'], '2')
        self.assertEqual(self.git('tag').stdout, '')

    def test_prepares_commit_and_annotated_tag_without_pushing(self):
        result = self.prepare('0.1.2', '--date', '2026-10-12')
        self.assertEqual(result.returncode, 0, result.stderr)
        values = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(values['CFBundleShortVersionString'], '0.1.2')
        self.assertEqual(values['CFBundleVersion'], '3')
        self.assertEqual(values['CFBundleName'], 'Don’t Sleep')
        self.assertIn('## 0.1.2 — 2026-10-12', self.changelog.read_text())
        self.assertIn('версия `0.1.2`, сборка `3`', self.changelog.read_text())
        self.assertIn('## 0.1.0 — исходная локальная версия', self.changelog.read_text())
        self.assertEqual(self.git('cat-file', '-t', 'v0.1.2').stdout.strip(), 'tag')
        self.assertEqual(self.git('rev-parse', 'v0.1.2^{commit}').stdout,
                         self.git('rev-parse', 'HEAD').stdout)
        self.assertEqual(self.git('status', '--porcelain').stdout, '')
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/v0.1.2').stdout, '')
        self.assertIn(self.initial, self.git('ls-remote', 'origin', 'refs/heads/main').stdout)

    def test_can_finalize_version_already_prepared_in_sources(self):
        result = self.prepare('0.1.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())['CFBundleVersion'], '3')

    def test_dry_run_does_not_change_files_commits_or_tags(self):
        before = self.changelog.read_bytes()
        result = self.prepare('0.1.2', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.initial)
        self.assertEqual(self.changelog.read_bytes(), before)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())['CFBundleVersion'], '2')
        self.assertEqual(self.git('tag').stdout, '')

    def test_rejects_invalid_or_older_versions_before_changes(self):
        for version in ['v0.1.2', '01.2.3', '0.1', '0.1.2-beta.1', '0.1.0']:
            with self.subTest(version=version):
                self.assert_unchanged(self.prepare(version))

    def test_rejects_dirty_tree_including_untracked_files(self):
        (self.root / 'user-work.txt').write_text('unfinished work')
        result = self.prepare('0.1.2')
        self.assert_unchanged(result)
        self.assertIn('clean', result.stderr)

    def test_rejects_release_outside_main(self):
        self.git('checkout', '-b', 'feature')
        result = self.prepare('0.1.2')
        self.assert_unchanged(result)
        self.assertIn('main', result.stderr)

    def test_rejects_existing_remote_tag_before_changes(self):
        self.git('tag', 'v0.1.2')
        self.git('push', 'origin', 'v0.1.2')
        self.git('tag', '-d', 'v0.1.2')
        result = self.prepare('0.1.2')
        self.assert_unchanged(result)
        self.assertIn('already exists', result.stderr)

    def test_rejects_unreachable_origin_before_changes(self):
        self.git('remote', 'set-url', 'origin', str(Path(self.tmp.name) / 'missing.git'))
        result = self.prepare('0.1.2')
        self.assert_unchanged(result)
        self.assertIn('ls-remote', result.stderr)

    def test_rejects_already_dated_release_notes(self):
        self.changelog.write_text('# История изменений\n\n## 0.1.1 — 2026-10-11\n')
        self.git('add', 'CHANGELOG.md')
        self.git('commit', '-m', 'No pending notes')
        self.initial = self.git('rev-parse', 'HEAD').stdout.strip()
        result = self.prepare('0.1.2')
        self.assert_unchanged(result)
        self.assertIn('готовится', result.stderr)


    def test_rejects_empty_pending_release_notes(self):
        self.changelog.write_text('# История изменений\n\n## 0.1.1 — готовится\n\n')
        self.git('add', 'CHANGELOG.md')
        self.git('commit', '-m', 'Empty pending notes')
        self.initial = self.git('rev-parse', 'HEAD').stdout.strip()
        result = self.prepare('0.1.2')
        self.assert_unchanged(result)
        self.assertIn('Add release notes', result.stderr)

    def test_rejects_remote_ahead_of_local_main(self):
        self.git('commit', '--allow-empty', '-m', 'Remote advance')
        self.git('push', 'origin', 'main')
        self.git('reset', '--hard', self.initial)
        result = self.prepare('0.1.2')
        self.assert_unchanged(result)
        self.assertIn('current origin/main', result.stderr)

    def test_allows_local_commits_ahead_of_origin(self):
        self.git('commit', '--allow-empty', '-m', 'Local change')
        result = self.prepare('0.1.2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.initial, self.git('ls-remote', 'origin', 'refs/heads/main').stdout)

    def test_rejects_existing_local_tag(self):
        self.git('tag', 'v0.1.2')
        result = self.prepare('0.1.2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists locally', result.stderr)
        self.assertEqual(self.git('status', '--porcelain').stdout, '')
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.initial)

    def test_failed_commit_reports_partial_state_without_tag_or_push(self):
        hook = self.root / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        result = self.prepare('0.1.2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('local changes or a commit may remain', result.stderr)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.initial)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())['CFBundleVersion'], '3')
        self.assertEqual(self.git('tag').stdout, '')
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/v0.1.2').stdout, '')

    def test_failed_tag_reports_commit_left_locally_without_push(self):
        self.git('config', 'tag.gpgsign', 'true')
        self.git('config', 'gpg.program', str(self.root / 'missing-gpg'))
        result = self.prepare('0.1.2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('local changes or a commit may remain', result.stderr)
        self.assertNotEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.initial)
        self.assertEqual(self.git('status', '--porcelain').stdout, '')
        self.assertEqual(self.git('tag').stdout, '')
        self.assertIn(self.initial, self.git('ls-remote', 'origin', 'refs/heads/main').stdout)

if __name__ == '__main__':
    unittest.main()
