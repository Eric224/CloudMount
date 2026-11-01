#!/bin/zsh
# Mechanical platform exports from the approved bitmap masters; artwork stays intact.
set -euo pipefail
cd "${0:A:h:h}"
sips -s format png -z 1024 1024 Design/Brand/CloudMount-master.png --out Mobile/Resources/Assets.xcassets/AppIcon.appiconset/icon.png >/dev/null
ICONSET=$(mktemp -d /private/tmp/cloudmount-icons.XXXXXX)/CloudMount.iconset
mkdir -p "$ICONSET"
trap 'rm -rf -- "${ICONSET:h}"' EXIT
for SIZE in 16 32 128 256 512; do
    sips -s format png -z "$SIZE" "$SIZE" Design/Brand/CloudMount-master.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -s format png -z "$DOUBLE" "$DOUBLE" Design/Brand/CloudMount-master.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
