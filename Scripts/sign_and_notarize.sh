#!/usr/bin/env bash
#
# Signs ScreenSwap.app with a Developer ID, notarizes it, and staples the ticket.
#
# Required environment:
#   DEVELOPER_ID   e.g. "Developer ID Application: Jane Doe (ABCDE12345)"
#   KEYCHAIN_PROFILE  a notarytool profile created once with:
#       xcrun notarytool store-credentials "screenswap" \
#           --apple-id "you@example.com" --team-id ABCDE12345 --password <app-specific-password>
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: ..." KEYCHAIN_PROFILE=screenswap ./Scripts/sign_and_notarize.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ScreenSwap"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME-notarize.zip"

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your \"Developer ID Application: ...\" identity}"
: "${KEYCHAIN_PROFILE:?Set KEYCHAIN_PROFILE to your notarytool keychain profile name}"

if [ ! -d "$APP" ]; then
	echo "==> $APP not found; building it first"
	UNIVERSAL=1 "$ROOT/Scripts/build_app.sh"
fi

echo "==> Signing with: $DEVELOPER_ID"
# --options runtime enables the hardened runtime, which notarization requires.
# --timestamp embeds a secure timestamp, likewise required.
#
# Deliberately no --deep: Apple advises against it, since it walks nested code in
# an unspecified order and can sign things with the wrong flags. The bundle has no
# nested frameworks or helpers to sign today, so this is a single top-level sign;
# if a framework or XPC service is added later, sign it explicitly, innermost first.
codesign --force \
	--options runtime \
	--timestamp \
	--sign "$DEVELOPER_ID" \
	"$APP"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"
# Gatekeeper's own check. Before stapling this reports "rejected ... no usable
# ticket", which is expected at this point.
spctl --assess --type execute --verbose=4 "$APP" || true

echo "==> Creating notarization archive"
rm -f "$ZIP"
# ditto (not zip) preserves the bundle's symlinks and extended attributes.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple (this can take a few minutes)"
xcrun notarytool submit "$ZIP" \
	--keychain-profile "$KEYCHAIN_PROFILE" \
	--wait

echo "==> Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Final Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

rm -f "$ZIP"
echo
echo "Signed and notarized: $APP"
