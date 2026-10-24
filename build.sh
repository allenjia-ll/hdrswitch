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
  hdrctl.m -o hdrctl

echo "Built $(pwd)/hdrctl"
echo "Optional: sudo cp hdrctl /usr/local/bin/"
