#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/deps build/native
deps="$PWD/build/deps"
if [[ ! -d "$deps/libtorrent/.git" ]]; then
  git clone --no-checkout https://github.com/arvidn/libtorrent.git "$deps/libtorrent"
  git -C "$deps/libtorrent" checkout --detach 9d7443f467147d1784fb7516d2a882db1abb5a8b
  git -C "$deps/libtorrent" submodule update --init --recursive
fi
test "$(git -C "$deps/libtorrent" rev-parse HEAD)" = 9d7443f467147d1784fb7516d2a882db1abb5a8b
if [[ ! -d "$deps/boost_1_85_0/boost" ]]; then
  curl --fail --location --retry 3 https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2 -o "$deps/boost.tar.bz2"
  echo "7009fe1faa1697476bdc7027703a2badb84e849b7b0baad5086b087b971f8617  $deps/boost.tar.bz2" | shasum -a 256 -c -
  tar -xjf "$deps/boost.tar.bz2" -C "$deps"
fi
for sdk in appletvsimulator appletvos; do
  cmake -S Native -B "build/native/$sdk" -G Ninja \
    -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
    -DCTV_LIBTORRENT="$deps/libtorrent" -DBOOST_ROOT="$deps/boost_1_85_0" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build "build/native/$sdk" --parallel 3 > "build/native-$sdk.log" 2>&1 || { tail -100 "build/native-$sdk.log"; exit 1; }
  /usr/bin/libtool -static -o "build/native/$sdk/libContentTorrent.a" \
    "build/native/$sdk/libCTVNative.a" "build/native/$sdk/libtorrent/libtorrent-rasterbar.a"
done
mkdir -p Sources/Resources
cp "$deps/libtorrent/LICENSE" Sources/Resources/libtorrent-LICENSE.txt
cp "$deps/boost_1_85_0/LICENSE_1_0.txt" Sources/Resources/boost-LICENSE.txt
