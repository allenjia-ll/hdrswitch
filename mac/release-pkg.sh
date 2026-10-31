#!/usr/bin/env bash
# Build the installer: dist/hdrswitch-<version>-macos-arm64.pkg (at the repo root), with its SHA-256.
# It installs HDR Switch.app in /Applications and, if chosen on the setup screen, hdrctl: the binary and
# monitor_db.json in /usr/local/lib/hdrswitch (hdrctl finds the database beside its real path), with a
# link in /usr/local/bin. The package isn't signed: that needs an Apple Developer ID.
# Usage: mac/release-pkg.sh <version>    e.g. mac/release-pkg.sh 0.3.1
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: mac/release-pkg.sh <version>}"
VERSION="${VERSION#v}"
NAME="hdrswitch-$VERSION-macos-arm64"
ROOT=".."
DIST="$ROOT/dist"
WORK="$DIST/$NAME-pkg"

grep -q "^## \[$VERSION\]" "$ROOT/CHANGELOG.md" || { echo "CHANGELOG.md has no [$VERSION] section" >&2; exit 1; }

./build.sh
app/build.sh
APP="app/build/HDR Switch.app"
# The version Finder shows. Changing Info.plist breaks the signature, so sign again.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

rm -rf "$WORK" "$DIST/$NAME.pkg"
mkdir -p "$WORK/app" "$WORK/cli/usr/local/lib/hdrswitch" "$WORK/cli/usr/local/bin" "$WORK/resources"
ditto "$APP" "$WORK/app/HDR Switch.app"
cp hdrctl "$WORK/cli/usr/local/lib/hdrswitch/hdrctl"
cp "$ROOT/monitor_db.json" "$WORK/cli/usr/local/lib/hdrswitch/monitor_db.json"
ln -s ../lib/hdrswitch/hdrctl "$WORK/cli/usr/local/bin/hdrctl"

# Not relocatable: otherwise the installer updates any copy it finds, such as a build folder. Not
# version checked: CFBundleVersion stays at 1, so an upgrade could be skipped.
pkgbuild --analyze --root "$WORK/app" "$WORK/app.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool false "$WORK/app.plist"
plutil -replace 0.BundleIsVersionChecked -bool false "$WORK/app.plist"
pkgbuild --root "$WORK/app" --component-plist "$WORK/app.plist" --install-location /Applications \
  --scripts pkg/scripts --identifier io.github.allenjia-ll.hdrswitch.app --version "$VERSION" "$WORK/app.pkg" >/dev/null
pkgbuild --root "$WORK/cli" --install-location / \
  --identifier io.github.allenjia-ll.hdrswitch.cli --version "$VERSION" "$WORK/cli.pkg" >/dev/null

cp pkg/resources/* "$WORK/resources/"
cp "$ROOT/LICENSE" "$WORK/resources/LICENSE.txt"
sed "s/@VERSION@/$VERSION/g" pkg/distribution.xml > "$WORK/distribution.xml"
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$DIST/$NAME.pkg" >/dev/null
rm -rf "$WORK"
(cd "$DIST" && shasum -a 256 "$NAME.pkg" > "$NAME.pkg.sha256")

echo "Built dist/$NAME.pkg"
cat "$DIST/$NAME.pkg.sha256"
