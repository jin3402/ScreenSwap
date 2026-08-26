#!/usr/bin/env bash
#
# Packages dist/ScreenSwap.app into a distributable DMG with an /Applications
# drop target.
#
#   ./Scripts/make_dmg.sh
#
# Sign the app first (Scripts/sign_and_notarize.sh) if the DMG is going to
# anyone else; notarizing the app but not the DMG is fine, but an unsigned app
# inside a DMG will be blocked by Gatekeeper on the receiving machine.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ScreenSwap"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
STAGING="$DIST/dmg-staging"
DMG="$DIST/$APP_NAME.dmg"

if [ ! -d "$APP" ]; then
	echo "error: $APP not found. Run ./Scripts/build_app.sh first." >&2
	exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

echo "==> Staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
/usr/bin/ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
hdiutil create \
	-volname "$APP_NAME" \
	-srcfolder "$STAGING" \
	-ov \
	-format UDZO \
	"$DMG"

rm -rf "$STAGING"

echo "==> Verifying"
hdiutil verify "$DMG"

echo
echo "Created: $DMG"
echo "If the app is signed, notarize the DMG too:"
echo "  xcrun notarytool submit \"$DMG\" --keychain-profile <profile> --wait && xcrun stapler staple \"$DMG\""
