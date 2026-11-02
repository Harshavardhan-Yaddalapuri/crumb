#!/bin/bash
# FinderBridge spike: can we read and set desktop icon positions, and do they stick?
#   spike/finder_positions.sh view                    # desktop bounds, icon size, arrangement, grid spacing
#   spike/finder_positions.sh list                    # every desktop item: name<TAB>x,y
#   spike/finder_positions.sh move "<name>" <x> <y>   # set one item's position, print it back after 1s
set -euo pipefail

case "${1:-}" in
view)
    osascript -e 'tell application "Finder" to get bounds of window of desktop'
    osascript -e 'tell application "Finder" to get {icon size, arrangement} of icon view options of window of desktop'
    defaults read com.apple.finder DesktopViewSettings 2>/dev/null || echo "(no DesktopViewSettings in com.apple.finder)"
    ;;
list)
    osascript <<'EOF'
tell application "Finder"
    set out to ""
    -- Fetch into a variable first: looping over "every item of desktop" directly runs zero times.
    set desktopItems to every item of desktop
    repeat with i in desktopItems
        set p to desktop position of i
        set out to out & (name of i) & tab & (item 1 of p) & "," & (item 2 of p) & linefeed
    end repeat
    return out
end tell
EOF
    ;;
move)
    [ $# -eq 4 ] || { echo "usage: $0 move \"<name>\" <x> <y>" >&2; exit 2; }
    osascript - "$2" "$3" "$4" <<'EOF'
on run argv
    set {n, x, y} to argv
    tell application "Finder"
        set desktop position of item n of desktop to {x as integer, y as integer}
        delay 1
        return desktop position of item n of desktop
    end tell
end run
EOF
    ;;
*)
    sed -n '2,5p' "$0"
    exit 2
    ;;
esac
