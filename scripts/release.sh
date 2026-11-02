#!/bin/sh
# Build a signed, notarised Aside DMG in build/. Usage: scripts/release.sh [--no-notarize]
#
#   ASIDE_RELEASE_IDENTITY  signing identity (default: Developer ID Application: Joshua Ramkissoon (U5D3H6CY73))
#   ASIDE_NOTARY_PROFILE    notarytool keychain profile, made once with:
#                             xcrun notarytool store-credentials <profile> --apple-id … --team-id U5D3H6CY73
#   ASIDE_ARCHS             architectures to build (default: "arm64 x86_64", a universal binary)
#   --no-notarize           stop after building and signing the DMG
set -e
cd "$(dirname "$0")/.."

IDENTITY="${ASIDE_RELEASE_IDENTITY:-Developer ID Application: Joshua Ramkissoon (U5D3H6CY73)}"
ARCHS="${ASIDE_ARCHS:-arm64 x86_64}"
NOTARIZE=1
[ "$1" = "--no-notarize" ] && NOTARIZE=0

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/release/Aside.app
DMG=build/Aside-$VERSION.dmg

echo "Aside $VERSION ($BUILD), $ARCHS"

# 1. Build.
ARCH_FLAGS=""
for a in $ARCHS; do ARCH_FLAGS="$ARCH_FLAGS --arch $a"; done
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/Aside"

# 2. Assemble the bundle.
rm -rf build/release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Aside"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 3. Sign with the hardened runtime and a secure timestamp, as notarisation requires.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 4. A DMG with the app and a shortcut to /Applications.
STAGE=build/release/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Aside" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "Built $DMG"

# 5. Notarise and staple.
if [ "$NOTARIZE" = 0 ]; then
  echo "Skipped notarisation (--no-notarize)."
  exit 0
fi
if [ -z "$ASIDE_NOTARY_PROFILE" ]; then
  echo "Set ASIDE_NOTARY_PROFILE to a notarytool keychain profile, or pass --no-notarize." >&2
  exit 1
fi
xcrun notarytool submit "$DMG" --keychain-profile "$ASIDE_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Notarised $DMG"
