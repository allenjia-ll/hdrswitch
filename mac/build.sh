#!/usr/bin/env bash
# Build hdrctl. Needs Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools not found. Install with: xcode-select --install" >&2
  exit 1
fi

clang -fobjc-arc -O2 -Wall -mmacosx-version-min=12.0 \
  -framework AppKit -framework ApplicationServices -framework IOKit \
  hdrctl.m core/hdrcore.m -o hdrctl

# hdrctl reads monitor_db.json from its own folder; the repo keeps one copy at the root.
cp ../monitor_db.json monitor_db.json

echo "Built $(pwd)/hdrctl"
echo "Optional: sudo ln -s \"$(pwd)/hdrctl\" /usr/local/bin/hdrctl  (a copy would need monitor_db.json and my_monitor next to it)"
