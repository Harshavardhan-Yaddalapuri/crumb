# FinderBridge Spike — Findings

Date: 2026-11-02  ·  macOS 27.0.1  ·  Display 1920×1080

## Decision

**GO.** Setting a desktop icon's position through Finder Apple Events works, reads back exactly, survives 10 s and `killall Finder`. Plan 2 builds FinderBridge on per-icon positioning; the Sort By fallback isn't needed.

## Results

| Question | Result |
|---|---|
| Set position works (Sort By None) | yes |
| Read-back matches target | yes, exact (`1223, 309` → `1223, 309`) |
| Survives 10 s | yes |
| Survives `killall Finder` | yes |
| Off-grid target snaps | **no**: `1240, 318` stays `1240, 318`. Crumb must compute grid points itself. |
| Per-move latency | 78–90 ms (median 86) via `osascript`, including process launch; in-process `NSAppleScript` should be faster |
| With Sort By = Name | inconclusive: setting `arrangement` via AppleScript didn't rearrange the real desktop, and the move still worked. Plan 2 reads `DesktopViewSettings.IconViewSettings.arrangeBy` and, if it isn't `none`, asks the user before hauling. |
| With Use Stacks | not tested (not scriptable). Plan 2 treats `DesktopViewSettings.GroupBy` ≠ `None` like a sorted desktop. |

## Layout (from `view`)

- Desktop bounds: `0, 0, 1920, 1080`
- Icon view: icon size 64, arrangement "not arranged"
- `DesktopViewSettings.IconViewSettings`: `gridSpacing = 54`, `iconSize = 64`, `textSize = 12`, `labelOnBottom = 1`, `gridOffsetX/Y = 0`
- Positions are icon centers in points from the top-left of the screen (e.g. `1854,182`).

## Grid

Measured with 18 temp files + `clean up window of desktop by name` (1920×1080, icon size 64, gridSpacing 54):

- Column pitch **124 pt**; rightmost column center x = **1854** (66 pt from the right edge)
- Row pitch **112 pt**; top row center y = **70**
- **8 rows** per column (y = 70 … 854)
- Fill order: rightmost column first, top to bottom; matches `GapPlanner`'s `Cell(col: 0, row: 0)` = top-right
- Center of cell = `(1854 − 124·col, 70 + 112·row)` on this setup. Plan 2 should derive pitch from icon size / gridSpacing / text size, or measure it the same way at first launch.

## Gotchas found

1. **Stage Manager with "Show Items" off hides desktop icons from Finder scripting.** `every item of desktop` returns nothing while `com.apple.WindowManager` has `GloballyEnabled = 1` and `HideDesktop = 1`. Crumb must detect this and tell the user ("I can't see your desktop icons") instead of going silent. Spec §4 already pauses hauling in this case.
2. **AppleScript: loop over a variable, not the live query.** `repeat with i in (every item of desktop)` silently ran zero times; `set xs to every item of desktop` then `repeat with i in xs` works.
3. **Automation permission is per calling app.** Terminal was granted here; the Crumb app will trigger its own "wants to control Finder" prompt.
4. The Desktop is synced to iCloud Drive on this Mac (`~/Library/Mobile Documents/com~apple~CloudDocs/Desktop` → `~/Desktop`). Moving files from there into Belly's staging folder is untested; see 5.
5. **iCloud "needs to be downloaded" (-8013).** Finder refused to trash `crumb-spike.txt` (an empty file made with `touch`): "The operation can't be completed because the item needs to be downloaded." 18 files made through Finder trashed fine. With iCloud Desktop, a file may not be local, so Belly's move to staging can fail. Plan 2: check `URLResourceValues.ubiquitousItemDownloadingStatus`; if it isn't `.current`, skip it (or start a download and retry later). Never treat a failed move as eaten; spec §4 already says spit out + "Couldn't eat that one." 
