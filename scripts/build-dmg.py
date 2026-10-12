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


def render_assets(stage):
    assets = stage / 'artwork'
    assets.mkdir()
    renderer = assets / 'render-dmg'
    run('/usr/bin/xcrun', 'swiftc', ROOT / 'scripts/render-dmg.swift', '-o', renderer)
    run(renderer, ROOT, assets)
    run('/usr/bin/tiffutil', '-cathidpicheck', assets / 'background.png',
        assets / 'background@2x.png', '-out', assets / 'background.tiff')
    return assets


def configure_design(mount, assets):
    from dmg_layout import configure
    configure(mount, assets)
    run(assets / 'render-dmg', '--set-icon', assets / 'Readme.icns', mount / 'Установка.txt')


def verify_design(mount, assets):
    from dmg_layout import verify, finder_info
    verify(mount, assets)
    if not int.from_bytes(finder_info(mount / 'Установка.txt')[8:10], 'big') & 0x0400:
        raise ValueError('DMG TXT custom icon flag is missing.')
    if not (mount / 'Установка.txt/..namedfork/rsrc').read_bytes():
        raise ValueError('DMG TXT icon resource is missing.')


def build(app, output):
    app = app.resolve()
    version, _ = verify_app(ROOT, app)
    verify_bundle(app)
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.dmg-build.', dir=output))
    mount = stage / 'mounted'
    try:
        assets = render_assets(stage)
        payload = stage / 'payload'
        payload.mkdir()
        run('/usr/bin/ditto', app, payload / 'Don’t Sleep.app')
        (payload / 'Applications').symlink_to('/Applications')
        instructions = ROOT / 'docs/installation.txt'
        shutil.copyfile(instructions, payload / 'Установка.txt')
        # Layout aliases must be created on the final HFS+ filesystem, not on APFS staging.
        writable = stage / 'writable.dmg'
        run('/usr/bin/hdiutil', 'create', '-srcfolder', payload, '-volname',
            'Don’t Sleep ' + version, '-fs', 'HFS+', '-format', 'UDRW', '-size',
            str(sum(p.stat().st_size for p in payload.rglob('*') if p.is_file()) // (1024 * 1024) + 32) + 'm',
            writable)
        mount.mkdir()
        run('/usr/bin/hdiutil', 'attach', '-nobrowse', '-noautoopen', '-mountpoint', mount, writable)
        configure_design(mount, assets)
        verify_design(mount, assets)
        run('/usr/bin/hdiutil', 'detach', mount)
        image = stage / NAME
        run('/usr/bin/hdiutil', 'convert', writable, '-format', 'UDZO', '-o', image)
        run('/usr/bin/hdiutil', 'verify', image)
        run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
            '-mountpoint', mount, image)
        if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications':
            raise ValueError('DMG does not contain the Applications link.')
        if (mount / 'Установка.txt').read_bytes() != instructions.read_bytes():
            raise ValueError('DMG installation instructions differ from source.')
        verify_design(mount, assets)
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
        shutil.copyfile(assets / 'layout-preview.png', output / 'layout-preview.png')
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
    # Keep the historical ./scripts/build-dmg.py entry point after one-time setup.
    try:
        import ds_store  # noqa: F401
        import mac_alias  # noqa: F401
    except ImportError:
        python = ROOT / '.build/dmg-tools/bin/python3'
        if python.exists() and str(python.parent.parent) != sys.prefix:
            os.execv(str(python), [str(python), str(Path(__file__).resolve())] + sys.argv[1:])
        print('Run ./scripts/setup-dmg-tools.sh before packaging the DMG.', file=sys.stderr)
        return 1
    try:
        build(args.app, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('DMG build failed: {}'.format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
