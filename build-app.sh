#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
python3 Tools/sync-release.py
for PRODUCT in CloudMount CloudMountHelper CloudMountVaultHelper; do
    swift build -c release --triple arm64-apple-macosx26.0 --product "$PRODUCT" --jobs 4
done
BUILD_BIN_DIR=$(swift build -c release --triple arm64-apple-macosx26.0 --show-bin-path)
APP_PATH="$PWD/CloudMount.app"
# This path is the generated build product, never the installed application.
rm -rf -- "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources"
cp "$BUILD_BIN_DIR/CloudMount" "$APP_PATH/Contents/MacOS/CloudMount"
cp "$BUILD_BIN_DIR/CloudMountHelper" "$APP_PATH/Contents/Helpers/CloudMountHelper"
cp "$BUILD_BIN_DIR/CloudMountVaultHelper" "$APP_PATH/Contents/Helpers/CloudMountVaultHelper"
cp -R "$BUILD_BIN_DIR/CloudMount_CloudMountVaultCore.bundle" "$APP_PATH/Contents/Resources/"
# The standalone helper's Bundle.main looks beside its executable.
cp -R "$BUILD_BIN_DIR/CloudMount_CloudMountVaultCore.bundle" "$APP_PATH/Contents/Helpers/"
[[ -x Resources/CloudMountRclone ]] || { echo 'Build the compatible engine with Engine/build-engine.py first.' >&2; exit 1; }
cp Resources/CloudMountRclone "$APP_PATH/Contents/Helpers/CloudMountRclone"
chmod +x "$APP_PATH/Contents/Helpers/CloudMountRclone"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
cp Resources/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp -R Resources/*.lproj "$APP_PATH/Contents/Resources/"
mkdir -p "$APP_PATH/Contents/Resources/Licenses"
cp Vendor/CryptomatorCryptoLib/LICENSE.txt "$APP_PATH/Contents/Resources/Licenses/CryptomatorCryptoLib-AGPL.txt"
cp Vendor/CRYPTOMATOR-DESKTOP-LICENSE.txt "$APP_PATH/Contents/Resources/Licenses/CryptomatorDesktop-GPL.txt"
cp Vendor/LICENSING.md Vendor/upstream.json "$APP_PATH/Contents/Resources/Licenses/"
python3 Engine/check-portability.py "$APP_PATH" --remove-build-rpaths
# Only opt into a named Developer ID when the owner authorizes that identity.
SIGNING_FLAGS=(--force --sign "${SIGNING_IDENTITY:--}" --options runtime)
if [[ "${SIGNING_IDENTITY:--}" != '-' ]]; then SIGNING_FLAGS+=(--timestamp); fi
for RESOURCE_BUNDLE in "$APP_PATH/Contents/Resources/CloudMount_CloudMountVaultCore.bundle" "$APP_PATH/Contents/Helpers/CloudMount_CloudMountVaultCore.bundle"; do
    codesign "${SIGNING_FLAGS[@]}" "$RESOURCE_BUNDLE"
done
# rclone alone needs to load the separately installed vendor-signed macFUSE.
codesign "${SIGNING_FLAGS[@]}" --identifier com.codex.cloudmount.rclone --entitlements Resources/Rclone.entitlements "$APP_PATH/Contents/Helpers/CloudMountRclone"
codesign "${SIGNING_FLAGS[@]}" --identifier com.codex.cloudmount.helper "$APP_PATH/Contents/Helpers/CloudMountHelper"
codesign "${SIGNING_FLAGS[@]}" --identifier com.codex.cloudmount.vault-helper "$APP_PATH/Contents/Helpers/CloudMountVaultHelper"
codesign "${SIGNING_FLAGS[@]}" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
python3 Engine/check-portability.py "$APP_PATH"
echo "$APP_PATH"
