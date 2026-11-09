#!/bin/bash
# Build build/Crumb.app from the Swift package and sign it ad hoc with the Hardened Runtime.
#   scripts/make-app.sh            # debug build for this Mac, for development
#   scripts/make-app.sh release    # optimised universal build (Apple Silicon + Intel), zipped for sharing
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-debug}
arch=()
[ "$config" = release ] && arch=(--arch arm64 --arch x86_64)
swift build -c "$config" ${arch[@]+"${arch[@]}"} --product Crumb
bin=$(swift build -c "$config" ${arch[@]+"${arch[@]}"} --show-bin-path)
app=build/Crumb.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Crumb" "$app/Contents/MacOS/Crumb"
cp art/crumb.usdz "$app/Contents/Resources/"
cp scripts/Info.plist "$app/Contents/Info.plist"
# Hardened Runtime: other processes can't inject code into Crumb to borrow its Finder permission.
codesign --force --options runtime --entitlements scripts/Crumb.entitlements --sign - "$app"
if [ "$config" = release ]; then
    zip=build/Crumb.zip  # fixed name: install.sh downloads releases/latest/download/Crumb.zip
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"  # ditto keeps the signature and bundle metadata intact
    echo "$zip"
fi
echo "$app"
