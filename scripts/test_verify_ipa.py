import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from verify_ipa import verify


class PackageValidationTests(unittest.TestCase):
    def make(self, folder, platform=3, signed=False, extra=None):
        path = Path(folder) / 'pilot.ipa'
        info = dict(CFBundleIdentifier='tv.content.tvos.aworan01',
                    CFBundleExecutable='ContentTV', CFBundleSupportedPlatforms=['AppleTVOS'])
        binary = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        binary += struct.pack('<6I', 0x32, 24, platform, 0x110000, 0x1A0000, 0)
        with zipfile.ZipFile(path, 'w') as z:
            base = 'Payload/ContentTV.app/'
            z.writestr(base + 'Info.plist', plistlib.dumps(info))
            z.writestr(base + 'ContentTV', binary)
            if signed:
                z.writestr(base + 'embedded.mobileprovision', b'not a real profile')
            if extra:
                z.writestr(extra, b'bad')
        return path

    def test_accepts_device_package(self):
        with tempfile.TemporaryDirectory() as f:
            self.assertEqual(verify(self.make(f))['CFBundleExecutable'], 'ContentTV')

    def test_rejects_simulator_even_when_arm64(self):
        with tempfile.TemporaryDirectory() as f:
            with self.assertRaisesRegex(ValueError, 'physical tvOS'):
                verify(self.make(f, platform=8))

    def test_rejects_profiles(self):
        with tempfile.TemporaryDirectory() as f:
            with self.assertRaisesRegex(ValueError, 'unsigned'):
                verify(self.make(f, signed=True))

    def test_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as f:
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                verify(self.make(f, extra='Payload/../outside'))


if __name__ == '__main__':
    unittest.main()
