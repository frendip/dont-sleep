"""Headless Finder layout. Called only on a private, mounted build image."""
import subprocess
import shutil
from ds_store import DSStore
from mac_alias import Alias

WINDOW = (720, 460)
POSITIONS = {'Applications': (220, 190), 'Don’t Sleep.app': (500, 190),
             'Установка.txt': (360, 350)}
ASSETS = {'.background.tiff': 'background.tiff', '.VolumeIcon.icns': 'VolumeIcon.icns'}


def finder_info(path):
    result = subprocess.run(["/usr/bin/xattr", "-px", "com.apple.FinderInfo", str(path)],
                            capture_output=True, text=True)
    return bytes.fromhex(result.stdout) if result.returncode == 0 else bytes(32)


def configure(mount, assets):
    for target, source in ASSETS.items():
        shutil.copyfile(assets / source, mount / target)
    # kHasCustomIcon in the volume's FinderInfo, preserving unrelated flags.
    finder = bytearray(finder_info(mount))
    flags = int.from_bytes(finder[8:10], 'big') | 0x0400
    finder[8:10] = flags.to_bytes(2, 'big')
    subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', finder.hex(),
                    str(mount)], check=True)
    background = Alias.for_file(str(mount / '.background.tiff'))
    with DSStore.open(str(mount / '.DS_Store'), 'w+') as ds:
        ds['.']['vSrn'] = ('long', 1)
        ds['.']['icvl'] = ('type', b'icnv')
        ds['.']['bwsp'] = {
            'WindowBounds': '{{160, 120}, {720, 460}}',
            'ShowToolbar': False, 'ShowStatusBar': False, 'ShowSidebar': False,
            'ShowPathbar': False, 'ShowTabView': False, 'SidebarWidth': 0,
            'ContainerShowSidebar': False, 'PreviewPaneVisibility': False,
        }
        ds['.']['icvp'] = {
            'viewOptionsVersion': 1, 'backgroundType': 2,
            # Finder rejects incomplete icon-view dictionaries, even for picture backgrounds.
            'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
            'backgroundImageAlias': background.to_bytes(),
            'iconSize': 112.0, 'textSize': 14.0, 'labelOnBottom': True,
            'arrangeBy': 'none', 'showIconPreview': False, 'showItemInfo': False,
            'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'gridSpacing': 100.0,
            'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        }
        for name, position in POSITIONS.items():
            ds[name]['Iloc'] = position


def verify(mount, assets):
    for target, source in ASSETS.items():
        if not (mount / target).is_file() or (mount / target).read_bytes() != (assets / source).read_bytes():
            raise ValueError('DMG design asset differs: ' + target)
    finder = finder_info(mount)
    if not int.from_bytes(finder[8:10], 'big') & 0x0400:
        raise ValueError('DMG custom volume icon flag is missing.')
    with DSStore.open(str(mount / '.DS_Store'), 'r') as ds:
        for name, position in POSITIONS.items():
            if ds[name]['Iloc'] != position:
                raise ValueError('DMG icon position differs: ' + name)
        window = ds['.']['bwsp']
        settings = ds['.']['icvp']
        if (window['WindowBounds'] != '{{160, 120}, {720, 460}}'
                or any(window[k] for k in ('ShowToolbar', 'ShowSidebar', 'ShowStatusBar', 'ShowPathbar'))
                or settings['iconSize'] != 112.0 or settings['arrangeBy'] != 'none'
                or settings['showIconPreview'] or settings['backgroundType'] != 2
                or any(settings.get('backgroundColor' + channel) != 1.0
                       for channel in ('Red', 'Green', 'Blue'))):
            raise ValueError('DMG Finder view settings differ.')
        try:
            alias = Alias.from_bytes(settings['backgroundImageAlias'])
            if (alias.target.filename != '.background.tiff'
                    or alias.target.cnid != (mount / '.background.tiff').stat().st_ino
                    or alias.target.folder_cnid != mount.stat().st_ino):
                raise ValueError('background target changed')
        except Exception as error:
            raise ValueError('DMG background alias is invalid.') from error
