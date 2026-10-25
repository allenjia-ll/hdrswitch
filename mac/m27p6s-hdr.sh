#!/usr/bin/env bash
# m27p6s-hdr.sh on|off|toggle|status
#   on   → HDR on  + "Rec. ITU-R BT.2020-1" + local dimming Standard
#   off  → HDR off + "Display P3"           + local dimming Off
#
# To use your own calibrated SDR profile:
#   SDR_PROFILE=~/Library/ColorSync/Profiles/M27P6S.icc ./m27p6s-hdr.sh off
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HDRCTL="$DIR/hdrctl"
command -v hdrctl >/dev/null 2>&1 && [[ ! -x "$HDRCTL" ]] && HDRCTL="$(command -v hdrctl)"
[[ -x "$HDRCTL" ]] || { echo "hdrctl not built yet — run ./build.sh" >&2; exit 1; }

exec "$HDRCTL" \
  --display     "${DISPLAY_NAME:-M27P6S}" \
  --hdr-profile "${HDR_PROFILE:-Rec. ITU-R BT.2020-1}" \
  --sdr-profile "${SDR_PROFILE:-Display P3}" \
  "${@:-status}"
