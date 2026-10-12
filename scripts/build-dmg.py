#!/usr/bin/python3
"""Package an existing ARM64 app in a verified DMG. Never install services."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from release_metadata import ROOT, verify_app

NAME = 'DontSleep-macos-arm64.dmg'


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def verify_bundle(app):
    run(ROOT / 'scripts/verify-bundle.sh', app)
    for relative in ('MacOS/DontSleepApp', 'Library/LaunchServices/DontSleepController',
                     'Library/LaunchServices/DontSleepWatchdog'):
        binary = app / 'Contents' / relative
        archs = subprocess.check_output(['/usr/bin/lipo', '-archs', str(binary)], text=True).strip()
        if archs != 'arm64':
            raise ValueError('Expected ARM64 binary: {} (got {})'.format(binary, archs))
    run(app / 'Contents/MacOS/DontSleepApp', '--smoke-test')


def build(app, output):
    app = app.resolve()
    version, _ = verify_app(ROOT, app)
    verify_bundle(app)
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.dmg-build.', dir=output))
    mount = stage / 'mounted'
    try:
        payload = stage / 'payload'
        payload.mkdir()
        run('/usr/bin/ditto', app, payload / 'Don’t Sleep.app')
        (payload / 'Applications').symlink_to('/Applications')
        instructions = ROOT / 'docs/installation.txt'
        shutil.copyfile(instructions, payload / 'Установка.txt')
        image = stage / NAME
        run('/usr/bin/hdiutil', 'create', '-srcfolder', payload, '-volname',
            'Don’t Sleep ' + version, '-fs', 'HFS+', '-format', 'UDZO', image)
        run('/usr/bin/hdiutil', 'verify', image)
        mount.mkdir()
        run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
            '-mountpoint', mount, image)
        if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications':
            raise ValueError('DMG does not contain the Applications link.')
        if (mount / 'Установка.txt').read_bytes() != instructions.read_bytes():
            raise ValueError('DMG installation instructions differ from source.')
        packaged_app = mount / 'Don’t Sleep.app'
        verify_app(ROOT, packaged_app)
        verify_bundle(packaged_app)
        run('/usr/bin/hdiutil', 'detach', mount)
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        checksum = stage / 'SHA256SUMS'
        checksum.write_text('{}  {}\n'.format(digest, NAME), encoding='utf-8')
        # Only validated images replace an earlier local build.
        image.replace(output / NAME)
        checksum.replace(output / 'SHA256SUMS')
        print('Built and verified: {}'.format(output / NAME))
        return output / NAME
    finally:
        # Never recursively remove a staging directory while its image is mounted.
        if os.path.ismount(mount):
            try:
                run('/usr/bin/hdiutil', 'detach', mount)
            except subprocess.CalledProcessError:
                print('Cannot detach image; staging directory retained: {}'.format(stage), file=sys.stderr)
                raise
        shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/Don’t Sleep.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/release')
    args = parser.parse_args()
    try:
        build(args.app, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('DMG build failed: {}'.format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
