#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/native Sources/Resources
base=https://github.com/aworan01/content-tv-tvos/releases/download/native-v1-3
curl --fail --location --retry 3 "$base/ContentTorrent-tvos-v1.tar.gz" -o build/native/dependency.tar.gz
python3 - <<'PY'
from pathlib import Path
import hashlib, tarfile
path=Path('build/native/dependency.tar.gz')
assert hashlib.sha256(path.read_bytes()).hexdigest()=='08c8e231f094370af5d8db5cdd4613ae67d81e6f2fa5cb1f349517d5b525c36e', 'Native dependency checksum mismatch'
expected={'appletvos/libContentTorrent.a','appletvsimulator/libContentTorrent.a'}
with tarfile.open(path) as archive:
    assert {m.name for m in archive}==expected, 'Unexpected native archive content'
    for name in sorted(expected):
        member=archive.getmember(name)
        assert member.isfile() and member.size<100*1024*1024
        output=path.parent/name
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_bytes(archive.extractfile(member).read())
PY
for file in libtorrent-LICENSE.txt boost-LICENSE.txt; do
  curl --fail --location --retry 3 "$base/$file" -o "Sources/Resources/$file"
done
