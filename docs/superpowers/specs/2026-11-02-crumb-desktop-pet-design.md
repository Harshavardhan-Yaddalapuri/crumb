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

Pet: original cartoon puppy (orange fur, cream snout and paws, floppy dark ears, blue collar), ~110×92pt, side view, lives along the bottom edge of the desktop above the Dock. Carries icons in its mouth when hauling.

Art and animation: cut-out (skeletal) puppet. Parts: body, head, near/far ear, tail, four legs, mouth open/closed, eyes open/closed. Each part has a pivot; a per-frame loop blends between poses (stand, sit with head tilt, sniff, bite, carry, sleep, burp), drives a distance-locked walk cycle (no foot sliding), eased moves, a spring on the ears, tail wag, breathing, and fullness scaling. Implemented in one `PetSprite` file with SpriteKit nodes; hand-illustrated parts can replace the shapes later without changing the skeleton. Reference prototype: https://claude.ai/artifact/KVNPRyusCCgmBSdUjHGoyj

| State | Trigger | Visual |
|---|---|---|
| Idle / Wander | Default | Strolls, sits, blinks; naps after 10 min of no activity |
| Haul | Gap appears or sort preset applied | Walks to icon, grabs it, drags it to its new spot |
| Sniff | Junk candidate found | Walks to file, sniffs, "?" appears |
| Ask | After Sniff | Bubble: "Eat `<filename>`?" with **Yum** / **Keep** / **Never ask about this** |
| Eat (Bite 1–N) | Yum | N = round(1 + 2 × log10(sizeMB + 1)), clamped to 1…10 (e.g. 2.4 MB → 2, 45 MB → 4, 180 MB → 6, 1.4 GB → 7). Each bite removes a chunk from the icon sprite, sweeping left to right, with a crumb-particle burst; ~0.5 s per bite (0.35 s when N > 5) |
| Fullness (1–5) | Belly holds 1–5 digesting files | Belly roundness scales with count; at 5 it's stuffed: slow waddle, pats tummy |
| Digest nap | Belly reaches 5/5 (after hauling to close the last gap) | Curls up, "zzz"; wakes as soon as a slot frees |
| Burp | A file's own 15-min digest timer ends | Small burp, belly shrinks one step; that file moves to Trash at this moment |
| Spit out | Undo (click sleeping pet → "Spit it out", or from Belly history) | Coughs the file back to its original position |
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

Bite masks: three pre-drawn "bitten" alpha masks applied in order to the icon snapshot (bite 1, bite 2, gone). Two-bite variant uses masks 1 and 3.

Anti-annoyance rules:
- At most one Ask per 15 minutes while wandering.
- "Clean up now" bypasses that limit and Asks back-to-back until the belly is 5/5 or no candidates remain; then it naps.
- Silent while a full-screen app is frontmost or a Focus mode is on.
- No Asks during Digest nap; new haul/arrange jobs queue until it wakes.
- **Keep** = never ask about that file again.

Pet menu (click pet): Clean up now · Sort by ▸ (Kind / Date / Name / Off) · Belly (history + undo) · Nap for 1h · Settings.

## 2. Junk detection

Deterministic rules only. Each rule is togglable in Settings.

| Rule | Matches | Default age |
|---|---|---|
| Old screenshots | `kMDItemIsScreenCapture` or name starts with `Screenshot` / `Screen Recording` | 7 days |
| Installers | `.dmg`, `.pkg`, `.zip` whose contained app already exists in `/Applications` | 3 days |
| Duplicates | `name (1).ext`, `name copy.ext` byte-identical to the original in the same folder | Immediate |
| Partial downloads | `.crdownload`, `.part`, `.download` | 1 day untouched |
| Temp junk | `.tmp`, `~$*` Office lock files, empty folders | 1 day |

- "Age" = time since last opened (`kMDItemLastUsedDate`), falling back to modification date if never opened.
- Never touched: any file with a Finder tag; files marked "Never ask"; non-empty folders.
- Candidate order: oldest first, ties broken by largest size.
- Scope: `~/Desktop` (top level) and `~/Downloads` (top level). No recursion in v1.

## 3. Architecture

Native Swift app, AppKit + SpriteKit, no third-party dependencies.

| Component | Responsibility | Built on |
|---|---|---|
| PetOverlay | Borderless transparent window over the main display, level just above desktop icons; click-through except pet and bubble; renders pet and carried/bitten icon sprites | AppKit `NSWindow`, SpriteKit |
| PetBrain | State machine + job queue (Haul, Sniff/Ask/Eat, Burrow, Spit out); enforces anti-annoyance rules and digest timer | Swift |
| FolderWatcher | Emits added/removed/renamed events for Desktop and Downloads | FSEvents |
| JunkRules | Pure function: file metadata → `junk(reason)` or `keep` | Swift, Spotlight metadata |
| FinderBridge | Only component that talks to Finder: read all desktop icon positions, set one icon's position, read grid spacing/icon size | Apple Events via `NSAppleScript` |
| GapPlanner | Pure function: current positions + grid + sort mode → ordered list of moves preserving reading order | Swift |
| Belly | Holds eaten files in `~/Library/Application Support/Crumb/Belly/` during digestion, moves to Trash on Burp, keeps undo history (original path, original desktop position, current location) as JSON | `FileManager`, `NSWorkspace.recycle` |

### Data flows

File removed from Desktop:
1. FolderWatcher → `removed(file)`.
2. PetBrain asks FinderBridge for positions → GapPlanner returns moves.
3. One Haul job per move. PetOverlay snapshots the icon, plays walk/grab/drag; at drop, FinderBridge sets the real position and verifies it; sprite fades into the real icon.

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

FinderBridge's ability to set desktop icon positions reliably on current macOS is the core risk. First task is a 2-day spike proving set-and-verify works. Fallback if it fails: set Finder's desktop arrangement ("Sort By") via Apple Events and keep the pet's animation as the visual layer.

## 4. Error handling

| Situation | Behavior |
|---|---|
| Finder automation denied | Sad state with settings button. Eating still works; hauling disabled. |
| Position set doesn't stick | FinderBridge reads back; retry once; else skip icon, Shrug, log. Never fake a move. |
| File gone/changed before action | Job dropped, Shrug. |
| Move to staging or Trash fails | File left in place (or returned), Spit out, bubble "Couldn't eat that one." |
| App quit/crash mid-digest | On launch, Belly sweeps staging: files held ≥ 15 min → Trash; younger resume countdown. |
| Icons rearranged mid-haul | Remaining hauls re-planned from fresh positions. |
| Desktop icons hidden (Finder setting / Stage Manager) | Pet wanders; hauling paused until icons visible. |

## 5. Testing

- JunkRules: table-driven unit tests (name, age, tags, size → expected verdict). Primary file-safety gate.
- GapPlanner: unit tests on grids with holes and each sort mode.
- Belly: eat → digest → Trash, per-file timers (eat 3 at t=0 and 1 at t=10 → 3 burp at t=15, 1 at t=25), capacity cap at 5, spit out mid-digest, crash-recovery sweep; run against a temp directory with an injectable clock.
- FinderBridge: manual verification on real macOS (the spike).
- Animations: visual check; no automated UI tests in v1.
