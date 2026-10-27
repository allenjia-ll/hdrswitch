#!/usr/bin/env bash
# Build the menu bar app and package it: dist/hdrswitch-<version>-macos-arm64.dmg (at the repo root),
# with its SHA-256. Opening the DMG shows HDR Switch.app next to an Applications shortcut to drag it
# onto. The CLI zip is separate (mac/release.sh).
# Usage: mac/app/release.sh <version>    e.g. mac/app/release.sh 0.2.1
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: mac/app/release.sh <version>}"
VERSION="${VERSION#v}"
NAME="hdrswitch-$VERSION-macos-arm64"
ROOT="../.."
DIST="$ROOT/dist"
APP="build/HDR Switch.app"
STAGE="$DIST/$NAME-dmg"

grep -q "^## \[$VERSION\]" "$ROOT/CHANGELOG.md" || { echo "CHANGELOG.md has no [$VERSION] section" >&2; exit 1; }

./build.sh

# The version Finder shows. Changing Info.plist breaks the signature, so sign again.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

# The release must run on macOS 12+ on Apple Silicon, signed, with the shipped monitor database.
BIN="$APP/Contents/MacOS/HDRSwitch"
[[ "$(lipo -archs "$BIN")" == "arm64" ]] || { echo "the app is not arm64-only" >&2; exit 1; }
minos="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/ {f=1} f && $1=="minos" {print $2; exit}')"
[[ "$minos" == "12.0" ]] || { echo "the app's minimum macOS is $minos, expected 12.0" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "the app's signature doesn't verify" >&2; exit 1; }
[[ -f "$APP/Contents/Resources/monitor_db.json" ]] || { echo "monitor_db.json is missing from the app" >&2; exit 1; }

rm -rf "$STAGE" "$DIST/$NAME.dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/HDR Switch.app"   # ditto keeps the bundle and its signature intact
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "HDR Switch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")

echo "Built dist/$NAME.dmg"
cat "$DIST/$NAME.dmg.sha256"
