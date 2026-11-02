#!/bin/bash
# Build build/Crumb.app from the Swift package and sign it ad hoc.
#   scripts/make-app.sh            # debug build
#   scripts/make-app.sh release
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-debug}
swift build -c "$config" --product Crumb
bin=$(swift build -c "$config" --show-bin-path)
app=build/Crumb.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Crumb" "$app/Contents/MacOS/Crumb"
cp art/crumb.usdz "$app/Contents/Resources/"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$app"
