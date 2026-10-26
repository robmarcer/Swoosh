#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGN_IDENTITY="${SWOOSH_SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" != "-" ]; then
  case "$SIGN_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) echo "Use a Developer ID Application identity, or omit SWOOSH_SIGN_IDENTITY for an ad-hoc preview." >&2; exit 1 ;;
  esac
  security find-identity -v -p codesigning | grep -F -- "\"$SIGN_IDENTITY\"" >/dev/null || {
    echo "The requested Developer ID Application identity is unavailable in the keychain." >&2; exit 1;
  }
fi
swift build -c release --arch arm64
APP="$PWD/build/Swoosh.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Swoosh "$APP/Contents/MacOS/Swoosh"
strip -S "$APP/Contents/MacOS/Swoosh"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
swift scripts/make-icon.swift "$PWD/build/Swoosh.iconset"
ICON_HASH=$(shasum -a 256 resources/AppIcon.png | cut -c 1-12)
ICON_FILE="Swoosh-$ICON_HASH.icns"
rm -f "$APP/Contents/Resources/"Swoosh*.icns
iconutil -c icns "$PWD/build/Swoosh.iconset" -o "$APP/Contents/Resources/$ICON_FILE"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $ICON_FILE" "$APP/Contents/Info.plist"
touch "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "$APP"
