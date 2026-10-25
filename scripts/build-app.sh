#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
APP="$PWD/build/Swoosh.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Swoosh "$APP/Contents/MacOS/Swoosh"
strip -S "$APP/Contents/MacOS/Swoosh"
cp resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"
