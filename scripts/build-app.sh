#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
APP="$PWD/build/Swoosh.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Swoosh "$APP/Contents/MacOS/Swoosh"
strip -S "$APP/Contents/MacOS/Swoosh"
cp resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/build/Swoosh.iconset"
ICON_HASH=$(shasum -a 256 resources/AppIcon.png | cut -c 1-12)
ICON_FILE="Swoosh-$ICON_HASH.icns"
rm -f "$APP/Contents/Resources/"Swoosh*.icns
iconutil -c icns "$PWD/build/Swoosh.iconset" -o "$APP/Contents/Resources/$ICON_FILE"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $ICON_FILE" "$APP/Contents/Info.plist"
touch "$APP"
codesign --force --sign - "$APP"
echo "$APP"
