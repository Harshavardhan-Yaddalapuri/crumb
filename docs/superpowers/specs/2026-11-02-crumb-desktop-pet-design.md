# Crumb — macOS Desktop Clean-up Pet — Design

Date: 2026-11-02
Status: Approved in brainstorming; pending spec review

## Summary

Crumb is a small animated pet that lives on the macOS desktop and keeps it tidy. It sniffs out junk files on the Desktop and in Downloads, asks before eating them (eaten files are held for 15 minutes, then moved to the Trash), and physically hauls desktop icons to close gaps and apply sort presets — so users never need Finder's "Clean Up By".

Inspiration: Tangerine for Mac (tangerineformac.com) — an offline, Shift-drag file converter. Borrowed principles: lives where your hands already are, one sharp job, fully local, Mac-native.

Platform: macOS only, native Swift. Distributed outside the Mac App Store (needs Apple Events to Finder).

## Goals

- Make desktop/Downloads clean-up effortless and fun to watch.
- Never lose a user's file: every action is undoable.
- Never be annoying: rate-limited, quiet during focus/full-screen.

## Non-goals (v1)

Multi-display support (pet stays on main display), custom arrangement zones, AI-based junk detection, alternate pet skins, Windows/web.

## 1. Character and behaviors

Pet: original chibi black puppy (glossy black fur, big eyes, floppy ears, orange collar with a gold tag, cream bib), about 110 pt tall, a 3D model built by `art/build_crumb.py` (Blender) and exported to `art/crumb.usdz`. Faces the viewer when idle or asking; turns three-quarter toward where it walks. Lives along the bottom edge of the desktop above the Dock. Carries icons in its mouth when hauling.

Art and animation: jointed 3D puppet rendered with RealityKit through an orthographic camera (1 m = 92 pt), so the nose can be placed on an exact screen point. Joints: BodyPivot, HeadPivot, JawPivot, TailPivot, EarL/R, EyeL/R, four legs. `PuppetRig` sets them from a `Pose` (stand, sit, sit with head tilt, sniff, bite, carry, sleep, burp); `Pet` blends poses, drives a distance-locked walk cycle (no foot sliding), a spring on the ears, blinking and breathing. Reshaping the model in Blender doesn't change code as long as the pivot names stay.

| State | Trigger | Visual |
|---|---|---|
| Idle / Wander | Default | Mostly sits and watches you: glances left and right, wags in bursts, blinks; now and then a short stroll over the middle of the screen (where the Dock is); naps after 10 min of no activity |
| Haul | Gap appears or sort preset applied | Trots to the icon, picks it up, and carries the real icon (Finder moves it along ~20×/s) to its new spot; strolls back to the Dock after |
| Sniff | Junk candidate found | Walks to file, sniffs, "?" appears |
| Ask | After Sniff | Bubble: "Eat `<filename>`?" with **Yum** / **Keep** / **Never ask about this** (turns off that rule, e.g. screenshots; Settings (Plan 4b) turns it back on) |
| Eat (Bite 1–N) | Yum | N = round(1 + 2 × log10(sizeMB + 1)), clamped to 3…10 (e.g. 2.4 MB → 3, 45 MB → 4, 180 MB → 6, 1.4 GB → 7). A same-size picture of the icon is laid exactly over the real one; the file moves into the belly before the first bite, so only one icon is ever visible (the name goes with it). Each bite carves round bite marks from the snout's side, with a crumb-particle burst; ~0.9 s per bite (0.7 s when N > 5) |
| Fullness (1–5) | Belly holds 1–5 digesting files | Belly roundness scales with count; at 5 it's stuffed: slow waddle (0.6× pace); body widens 5% per file |
| Digest nap | Belly reaches 5/5 (after hauling to close the last gap) | Curls up, "zzz"; wakes as soon as a slot frees |
| Burp | A file's own 15-min digest timer ends | Small burp, belly shrinks one step; that file moves to Trash at this moment |
| Spit out | Undo (click sleeping pet → "Spit it out", or from Belly history) | Crumb turns and coughs the file up: a same-size picture slides out of its mouth, the file goes back on the Desktop (from the belly or the Trash) with its real icon moved in under the picture, then Crumb carries it to a free slot; a spat-out file is never asked about again |
| Burrow | Stale file found in Downloads | Hops into Dock's Downloads stack, pops out dragging the file, then Sniff → Ask on the desktop |
| Shrug | A job fails or is skipped | Shrug animation, optional short bubble |
| Sad | Finder automation permission missing | Sad face, bubble "I need permission to tidy" with button to System Settings |

Eat sequence: Yum → Bite ×2–3 → belly grows one step → Haul (close gap) → back to Idle (or Digest nap if belly is 5/5). Independently, 15 min after that file was eaten → Burp → Trash.

Digestion model:
- Belly capacity: **5 files** (constant `bellyCapacity = 5`).
- Each file gets its own 15-min digest timer, started the moment it's eaten. Timers run regardless of fullness or nap.
- The pet is hungry (may Ask/eat) whenever fewer than 5 files are digesting. Example: eats 3 at 0:00, nothing else → all 3 burp at 0:15, belly empty.
- At 5/5 it naps; it wakes as soon as the oldest file burps and a slot frees.
- Files whose timers end within the same few seconds burp together in one Burp.

Bite holes: drawn in code (`biteHoles`), any count 1–10; bite k leaves round bite marks at k/N with everything behind gone; the last bite takes the rest.

Anti-annoyance rules:
- At most one Ask per 15 minutes while wandering.
- "Clean up now" bypasses that limit and Asks back-to-back until the belly is 5/5 or no candidates remain; then it naps.
- Silent while a full-screen app is frontmost (Focus status is only available to apps with a special Apple entitlement, so Focus isn't detected).
- No Asks during Digest nap; new haul/arrange jobs queue until it wakes.
- **Keep** = never ask about that file again.

Pet menu (click pet): Clean up now · Sort by ▸ (Kind / Date / Name / Off) · Belly (history + undo) · Nap for 1h · Settings.

## 2. Junk detection

Deterministic rules only. Each rule is togglable in Settings.

| Rule | Matches | Default age |
|---|---|---|
| Old screenshots | `kMDItemIsScreenCapture`, or name matches `Screenshot YYYY-MM-DD…` / `Screen Recording YYYY-MM-DD…` | 7 days |
| Installers | `.dmg`, `.pkg`, `.zip` whose name starts with an app in `/Applications` or `~/Applications` (matched by name; contents aren't opened). A `.zip` must be the app's name or the name followed by a version number, so the user's own archives ("Slack export.zip") aren't installers | 3 days |
| Duplicates | `name (1).ext`, `name copy.ext` byte-identical to the original in the same folder | Immediate |
| Partial downloads | `.crdownload`, `.part`, `.download` files (not folders, so Safari's `.download` bundles are left alone) | 1 day untouched |
| Temp junk | `.tmp`, `~$*` Office lock files, empty folders | 1 day |

- iCloud placeholders: rules read only metadata; duplicates are compared byte for byte when both files are local; when either is only in iCloud, a same-size pair is asked about and, after Yum, both are downloaded and compared before eating (different → kept). After Yum, a placeholder is downloaded first (up to a minute) so moving it never blocks.
- "Age" = time since the most recent of last opened (`kMDItemLastUsedDate`), modified, and date added (`kMDItemDateAdded`). Copies such as AirDrop or unzip can keep an old modified date, so the latest wins.
- Never touched: any file with a Finder tag; files marked "Never ask"; non-empty folders.
- Candidate order: oldest first, ties broken by largest size.
- Scope: `~/Desktop` (top level) and `~/Downloads` (top level). No recursion in v1.

## 3. Architecture

Native Swift app, AppKit + RealityKit, no third-party dependencies.

| Component | Responsibility | Built on |
|---|---|---|
| PetOverlay | Borderless transparent window over the main display, level just above desktop icons; click-through except pet and bubble; renders pet and carried/bitten icon sprites | AppKit `NSWindow`, RealityKit `ARView` |
| PuppetRig + Pet | Map poses, walk, ears and blinks onto the USDZ joints each frame | RealityKit, CrumbCore `Pose`/`Gait`/`Spring`/`ScreenMap` |
| PetBrain | State machine + job queue (Haul, Sniff/Ask/Eat, Burrow, Spit out); enforces anti-annoyance rules and digest timer | Swift |
| FolderWatcher | Emits added/removed/renamed events for Desktop and Downloads | FSEvents |
| JunkRules | Pure function: file metadata → `junk(reason)` or `keep` | Swift, Spotlight metadata |
| FinderBridge | Only component that talks to Finder: read all desktop icons and positions in one call, place an icon and read it back, stream an icon along while carried; reads Finder's layout prefs | Apple Events via `NSAppleScript` |
| GapPlanner | Pure function: current positions + grid + sort mode → ordered list of moves preserving reading order | Swift |
| Belly | Holds eaten files in `~/Library/Application Support/Crumb/Belly/` during digestion, moves to Trash on Burp, keeps undo history (original path, original desktop position, current location) as JSON | `FileManager`, `NSWorkspace.recycle` |

### Data flows

File removed from Desktop, or an icon moved (Finder has no event for moves, so icon positions are also checked every 5 s, skipped while a mouse button is down):
1. FolderWatcher → `removed(file)`, or the 5 s position check.
2. PetBrain asks FinderBridge for positions → GapPlanner returns moves.
3. Hauler plans the moves and hauls one at a time: the puppy walks to the icon, bites, and carries the real icon while FinderBridge moves it along; at the drop FinderBridge places it and reads it back. After each haul it re-plans from fresh positions.

Eating:
1. JunkRules flags file → PetBrain queues Sniff/Ask.
2. On Yum: PetBrain re-validates the file (exists, unchanged), PetOverlay plays bites; on final bite Belly moves the file into the staging folder and records it.
3. Belly records `eatenAt` per file; PetBrain hauls to close the gap, then Idles (or naps at 5/5). Belly fires a Burp for each file when `now − eatenAt ≥ 15 min` and moves it to Trash.

Undo:
- During digestion: Belly moves file from staging back to its original path; FinderBridge restores its desktop position.
- After Burp: Belly restores from Trash using the recorded Trash URL, then position as above.

### Permissions

- Automation (Finder): requested on first launch.
- Downloads folder access: requested when Burrow is first enabled.

### Risk and spike

Resolved: the spike (spike/FINDINGS.md) showed per-icon positioning works and reads back exactly. Off-screen positions are silently ignored, so every move is verified by reading back.

## 4. Error handling

| Situation | Behavior |
|---|---|
| Finder automation denied | Sad state with settings button. Hauling and eating pause: Crumb needs icon positions to walk to a file. |
| Position set doesn't stick | FinderBridge reads back; retry once; else skip icon, Shrug, log. Never fake a move. |
| File gone/changed before action | Job dropped, Shrug. |
| Move to staging or Trash fails | File left in place (or returned), Spit out, bubble "Couldn't eat that one." |
| App quit/crash mid-digest | On launch, Belly sweeps staging: files held ≥ 15 min → Trash; younger resume countdown. |
| Icons rearranged mid-haul | Remaining hauls re-planned from fresh positions. |
| Desktop icons hidden (Finder setting / Stage Manager) | Pet wanders; hauling paused until icons visible. |
| Finder is sorting the desktop (Sort By / stacks) | Sad face, bubble asking to set Sort By to None; hauling paused, rechecked every minute. |
| Icon size / spacing other than Finder's defaults | Bubble: leaves icons alone (grid not measured yet); v2 measures other grids. |

## 5. Testing

- JunkRules: table-driven unit tests (name, age, tags, size → expected verdict). Primary file-safety gate.
- GapPlanner: unit tests on grids with holes and each sort mode.
- Belly: eat → digest → Trash, per-file timers (eat 3 at t=0 and 1 at t=10 → 3 burp at t=15, 1 at t=25), capacity cap at 5, spit out mid-digest, crash-recovery sweep; run against a temp directory with an injectable clock.
- FinderBridge: manual verification on real macOS (the spike).
- Animations: visual check; no automated UI tests in v1.
