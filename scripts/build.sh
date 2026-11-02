#!/bin/sh
# Build Aside.app into build/. Usage: scripts/build.sh [--install]
#   --install  copies it to ~/Applications and relaunches it.
set -e
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Aside"

APP=build/Aside.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Aside"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so macOS keeps the Accessibility grant across rebuilds.
IDENTITY="${ASIDE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "No Apple Development identity found; signing ad hoc (Accessibility must be re-granted after each build)."
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [ "$1" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x Aside 2>/dev/null || true
  rm -rf "$HOME/Applications/Aside.app"
  cp -R "$APP" "$HOME/Applications/Aside.app"
  open "$HOME/Applications/Aside.app"
  echo "Installed to ~/Applications/Aside.app"
fi
