#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/native Sources/Resources
base=https://github.com/aworan01/content-tv-tvos/releases/download/native-v1-4
curl --fail --location --retry 3 "$base/ContentTorrent-tvos-v1.tar.gz" -o build/native/dependency.tar.gz
python3 - <<'PY'
from pathlib import Path
import hashlib, tarfile
path=Path('build/native/dependency.tar.gz')
assert hashlib.sha256(path.read_bytes()).hexdigest()=='22880f877267f028a2790c6aa879019ae3adff9c4e777bbb6b548bf8792c1d13', 'Native dependency checksum mismatch'
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

