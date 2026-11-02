#!/bin/sh
# Build a local (development) Aside.app into build/. Usage: scripts/build.sh [--install]
#   --install  copies it to ~/Applications and relaunches it.
# Local builds don't auto-update; scripts/release.sh makes the public, notarised, self-updating build.
set -e
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP=build/Aside.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Aside" "$APP/Contents/MacOS/Aside"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Aside" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The build number is the commit count, so every build from a new commit is distinct.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so macOS keeps the Accessibility grant across rebuilds.
# --deep re-signs the embedded Sparkle.framework with our identity (the hardened runtime requires one team).
IDENTITY="${ASIDE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "No Apple Development identity found; signing ad hoc (Accessibility must be re-granted after each build)."
  codesign --force --deep --sign - "$APP"
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
