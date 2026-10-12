#!/usr/bin/python3
"""Prepare a local release commit and annotated tag; never push or publish."""

import argparse
import datetime
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
VERSION = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
FILES = ['Resources/Info.plist', 'CHANGELOG.md']


def git(*args):
    result = subprocess.run(['git', *args], cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise ValueError('git {} failed:\n{}'.format(' '.join(args), result.stderr.strip()))
    return result.stdout.strip()


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(VERSION, value):
        raise ValueError('Version must be MAJOR.MINOR.PATCH, without v or prerelease suffixes.')
    return tuple(int(part) for part in value.split('.'))


def prepare(args):
    requested = version_tuple(args.version)
    tag = 'v' + args.version
    if Path(git('rev-parse', '--show-toplevel')).resolve() != ROOT:
        raise ValueError('Run from a checkout containing this script.')
    if git('branch', '--show-current') != 'main':
        raise ValueError('Release preparation requires the main branch.')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Release preparation requires a clean working tree; commit your work first.')
    if git('tag', '--list', tag):
        raise ValueError('Tag {} already exists locally.'.format(tag))

    # Read-only remote check: do not silently prepare a duplicate release offline.
    remote_refs = git('ls-remote', 'origin', 'refs/heads/main', 'refs/tags/' + tag)
    remote_main = None
    for line in remote_refs.splitlines():
        oid, ref = line.split()
        if ref == 'refs/tags/' + tag:
            raise ValueError('Tag {} already exists on origin.'.format(tag))
        if ref == 'refs/heads/main':
            remote_main = oid
    if not remote_main:
        raise ValueError('origin/main is missing; publish the main branch first.')
    # Local commits ahead of origin are allowed; stale/divergent main is not.
    ancestry = subprocess.run(['git', 'merge-base', '--is-ancestor', remote_main, 'HEAD'],
                              cwd=ROOT, capture_output=True)
    if ancestry.returncode:
        raise ValueError('Local main does not contain current origin/main; fetch and reconcile it first.')

    plist_path = ROOT / FILES[0]
    plist_text = plist_path.read_text(encoding='utf-8')
    values = plistlib.loads(plist_text.encode('utf-8'))
    current = values.get('CFBundleShortVersionString')
    if requested < version_tuple(current):
        raise ValueError('Release version cannot be older than {}.'.format(current))
    build = values.get('CFBundleVersion')
    if not isinstance(build, str) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('CFBundleVersion must be a positive integer.')
    next_build = str(int(build) + 1)

    # Keep the existing plist layout, while requiring exactly one of each key.
    for key, value in [('CFBundleShortVersionString', args.version),
                       ('CFBundleVersion', next_build)]:
        pattern = r'(<key>' + key + r'</key>\s*<string>)[^<]*(</string>)'
        plist_text, count = re.subn(pattern, lambda m: m[1] + value + m[2], plist_text)
        if count != 1:
            raise ValueError('Expected exactly one string value for {}.'.format(key))
    plistlib.loads(plist_text.encode('utf-8'))

    changelog_path = ROOT / FILES[1]
    changelog = changelog_path.read_text(encoding='utf-8')
    headings = list(re.finditer(r'^## .+$', changelog, re.MULTILINE))
    expected = '## {} — готовится'.format(current)
    if not headings or headings[0][0] != expected:
        raise ValueError('First CHANGELOG.md release heading must be {!r}.'.format(expected))
    start = headings[0].end()
    end = headings[1].start() if len(headings) > 1 else len(changelog)
    notes = changelog[start:end]
    if not notes.strip():
        raise ValueError('Add release notes to CHANGELOG.md before preparing a release.')
    notes = re.sub(r'Кандидат: версия `[^`]+`, сборка `[^`]+`\.',
                   'Кандидат: версия `{}`, сборка `{}`.'.format(args.version, next_build), notes)
    date = args.date or datetime.date.today().isoformat()
    datetime.date.fromisoformat(date)
    changelog = (changelog[:headings[0].start()] + '## {} — {}'.format(args.version, date)
                 + notes + changelog[end:])
    # Find identity errors before editing files. Existing signing/hook settings apply.
    git('var', 'GIT_AUTHOR_IDENT')
    git('var', 'GIT_COMMITTER_IDENT')
    print('Prepare {}: version {} → {}, build {} → {}, date {}'.format(
        tag, current, args.version, build, next_build, date), flush=True)
    if args.dry_run:
        print('Dry run: no files, commits or tags changed.')
        return

    plist_path.write_text(plist_text, encoding='utf-8')
    changelog_path.write_text(changelog, encoding='utf-8')
    try:
        git('add', '--', *FILES)
        git('commit', '-m', 'chore: prepare release ' + args.version, '--only', '--', *FILES)
        commit = git('rev-parse', 'HEAD')
        git('tag', '-a', tag, commit, '-m', 'Release ' + args.version)
    except ValueError as error:
        raise ValueError(str(error) + '\nPreparation stopped. Inspect git status/log/tag before retrying; '
                         'local changes or a commit may remain. Nothing was pushed.') from error
    print('Created local commit {} and annotated tag {}.'.format(commit[:12], tag))
    print('Nothing was pushed. To send both (if direct pushes to main are allowed):')
    print('  git push --atomic origin main {}'.format(tag))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version', help='Product version, e.g. 0.1.2 (without v).')
    parser.add_argument('--dry-run', action='store_true', help='Validate and show the plan without changes.')
    parser.add_argument('--date', help='Release preparation date YYYY-MM-DD; defaults to local date.')
    args = parser.parse_args()
    try:
        prepare(args)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        print('Error: {}'.format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
