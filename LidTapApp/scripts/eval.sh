#!/bin/bash
# Cross-validates every recogniser on a recorded dataset (default: this Mac's own calibration).
#   scripts/eval.sh [path/to/dataset.json]
set -euo pipefail
cd "$(dirname "$0")/.."
FIX="$(pwd)/scripts/toolchain-fix"
[ -f "$FIX/overlay.yaml" ] || { echo "Run scripts/build.sh once first (it creates the toolchain overlay)"; exit 1; }
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(find Sources Tools/eval -name '*.swift' ! -name 'LidTapApp.swift' -print0)
mkdir -p build
swiftc -O -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 -vfsoverlay "$FIX/overlay.yaml" \
  -framework IOKit -framework CoreAudio -framework CoreMediaIO -framework ServiceManagement -framework Security "${files[@]}" -o build/LidTapEval 2>&1 | grep -E "error:" && exit 1 || true
exec build/LidTapEval "$@"
