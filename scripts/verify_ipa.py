"""Validate an unsigned arm64 AppleTVOS IPA without needing Apple's SDK."""
import plistlib
import struct
import sys
import zipfile
from pathlib import PurePosixPath


def verify(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        for name in names:
            p = PurePosixPath(name)
            if p.is_absolute() or '..' in p.parts or '\\' in name:
                raise ValueError('Unsafe archive path')
            if not name.startswith('Payload/'):
                raise ValueError('Unexpected content outside Payload')
            if '/_CodeSignature/' in name or name.endswith('/embedded.mobileprovision'):
                raise ValueError('This pilot must be unsigned and contain no profile')
        infos = [n for n in names if n.startswith('Payload/') and n.count('/') == 2
                 and n.endswith('.app/Info.plist')]
        if len(infos) != 1:
            raise ValueError('Expected exactly one application')
        info = plistlib.loads(archive.read(infos[0]))
        if info.get('CFBundleSupportedPlatforms') != ['AppleTVOS']:
            raise ValueError('Not an Apple TV device application')
        if info.get('CFBundleIdentifier') != 'tv.content.tvos.aworan01':
            raise ValueError('Unexpected bundle identifier')
        executable = info.get('CFBundleExecutable', '')
        if not executable or PurePosixPath(executable).name != executable:
            raise ValueError('Invalid executable path')
        base = infos[0].rsplit('/', 1)[0]
        binary = archive.read(base + '/' + executable)
        if len(binary) < 32:
            raise ValueError('Truncated executable')
        magic, cpu, _, _, commands, command_bytes, _, _ = struct.unpack_from('<8I', binary)
        if magic != 0xFEEDFACF or cpu != 0x0100000C:
            raise ValueError('Expected a thin arm64 device executable')
        if 32 + command_bytes > len(binary):
            raise ValueError('Truncated load commands')
        offset = 32
        platform = None
        for _ in range(commands):
            if offset + 8 > 32 + command_bytes:
                raise ValueError('Invalid load command table')
            command, length = struct.unpack_from('<2I', binary, offset)
            if length < 8 or offset + length > 32 + command_bytes:
                raise ValueError('Invalid load command size')
            if command == 0x32 and length >= 24:  # LC_BUILD_VERSION
                platform = struct.unpack_from('<I', binary, offset + 8)[0]
            offset += length
        if platform != 3:  # PLATFORM_TVOS, not PLATFORM_TVOSSIMULATOR (8)
            raise ValueError('Executable is not built for physical tvOS')
        return info


if __name__ == '__main__':
    metadata = verify(sys.argv[1])
    print('Verified unsigned arm64 AppleTVOS IPA:', metadata['CFBundleIdentifier'])
