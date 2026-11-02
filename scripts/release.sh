#!/usr/bin/env bash
# Builds, signs (Developer ID), notarises and staples the public Aside release: build/release/Aside-<version>.dmg,
# with an installer window, Sparkle auto-update and an appcast. Usage:
#   scripts/release.sh             build, sign, notarise; update site/appcast.xml
#   scripts/release.sh --publish   ...then upload to a GitHub release (v<version>) and redeploy the site
# Version comes from Resources/Info.plist (CFBundleShortVersionString); the build number is the git commit count.
# Needs: the "Developer ID Application" cert; a notarytool keychain profile (ASIDE_NOTARY_PROFILE, default
# patch-notary, same Apple developer account as Patch); Sparkle's EdDSA key in the login keychain (account "aside",
# made with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account aside`); uv (for dmgbuild); gh; npx vercel.
# ASIDE_SKIP_NOTARIZE=1 builds everything without notarising (local testing only: Gatekeeper will refuse it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WORK="$ROOT/build/release"
PROFILE="${ASIDE_NOTARY_PROFILE:-patch-notary}"
BUNDLE_ID="com.jkmr.aside"
REPO="joshuaramkissoon/aside"
SITE="https://aside-mac.vercel.app"
PLB=/usr/libexec/PlistBuddy
FEED_URL="$SITE/appcast.xml"
SPARKLE_PUBLIC_KEY="RWZJLW/iNGmPBbaHShy1oR2uPhu1v+ff4ibeWCvjetk="
SPARKLE_ACCOUNT="aside"

VERSION="$($PLB -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(git rev-list --count HEAD)"
SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[[ -n "$SIGN_ID" ]] || { echo "No Developer ID Application identity in the keychain" >&2; exit 1; }

APP="$WORK/Aside.app"
DMG="$WORK/Aside-$VERSION.dmg"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "==> Building universal binary ($VERSION, build $BUILD)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Aside" "$APP/Contents/MacOS/Aside"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Aside" 2>/dev/null || true
PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
$PLB -c "Set :CFBundleVersion $BUILD" "$PLIST"
$PLB -c "Add :SUFeedURL string $FEED_URL" "$PLIST"
$PLB -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$PLIST"
$PLB -c "Add :SUEnableAutomaticChecks bool true" "$PLIST"
$PLB -c "Add :SUAutomaticallyUpdate bool true" "$PLIST"

echo "==> Signing app"
# Inside-out: Sparkle's helpers, then the framework, then the app (no --deep).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$@"; }
sign "$SPK/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
sign "$SPK/Autoupdate"
sign "$SPK/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

notarize() {
  if [[ "${ASIDE_SKIP_NOTARIZE:-}" == "1" ]]; then echo "(skipping notarisation)"; return; fi
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

echo "==> Notarising app"
ditto -c -k --keepParent "$APP" "$WORK/Aside.zip"
notarize "$WORK/Aside.zip"
[[ "${ASIDE_SKIP_NOTARIZE:-}" == "1" ]] || xcrun stapler staple "$APP"

echo "==> Building DMG"
# The installer window: background (Resources/dmg/background.html, rendered by scripts/make_dmg_background.sh),
# icon positions and size, written into the DMG's .DS_Store by dmgbuild (no Finder scripting).
[[ -f Resources/dmg/background.tiff ]] || scripts/make_dmg_background.sh
uvx --quiet dmgbuild -s Resources/dmg/settings.py -D app="$APP" -D bg="$ROOT/Resources/dmg/background.tiff" "Aside" "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

echo "==> Notarising DMG"
notarize "$DMG"
[[ "${ASIDE_SKIP_NOTARIZE:-}" == "1" ]] || xcrun stapler staple "$DMG"

echo "==> Verifying"
if [[ "${ASIDE_SKIP_NOTARIZE:-}" != "1" ]]; then
  spctl -a -vv "$APP"
  spctl -a -vvv -t install "$DMG"
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
fi
# Aside.dmg is the stable "latest" download (the site links to releases/latest/download/Aside.dmg);
# Aside-<version>.dmg is the file the appcast points at.
cp "$DMG" "$WORK/Aside.dmg"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"

echo "==> Appcast"
DMG_URL="https://github.com/$REPO/releases/download/v$VERSION/Aside-$VERSION.dmg"
SIG="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"  # sparkle:edSignature="…" length="…"
python3 scripts/appcast.py site/appcast.xml --version "$BUILD" --short "$VERSION" --url "$DMG_URL" \
  --signature "$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$SIG")" \
  --length "$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIG")" \
  --min-system "$($PLB -c 'Print :LSMinimumSystemVersion' "$PLIST")" \
  --notes "https://github.com/$REPO/releases/tag/v$VERSION"
echo "Appcast: site/appcast.xml (commit it with the release)"

if [[ " $* " == *" --publish "* ]]; then
  [[ "${ASIDE_SKIP_NOTARIZE:-}" != "1" ]] || { echo "Refusing to publish an unnotarised build" >&2; exit 1; }
  echo "==> Publishing v$VERSION to GitHub"
  NOTES="${ASIDE_RELEASE_NOTES:-Aside $VERSION}"
  if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" "$WORK/Aside.dmg" -R "$REPO" --clobber
  else
    gh release create "v$VERSION" "$DMG" "$WORK/Aside.dmg" -R "$REPO" --title "Aside $VERSION" --notes "$NOTES" --latest
  fi
  echo "==> Redeploying the site (appcast)"
  # A fresh checkout isn't linked; link to the existing "aside" project, never create a new one.
  [[ -f site/.vercel/project.json ]] || (cd site && npx --yes vercel link --yes --project aside --scope joshuas-projects-2e196a74 >/dev/null)
  (cd site && npx --yes vercel deploy --prod --yes --scope joshuas-projects-2e196a74 >/dev/null)
  curl -sIL "https://github.com/$REPO/releases/latest/download/Aside.dmg" | grep -iE "^HTTP|content-length" | tail -2 || true
  curl -s "$FEED_URL" | grep -m1 -o "sparkle:shortVersionString>[^<]*" || true
fi
