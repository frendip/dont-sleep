#!/usr/bin/env python3
"""Create a new GitHub Release draft from a verified DMG; never publish or replace."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from release_metadata import tag_version


def gh(*args):
    return subprocess.run(['gh', *args], check=True, text=True, capture_output=True).stdout.strip()


def publish(repository, tag, directory):
    tag_version(tag)
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Expected GitHub repository OWNER/NAME.')
    directory = directory.resolve()
    dmg = directory / 'DontSleep-macos-arm64.dmg'
    checksum = directory / 'SHA256SUMS'
    notes = directory / 'release-notes.md'
    for path in (dmg, checksum, notes):
        if path.is_symlink() or not path.is_file() or not path.stat().st_size:
            raise ValueError('Missing or invalid release asset: {}'.format(path))
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    if checksum.read_text(encoding='utf-8') != '{}  {}\n'.format(digest, dmg.name):
        raise ValueError('DMG checksum mismatch; refusing to create a draft.')
    # A failed lookup must not be treated as "release does not exist".
    pages = json.loads(gh('api', '--paginate', '--slurp',
                         'repos/{}/releases?per_page=100'.format(repository)))
    for page in pages:
        for release in page:
            if release['tag_name'] == tag:
                raise ValueError('Release {} already exists. Nothing was changed. '
                                 'For a failed upload, inspect and delete only the incomplete draft '
                                 'before retrying; never replace a published release.'.format(tag))
    return gh('release', 'create', tag, str(dmg), str(checksum), '--repo', repository,
              '--verify-tag', '--draft', '--title', 'Don’t Sleep ' + tag[1:],
              '--notes-file', str(notes))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('--repo', required=True)
    parser.add_argument('--directory', type=Path, default=Path('dist/release'))
    args = parser.parse_args()
    try:
        print(publish(args.repo, args.tag, args.directory))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        print('Error: {}\nNo public release was requested. A partial draft may remain after '
              'an upload failure; inspect GitHub Releases before retrying.'.format(detail), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
