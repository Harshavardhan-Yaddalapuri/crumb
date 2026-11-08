# Crumb Plan 4b — Finish the Desktop

**Goal:** the last Desktop features from the spec: Nap for 1h, Settings, and silence while a full-screen app is in front.
Downloads (scanning and Burrow) are deferred by the user until the Desktop is done.

**Architecture:** all three live in `Eater` (it owns asking, napping and the rule/keep lists) plus menu items in
`Controls.swift` / `main.swift`. No new permissions, no new files beyond this plan.

## Task 1: Nap for 1h

- `Eater.napForAnHour()`: sets `restUntil = now + 1 h`, lets the current job finish, then sleeps (same sleep as the
  stuffed nap: no asks, tidies wait, burps still happen silently). A timer calls `wakeUp()` after the hour.
- `Eater.wakeUp()`: ends the rest; a stuffed Crumb sleeps on until a slot frees.
- A slot freeing doesn't end a rest; "Clean up now" and Spit out do (the user asked for something).
- Menu: "Nap for 1h", or "Wake up" while resting. `Eater.onChange` rebuilds the menu so the title follows.
- Not kept across relaunch (a relaunch is awake).

## Task 2: Settings submenu

- "Settings ▸ Ask about": one checkable item per junk rule (re-enables a rule turned off by "Never ask about …").
- "Forget N kept files": clears the never-ask list (Keep answers and spat-out files), so they're asked about again.
- A submenu rather than a window: Crumb has no Dock icon or app menu, and two settings don't need a window.

## Task 3: Quiet while full-screen

- `Eater.fullScreenAppInFront()`: the frontmost app has a normal-layer window exactly covering the main display.
  Window bounds need no permission (titles would need Screen Recording; they aren't read).
- `lookForJunk` doesn't ask while it's true. Tidies still run: they are silent and the pet is hidden behind the app.

## Verify

- `swift test` (14 tests; these are app-side changes with no pure logic worth a unit test).
- Live: Nap for 1h → asleep, menu shows Wake up → Wake up → awake. Settings toggles persist (`defaults read`).
  Full-screen: a test window in full screen makes `fullScreenAppInFront()` true; windowed, false.
- Spec: menu, nap and full-screen rows updated; Downloads marked deferred.
