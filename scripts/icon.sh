#!/bin/sh
# Render the app icon from DevTools.AppIconArt into Resources/AppIcon.icns.
set -e
cd "$(dirname "$0")/.."
swift build
TMP="$(mktemp -d)"
.build/debug/Aside --icon "$TMP/icon.png"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
