#!/usr/bin/env bash
# Renders Resources/dmg/background.html to a two-resolution background.tiff (660×420 and @2x) for the installer window.
# Uses headless Chrome with a throwaway profile.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/Resources/dmg"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="$(mktemp -d)"
for s in 1 2; do
  "$CHROME" --headless --disable-gpu --hide-scrollbars --user-data-dir="$PROFILE" --force-device-scale-factor=$s \
    --virtual-time-budget=4000 --window-size=660,420 --screenshot="$DIR/bg@${s}x.png" "file://$DIR/background.html" >/dev/null 2>&1
done
rm -rf "$PROFILE"
tiffutil -cathidpicheck "$DIR/bg@1x.png" "$DIR/bg@2x.png" -out "$DIR/background.tiff" >/dev/null && rm -f "$DIR"/bg@?x.png
echo "Rendered $DIR/background.tiff"
