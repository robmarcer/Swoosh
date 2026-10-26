#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SWOOSH_SIGN_IDENTITY:?Set a Developer ID Application identity in SWOOSH_SIGN_IDENTITY.}"
: "${SWOOSH_NOTARY_PROFILE:?Set an existing notarytool keychain profile in SWOOSH_NOTARY_PROFILE.}"
case "$SWOOSH_SIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *) echo "Notarization requires Developer ID Application signing." >&2; exit 1 ;;
esac
# Validate existing credentials before building or submitting anything.
xcrun notarytool history --keychain-profile "$SWOOSH_NOTARY_PROFILE" >/dev/null
bash scripts/package-release.sh
APP="$PWD/build/Swoosh.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHIVE="$PWD/build/Swoosh-$VERSION-macos-arm64.zip"
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
printf '%s\n' "$SIGNATURE" | grep -F 'Authority=Developer ID Application:' >/dev/null
printf '%s\n' "$SIGNATURE" | grep -E 'flags=.*runtime' >/dev/null
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$SWOOSH_NOTARY_PROFILE" --wait --output-format json > build/notarization-result.json
STATUS=$(/usr/bin/plutil -extract status raw -o - build/notarization-result.json)
if [ "$STATUS" != "Accepted" ]; then
  echo "Notarization was not accepted. Inspect build/notarization-result.json; do not publish this archive." >&2
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# Stapling changes the bundle, so recreate the distribution archive and checksum.
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$ARCHIVE"
(cd build && shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt)
echo "Notarized archive: $ARCHIVE"
