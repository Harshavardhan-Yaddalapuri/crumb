#!/bin/bash
# Render every pose (and a walk frame) to PNGs, without needing Screen Recording permission.
#   scripts/snapshot-poses.sh [out-dir]     # default: build/poses
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-build/poses}
app=$(scripts/make-app.sh | tail -1)
rm -rf "$out"
CRUMB_SNAPSHOT="$PWD/$out" "$app/Contents/MacOS/Crumb"
ls "$out"
