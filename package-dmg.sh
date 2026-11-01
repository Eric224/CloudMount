#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
OUTPUT_DIRECTORY="${1:-$PWD/dist}"
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:A}"
APP_PATH="$PWD/CloudMount.app"
codesign --verify --deep --strict "$APP_PATH"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
DMG_PATH="$OUTPUT_DIRECTORY/CloudMount-$VERSION-macOS.dmg"
STAGING_DIRECTORY=$(mktemp -d /private/tmp/cloudmount-dmg.XXXXXX)
trap 'rm -rf -- "$STAGING_DIRECTORY"' EXIT
ditto "$APP_PATH" "$STAGING_DIRECTORY/CloudMount.app"
ln -s /Applications "$STAGING_DIRECTORY/Applications"
hdiutil create -ov -volname "CloudMount $VERSION" -srcfolder "$STAGING_DIRECTORY" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG_PATH"
if [[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != '-' ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
    codesign --verify --strict "$DMG_PATH"
fi
if [[ -n "${CLOUDMOUNT_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$CLOUDMOUNT_NOTARY_PROFILE" --wait --output-format json > "$OUTPUT_DIRECTORY/notarization-$VERSION.json"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Apple notarization was not accepted"' "$OUTPUT_DIRECTORY/notarization-$VERSION.json"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi
hdiutil verify "$DMG_PATH"
cp "$DMG_PATH" "$OUTPUT_DIRECTORY/CloudMount-macOS.dmg"
shasum -a 256 "$DMG_PATH"
