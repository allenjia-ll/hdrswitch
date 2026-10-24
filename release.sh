#!/usr/bin/env bash
# Build hdrctl and package a binary release: dist/hdrswitch-<version>-macos-arm64.zip
# Usage: ./release.sh <version>    e.g. ./release.sh 0.1.2
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>}"
VERSION="${VERSION#v}"
NAME="hdrswitch-$VERSION-macos-arm64"
STAGE="dist/$NAME"

grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no [$VERSION] section" >&2; exit 1; }

./build.sh

# The release must run on macOS 12+ on Apple Silicon.
[[ "$(lipo -archs hdrctl)" == "arm64" ]] || { echo "hdrctl is not arm64-only" >&2; exit 1; }
minos="$(otool -l hdrctl | awk '/LC_BUILD_VERSION/ {f=1} f && $1=="minos" {print $2; exit}')"
[[ "$minos" == "12.0" ]] || { echo "hdrctl minimum macOS is $minos, expected 12.0" >&2; exit 1; }

rm -rf "$STAGE" "dist/$NAME.zip"
mkdir -p "$STAGE"
cp hdrctl m27p6s-hdr.sh monitor_db.json README.md CHANGELOG.md LICENSE "$STAGE/"
chmod 755 "$STAGE/hdrctl" "$STAGE/m27p6s-hdr.sh"

# ditto keeps permissions and the code signature; --norsrc leaves out macOS metadata.
ditto -c -k --norsrc --keepParent "$STAGE" "dist/$NAME.zip"
(cd dist && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")

echo "Built dist/$NAME.zip"
cat "dist/$NAME.zip.sha256"
