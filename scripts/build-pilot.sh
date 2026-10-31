#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build dist
if [[ "${CTV_BUILD_NATIVE_SOURCE:-0}" = 1 ]]; then
  bash scripts/build-native.sh
else
  bash scripts/fetch-native.sh
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen before building.' >&2; exit 1; }
{
  xcodebuild -version
  xcodegen --version
  xcodebuild -showsdks
} > build/toolchain.txt
xcodegen generate --spec project.yml

# Use an installed Apple TV simulator rather than hardcoding a simulator UUID.
xcrun simctl list devices available --json > build/simulators.json
simulator="$(python3 - <<'PY'
import json, re
with open('build/simulators.json') as f:
    devices = json.load(f)['devices']
choices = []
for runtime, entries in devices.items():
    if 'tvOS' not in runtime:
        continue
    version = tuple(map(int, re.findall(r'\d+', runtime.split('tvOS')[-1])))
    for device in entries:
        if device.get('isAvailable') and 'Apple TV' in device['name']:
            choices.append((version, '4K' in device['name'], device['udid']))
if not choices:
    raise SystemExit('No installed tvOS simulator: inspect build/simulators.json.')
print(sorted(choices, reverse=True)[0][2])
PY
)"
xcodebuild test -project ContentTV.xcodeproj -scheme ContentTV \
  -configuration Debug -destination "platform=tvOS Simulator,id=$simulator" \
  -derivedDataPath build/simulator -resultBundlePath build/PilotTests.xcresult \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM='' 2>&1 | tee build/tests.log

# Capture the clean simulator UI for visual review; no user sources are installed.
xcrun simctl boot "$simulator" || true
xcrun simctl bootstatus "$simulator" -b
xcrun simctl install "$simulator" build/simulator/Build/Products/Debug-appletvsimulator/ContentTV.app
xcrun simctl launch "$simulator" tv.content.tvos.aworan01
sleep 8
xcrun simctl io "$simulator" screenshot dist/Content-TV-tvOS-preview.png

xcodebuild build -project ContentTV.xcodeproj -scheme ContentTV \
  -configuration Release -sdk appletvos -destination 'generic/platform=tvOS' \
  -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' 2>&1 | tee build/device-build.log

app=build/device/Build/Products/Release-appletvos/ContentTV.app
test -d "$app"
if codesign -dv "$app" >/dev/null 2>&1; then
  echo 'Unexpected signing identity: this build must be unsigned for local re-signing.' >&2
  exit 1
fi
xcrun vtool -show-build "$app/ContentTV" > build/macho-platform.txt
grep -Eq 'platform[[:space:]]+TVOS([[:space:]]|$)' build/macho-platform.txt

stage="$(mktemp -d "${TMPDIR:-/tmp}/contenttv-pilot.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/ContentTV.app"
archive="$PWD/dist/Content-TV-tvOS-0.3.0-unsigned.ipa"
# A fresh stage ensures each IPA contains only this build's application.
(cd "$stage"; COPYFILE_DISABLE=1 /usr/bin/zip -qr "$stage/package.ipa" Payload)
mv -f "$stage/package.ipa" "$archive"
python3 scripts/verify_ipa.py "$archive"
(cd dist; shasum -a 256 Content-TV-tvOS-0.3.0-unsigned.ipa) > dist/SHA256.txt
{
  echo 'Content TV tvOS 0.3.0 — unsigned device build'
  echo "Commit: ${GITHUB_SHA:-local}"
  cat build/toolchain.txt
  cat build/macho-platform.txt
  echo 'Simulator unit tests must pass before packaging.'
  echo 'Physical Apple TV installation and playback require local signing and device testing.'
} > dist/BUILD-INFO.txt

