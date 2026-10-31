#!/bin/sh
# Removes the app this script is in and hdrctl if the installer installed it. With --delete-data, also
# your settings and detected monitors. Settings > Uninstall HDR Switch… runs this; from Terminal:
#   "$HOME/Applications/HDR Switch.app/Contents/Resources/uninstall.sh" [--delete-data]
# Runs as you, without a password. Only these fixed paths are removed.

case "${1:-}" in
    "") delete_data=no ;;
    --delete-data) delete_data=yes ;;
    *) echo "usage: uninstall.sh [--delete-data]" >&2; exit 2 ;;
esac
[ "$(id -u)" != 0 ] || { echo "error: run this without sudo" >&2; exit 1; }
[ -n "$HOME" ] && [ -d "$HOME" ] || { echo "error: can't find your home folder; nothing was removed" >&2; exit 1; }

# The app must be one of the two places it installs to.
app=$(cd "$(dirname "$0")/../.." && pwd -P)   # Contents/Resources is inside the app
case "$app" in
    "/Applications/HDR Switch.app" | "$HOME/Applications/HDR Switch.app") ;;
    *) echo "error: HDR Switch isn't in an Applications folder ($app); nothing was removed" >&2; exit 1 ;;
esac
[ -w "$(dirname "$app")" ] || { echo "error: no permission to remove $app; nothing was removed" >&2; exit 1; }

if [ "$delete_data" = yes ]; then
    rm -rf "$HOME/Library/Application Support/HDR Switch"
fi

# Only the link the installer made: one of your own, such as to a build folder, stays.
if [ "$(readlink "$HOME/.local/bin/hdrctl" 2>/dev/null)" = "../lib/hdrswitch/hdrctl" ]; then
    rm -f "$HOME/.local/bin/hdrctl"
fi
rm -rf "$HOME/.local/lib/hdrswitch"
pkgutil --volume "$HOME" --forget io.github.allenjia-ll.hdrswitch.cli >/dev/null 2>&1
pkgutil --volume "$HOME" --forget io.github.allenjia-ll.hdrswitch.app >/dev/null 2>&1
rm -rf "$app"
# For a run from Terminal; from Settings, the app quits itself too. Only the app that was removed, not
# a build folder's.
pkill -f "^$app/Contents/MacOS/HDRSwitch"
exit 0
