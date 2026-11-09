#!/bin/bash
# Install or uninstall Crumb with one command.
#   curl -fsSL https://raw.githubusercontent.com/Harshavardhan-Yaddalapuri/crumb/master/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/Harshavardhan-Yaddalapuri/crumb/master/install.sh | bash -s -- uninstall
# CRUMB_ZIP=/path/to/Crumb.zip installs from a local zip instead of the latest GitHub release.
set -euo pipefail

repo=Harshavardhan-Yaddalapuri/crumb
app=/Applications/Crumb.app
bundle=dev.crumb.Crumb
support="$HOME/Library/Application Support/Crumb"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

quit_crumb() {
    if pgrep -xq Crumb; then
        osascript -e "quit app id \"$bundle\"" 2>/dev/null || true
        sleep 1
        pkill -x Crumb 2>/dev/null || true
    fi
}

install() {
    [ "$(uname)" = Darwin ] || fail "Crumb runs on macOS only."
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 15 ] || fail "Crumb needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    if [ -n "${CRUMB_ZIP:-}" ]; then
        cp "$CRUMB_ZIP" "$tmp/Crumb.zip"
    else
        say "Downloading Crumb…"
        # HTTPS only, also across GitHub's redirect to its download server.
        curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "$tmp/Crumb.zip" \
            "https://github.com/$repo/releases/latest/download/Crumb.zip" \
            || fail "couldn't download Crumb from github.com/$repo/releases."
    fi
    ditto -x -k "$tmp/Crumb.zip" "$tmp" || fail "the download isn't a valid zip."
    [ -d "$tmp/Crumb.app" ] || fail "the zip doesn't contain Crumb.app."
    # Refuse anything that isn't an intact, unmodified Crumb build with the Hardened Runtime.
    codesign --verify --strict --deep "$tmp/Crumb.app" 2>/dev/null || fail "Crumb.app's signature is broken; not installing."
    [ "$(defaults read "$tmp/Crumb.app/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$bundle" ] \
        || fail "the zip doesn't contain Crumb; not installing."
    sig=$(codesign -dv "$tmp/Crumb.app" 2>&1 || true)
    [[ "$sig" == *"flags="*"runtime"* ]] || fail "Crumb.app isn't hardened; not installing."

    quit_crumb
    rm -rf "$app"
    mv "$tmp/Crumb.app" "$app" || fail "couldn't write to /Applications."
    xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
    open "$app"
    say "Crumb is installed and running. 🐶"
    echo "When macOS asks whether Crumb may control Finder, click Allow: that's how it moves your Desktop icons."
    echo "Click the puppy for its menu. To uninstall later:"
    echo "  curl -fsSL https://raw.githubusercontent.com/$repo/master/install.sh | bash -s -- uninstall"
}

uninstall() {
    quit_crumb
    # Files still digesting haven't reached the Trash yet. Send them there rather than delete them with the app data.
    if [ -d "$support/Belly" ]; then
        find "$support/Belly" -mindepth 2 -maxdepth 2 -print0 | while IFS= read -r -d '' f; do
            osascript -l JavaScript -e 'function run(a) { ObjC.import("Foundation");
                $.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(a[0]), null, null) }' \
                "$f" >/dev/null && echo "Moved to the Trash: $(basename "$f")"
        done
    fi
    rm -rf "$app" "$support"
    defaults delete "$bundle" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$bundle.plist"
    tccutil reset AppleEvents "$bundle" >/dev/null 2>&1 || true  # forget the Finder permission
    say "Crumb is uninstalled."
}

case "${1:-install}" in
install) install ;;
uninstall) uninstall ;;
*) fail "usage: install.sh [install|uninstall]" ;;
esac
