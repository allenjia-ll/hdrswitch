#!/usr/bin/env bash
# Build the menu bar app: mac/app/build/HDR Switch.app. Needs Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools not found. Install with: xcode-select --install" >&2
  exit 1
fi

OUT=build
APP="$OUT/HDR Switch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The shared Objective-C core, then the Swift app linked against it.
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=12.0 -c ../core/hdrcore.m -o "$OUT/hdrcore.o"
swiftc -O -swift-version 5 -target arm64-apple-macos12.0 \
  -import-objc-header HDRSwitch-Bridging-Header.h \
  -framework AppKit -framework ApplicationServices -framework IOKit -framework SwiftUI \
  Sources/*.swift "$OUT/hdrcore.o" -o "$APP/Contents/MacOS/HDRSwitch"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/* "$APP/Contents/Resources/"
cp ../../monitor_db.json "$APP/Contents/Resources/"   # my_monitor.json goes in ~/Library/Application Support/HDR Switch
codesign --force --sign - "$APP"   # ad-hoc, required to run on Apple Silicon

echo "Built $(pwd)/$APP"
echo "Run: open \"$(pwd)/$APP\""
