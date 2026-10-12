#!/usr/bin/python3
"""Validate release metadata and render notes from the selected source tree."""

import argparse
import datetime
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
VERSION = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'


def tag_version(tag):
    if not re.fullmatch('v' + VERSION, tag):
        raise ValueError('Release tag must be vMAJOR.MINOR.PATCH (no prerelease suffix).')
    return tag[1:]


def read_version(plist_path):
    with plist_path.open('rb') as source:
        values = plistlib.load(source)
    version = values.get('CFBundleShortVersionString')
    build = values.get('CFBundleVersion')
    if not isinstance(version, str) or not re.fullmatch(VERSION, version):
        raise ValueError('Invalid CFBundleShortVersionString in {}'.format(plist_path))
    if not isinstance(build, str) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Invalid CFBundleVersion in {}'.format(plist_path))
    return version, build


def verify_app(root, app):
    expected = read_version(root / 'Resources/Info.plist')
    actual = read_version(app / 'Contents/Info.plist')
    if actual != expected:
        raise ValueError('App version/build {} differs from source {}.'.format(actual, expected))
    return actual


def release_notes(root, tag):
    version = tag_version(tag)
    actual, build = read_version(root / 'Resources/Info.plist')
    if version != actual:
        raise ValueError('Tag {} does not match Info.plist version {}.'.format(tag, actual))
    changelog = (root / 'CHANGELOG.md').read_text(encoding='utf-8')
    headings = list(re.finditer(r'^## (.+)$', changelog, re.MULTILINE))
    expected = re.escape(version) + r' — (\d{4}-\d{2}-\d{2})'
    heading = re.fullmatch(expected, headings[0][1]) if headings else None
    if not heading:
        raise ValueError('First changelog section must be {} with a preparation date; '
                         'finalize the «готовится» section before tagging.'.format(version))
    datetime.date.fromisoformat(heading[1])
    end = headings[1].start() if len(headings) > 1 else len(changelog)
    changes = changelog[headings[0].end():end].strip()
    if not changes:
        raise ValueError('Release notes are empty.')
    instructions = (root / 'docs/installation.txt').read_text(encoding='utf-8').strip()
    if not instructions:
        raise ValueError('First launch instructions are empty.')
    return ('# Don’t Sleep {}\n\nСборка {}. Только Apple Silicon (ARM64).\n\n'
            '**Локальная ad-hoc подпись; без Developer ID и нотарификации Apple.**\n\n'
            '{}\n\n---\n\n{}\n').format(version, build, changes, instructions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('--app', type=Path)
    parser.add_argument('--notes-output', type=Path)
    args = parser.parse_args()
    try:
        notes = release_notes(ROOT, args.tag)
        if args.app:
            verify_app(ROOT, args.app.resolve())
        if args.notes_output:
            args.notes_output.parent.mkdir(parents=True, exist_ok=True)
            args.notes_output.write_text(notes, encoding='utf-8')
        print('Release metadata verified: {}'.format(args.tag))
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        print('Error: {}'.format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
