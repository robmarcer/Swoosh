#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
APP="$PWD/build/Swoosh.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' resources/Info.plist)
ARCHIVE="Swoosh-$VERSION-macos-arm64.zip"
test "$(lipo -archs "$APP/Contents/MacOS/Swoosh")" = "arm64"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$PWD/build/$ARCHIVE"
(cd build && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt)
echo "$PWD/build/$ARCHIVE"
