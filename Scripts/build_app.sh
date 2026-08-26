#!/usr/bin/env bash
#
# Builds ScreenSwap.app into dist/.
#
#   ./Scripts/build_app.sh              # native arch (fast, for development)
#   UNIVERSAL=1 ./Scripts/build_app.sh  # arm64 + x86_64 (for distribution)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ScreenSwap"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building ($([ "${UNIVERSAL:-0}" = "1" ] && echo universal || echo native))"
if [ "${UNIVERSAL:-0}" = "1" ]; then
	swift build -c release --arch arm64 --arch x86_64
	# Universal builds land in a different tree than single-arch ones.
	BINARY="$ROOT/.build/apple/Products/Release/$APP_NAME"
else
	swift build -c release
	BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
fi

if [ ! -f "$BINARY" ]; then
	echo "error: built binary not found at $BINARY" >&2
	exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BINARY" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

# Localizations. SwiftPM ignores Resources/ because it sits outside the target
# path, so the .lproj bundles are installed here and read through Bundle.main.
for lproj in "$ROOT"/Resources/*.lproj; do
	[ -d "$lproj" ] || continue
	cp -R "$lproj" "$RESOURCES/"
done

# Optional icon: drop an AppIcon.icns in Resources/ to have it picked up.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
	cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
	/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist"
fi

printf 'APPL????' > "$CONTENTS/PkgInfo"

# Ad-hoc signature. macOS refuses to persist Accessibility / Screen Recording
# grants for a completely unsigned bundle, so this is not optional even locally.
#
# Caveat: an ad-hoc signature is derived from the binary, so every rebuild looks
# like a new app to TCC and permissions must be re-granted. Use a real Developer
# ID (Scripts/sign_and_notarize.sh) to make grants stick across builds.
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Verifying"
codesign --verify --verbose=2 "$APP"
plutil -lint "$CONTENTS/Info.plist"

echo
echo "Built: $APP"
echo "Run:   open \"$APP\""
