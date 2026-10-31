#!/bin/sh
# Removes HDR Switch.app and hdrctl if the installer installed it. With --delete-data, also the
# logged-in user's settings and detected monitors. Settings > Uninstall HDR Switch… runs this; from
# Terminal: sudo "/Applications/HDR Switch.app/Contents/Resources/uninstall.sh" [--delete-data]
# Only these fixed paths are removed.

case "${1:-}" in
    "") delete_data=no ;;
    --delete-data) delete_data=yes ;;
    *) echo "usage: uninstall.sh [--delete-data]" >&2; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo "error: run this with sudo" >&2; exit 1; }

if [ "$delete_data" = yes ]; then
    user=${SUDO_USER:-$(stat -f %Su /dev/console)}
    home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        echo "error: can't find the home folder of $user; nothing was removed" >&2
        exit 1
    fi
    rm -rf "$home/Library/Application Support/HDR Switch"
fi

# Only the link the installer made: one of your own, such as to a build folder, stays.
if [ "$(readlink /usr/local/bin/hdrctl 2>/dev/null)" = "../lib/hdrswitch/hdrctl" ]; then
    rm -f /usr/local/bin/hdrctl
fi
rm -rf /usr/local/lib/hdrswitch
pkgutil --forget io.github.allenjia-ll.hdrswitch.cli >/dev/null 2>&1
pkgutil --forget io.github.allenjia-ll.hdrswitch.app >/dev/null 2>&1
rm -rf "/Applications/HDR Switch.app"
pkill -x HDRSwitch   # last: Settings runs this from inside the app
exit 0
