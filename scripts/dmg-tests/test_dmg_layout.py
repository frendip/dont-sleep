"""Exercise real Finder metadata on a temporary HFS+ image, without launching Finder."""
import subprocess
import shutil
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ds_store import DSStore
import dmg_layout


class LayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Alias v2 uses HFS+ catalog IDs; APFS IDs can exceed 32 bits.
        cls.disk = Path(tempfile.mkdtemp(prefix='dontsleep-layout-test-'))
        cls.volume = cls.disk / 'volume'
        cls.volume.mkdir()
        try:
            subprocess.run(['/usr/bin/hdiutil', 'create', '-size', '16m', '-fs', 'HFS+',
                            '-volname', 'DMG Layout Test', str(cls.disk / 'test.dmg')],
                           check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['/usr/bin/hdiutil', 'attach', '-nobrowse', '-noautoopen',
                            '-mountpoint', str(cls.volume), str(cls.disk / 'test.dmg')],
                           check=True, stdout=subprocess.DEVNULL)
        except Exception:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        import os
        if os.path.ismount(cls.volume):
            # If detach fails, do not delete files in a live mount.
            subprocess.run(['/usr/bin/hdiutil', 'detach', str(cls.volume)], check=True,
                           stdout=subprocess.DEVNULL)
        shutil.rmtree(cls.disk)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=self.volume)
        self.addCleanup(self.tmp.cleanup)
        self.mount = Path(self.tmp.name) / 'mounted volume'
        self.mount.mkdir()
        self.assets = Path(self.tmp.name) / 'assets'
        self.assets.mkdir()
        for name in ('background.tiff', 'VolumeIcon.icns'):
            (self.assets / name).write_bytes(name.encode())
        (self.mount / 'Установка.txt').write_text('Инструкция', encoding='utf8')

    def prepare(self):
        dmg_layout.configure(self.mount, self.assets)

    def test_layout_preserves_reverse_drag_direction_and_separate_document(self):
        self.prepare()
        dmg_layout.verify(self.mount, self.assets)
        with DSStore.open(str(self.mount / '.DS_Store'), 'r') as ds:
            self.assertEqual(ds['Applications']['Iloc'], (220, 190))
            self.assertEqual(ds['Don’t Sleep.app']['Iloc'], (500, 190))
            self.assertEqual(ds['Установка.txt']['Iloc'], (360, 350))
            self.assertFalse(ds['.']['bwsp']['ShowToolbar'])
            self.assertEqual(ds['.']['icvp']['arrangeBy'], 'none')
            self.assertFalse(ds['.']['icvp']['showIconPreview'])
            # Finder expects the complete color triplet even for a picture background.
            for channel in ('Red', 'Green', 'Blue'):
                self.assertEqual(ds['.']['icvp']['backgroundColor' + channel], 1.0)

    def test_modified_icon_position_is_rejected(self):
        self.prepare()
        with DSStore.open(str(self.mount / '.DS_Store'), 'r+') as ds:
            ds['Applications']['Iloc'] = (500, 190)
        with self.assertRaisesRegex(ValueError, 'position'):
            dmg_layout.verify(self.mount, self.assets)

    def test_missing_or_changed_background_and_icon_are_rejected(self):
        for filename in ('.background.tiff', '.VolumeIcon.icns'):
            with self.subTest(filename=filename):
                self.prepare()
                (self.mount / filename).write_bytes(b'corrupted')
                with self.assertRaisesRegex(ValueError, 'asset'):
                    dmg_layout.verify(self.mount, self.assets)

    def test_missing_custom_volume_icon_flag_is_rejected(self):
        self.prepare()
        subprocess.run(['/usr/bin/xattr', '-d', 'com.apple.FinderInfo', str(self.mount)], check=True)
        with self.assertRaisesRegex(ValueError, 'icon flag'):
            dmg_layout.verify(self.mount, self.assets)

    def test_background_reference_must_still_point_inside_image(self):
        self.prepare()
        with DSStore.open(str(self.mount / '.DS_Store'), 'r+') as ds:
            settings = ds['.']['icvp']
            settings['backgroundImageAlias'] = b'broken'
            ds['.']['icvp'] = settings
        with self.assertRaisesRegex(ValueError, 'background alias'):
            dmg_layout.verify(self.mount, self.assets)


if __name__ == '__main__':
    unittest.main()
