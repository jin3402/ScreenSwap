# ScreenSwap

A macOS menu bar app for moving windows between your MacBook display and an
external monitor, driven entirely from the keyboard.

Everything runs through a single shortcut: **⌃⌥↑** (Control + Option + Up Arrow).
It fans your windows out so none of them overlap, then you aim, pick, and act.

> Deliberately **not** Control+Up — that is Mission Control. Adding Option keeps
> ScreenSwap clear of it.

---

## Two ways to move a window

**Just move this one** — ⌃⌥← and ⌃⌥→ send the frontmost window one display over
immediately. No overlay, no fanning out, no aiming. This is the common case by a
wide margin, and it is one keystroke.

**Show me everything** — ⌃⌥↑ opens the overview below, for picking several windows,
finding one you lost, or acting on something that is not frontmost.

| Shortcut | Action |
|---|---|
| **⌃⌥←** | Send the frontmost window to the display on the left |
| **⌃⌥→** | Send it to the display on the right |
| **⌃⌥↓** | Send it to the display below |
| **⌃⌥↑** | Open the window overview |

All four are configurable — see [Settings](#settings). "Send up" ships unbound
because ⌃⌥↑ is the overview; bind it if your displays are stacked.

---

## The overview

Press **⌃⌥↑**. Every window on every display physically fans out so none of them
overlap, and see-through outlines are drawn over them. They stay real, live
windows the whole time — nothing is a screenshot. The frontmost window starts
focused, outlined in **white**.

Closing the overlay **any** way puts every window back exactly where it was.

### Keys inside the overview

| Key | What it does |
|---|---|
| **arrows** | Aim the focus cursor. **Never** moves a window — safe to press any time |
| **⇧ Shift** | Tapped on its own: select the focused window — tap again to deselect |
| **⌘ + arrows** | Send the selection to the display in that direction |
| **↵ Enter** | Put the selection into full screen |
| **⌫ Backspace** | Take the selection back out of full screen |
| **⌘Q** | Quit the apps owning the selection |
| **space** | Swap **all** windows between the two displays |
| **1**–**9** | Jump the cursor straight to that window |
| **type letters** | Search by app name or window title; the cursor follows the match |
| **⌘Z** | Undo the last move |
| **esc** | Clear the search, or close when there is none |

Every action works on **the selection, or the focused window when nothing is
selected** — so you can aim at one window and act on it without selecting first.

### Aim first, then pick

Arrows only ever move the cursor; Shift is a discrete tap that marks whatever the
cursor sits on. Nothing about aiming can change a window, so you can look around
freely, and nothing is committed until you press an action key.

Sending is its own chord for the same reason. An early version moved windows on a
bare arrow press the moment you stopped selecting, which made the whole thing feel
like a trap.

Build a selection by repeating: arrow to a window, tap **Shift**, arrow to the
next, tap **Shift** again. Tapping Shift on an already-selected window deselects
it — Shift is the whole selection story, on and off.

### Two outlines, two meanings

- **White ring, just outside a window's edge** — the focus cursor.
- **Blue border, tint and a corner checkmark** — selected.

The checkmark, not the tint, is what identifies a selection when windows overlap:
the tint of a window sitting behind another necessarily paints across it.

### Finding a window fast

Every window wears a number. Press **1**–**9** to jump straight to it — numbers are
global, so one key means one window no matter which display it is on.

Past nine windows, **just start typing**. Matching is on both app name and window
title, so `mail` finds Mail and `invoice` finds the document window with it in the
title. Non-matches stay on screen but recede, so you can still see what you are
ruling out. **⌫** edits the query, **esc** clears it.

### Undo

Moving a dozen windows with one keystroke deserves a way back. **⌘Z** inside the
overview — or **Undo Last Move** in the menu bar — puts the last move's windows
back where they were.

Only moves are undoable. Full screen has its own reverse (⌫) and quitting an app is
not something an undo could honestly reverse.

### Mouse

- **Drag** a window onto another display's area to move just that one.
- **⌘-click** toggles selection, sharing the same set as Shift.

---

## The fan-out, and what it costs

macOS composites Mission Control inside the window server using private APIs, so
no third-party app can ask the system to *draw* everyone's live windows at new
positions. ScreenSwap takes the honest route instead: it really moves and resizes
your windows through the Accessibility API, then moves them back.

That keeps them genuine, live windows, but it has real costs worth knowing:

- **Apps re-lay out while spread.** Shrinking a window makes editors collapse
  sidebars and browsers reflow text. Restoring the size restores the layout, but
  things like scroll position may not come back exactly.
- **Minimum window sizes are respected.** An app that refuses to shrink past a
  floor stays large, and can still overlap its neighbours.
- **It takes a moment.** Each window costs a few Accessibility round trips, so a
  dozen windows means a visible beat before the overlay settles.
- **Nothing is lost if it crashes.** Every fan-out writes the original geometry to
  `~/Library/Application Support/ScreenSwap/pending-restore.json` first. If
  ScreenSwap is killed while windows are spread, the next launch offers to put
  them back.

Full-screen windows are left out of the fan-out — they own their whole Space, and
shrinking one into a grid cell fights the window server.

---

## Settings

**Menu bar icon → Settings…** (or ⌘, when the menu is open).

Every shortcut is rebindable: click one, type the new combination, and it takes
effect immediately. **⌫** while recording unbinds an action, **esc** cancels.
Combinations need at least one of ⌃ ⌥ ⌘ — a bare key would swallow that key
system-wide.

If another app already owns a combination, ScreenSwap says so rather than failing
silently, both when you pick it and at launch.

**Launch at login** lives here too. It uses `SMAppService`, so macOS manages it and
it shows up under Login Items in System Settings like any other well-behaved app.

## Requirements

- macOS 14 (Sonoma) or later
- Two displays, for the swap and send actions to be meaningful

## Permissions

**Accessibility** is the only permission ScreenSwap needs, and it is required.
This is how it reads and moves other apps' windows. Without it the app runs but
cannot move anything, and the menu bar icon stays dimmed.

> System Settings → Privacy & Security → Accessibility → enable **ScreenSwap**

The app watches for the grant and enables itself as soon as you flip the switch,
so there is normally no need to relaunch.

ScreenSwap never captures your screen, so it does **not** ask for Screen
Recording. Nothing is recorded, stored, or transmitted anywhere.

---

## Building

```bash
./Scripts/build_app.sh
```

This produces `dist/ScreenSwap.app`. For a universal (Apple Silicon + Intel)
build:

```bash
UNIVERSAL=1 ./Scripts/build_app.sh
```

Then launch it:

```bash
open dist/ScreenSwap.app
```

> **Permissions while developing.** `build_app.sh` ad-hoc signs the bundle, and an
> ad-hoc signature is derived from the binary itself. Any code change produces a
> new signature, which macOS treats as a different app — so Accessibility has to be
> granted again after a rebuild that changed code. Signing with a real Developer ID
> makes grants persist.

## Diagnostics

The binary has a terminal mode for checking display geometry and permissions
without opening the UI:

```bash
./dist/ScreenSwap.app/Contents/MacOS/ScreenSwap --diagnose
```

It reports permission status, each display's AppKit and CoreGraphics frames, the
directional map (which display is "left" of which), and every window it can see
along with whether it is movable.

Dry-run the move actions without touching a single window:

```bash
./dist/ScreenSwap.app/Contents/MacOS/ScreenSwap --plan-swap
```

For overlay problems, launch with logging and read `~/Library/Logs/ScreenSwap.log`:

```bash
open dist/ScreenSwap.app --args --debug
```

That log records which windows were found, which could be matched to an
Accessibility element, and what every action actually did — which is how to find
out why a particular app refuses to move.

---

## Distribution

Sign and notarize (needs a Developer ID certificate and a `notarytool` keychain
profile):

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" KEYCHAIN_PROFILE=screenswap ./Scripts/sign_and_notarize.sh
```

Package into a DMG with an `/Applications` drop target:

```bash
./Scripts/make_dmg.sh
```

Set up the notarytool profile once, beforehand:

```bash
xcrun notarytool store-credentials "screenswap" --apple-id "you@example.com" --team-id TEAMID --password <app-specific-password>
```

Change `CFBundleIdentifier` in `Info.plist` from `com.screenswap.app` to your own
reverse-DNS identifier before signing.

---

## Project layout

```
Sources/ScreenSwap/
  main.swift              Entry point; routes --diagnose to Diagnostics
  AppDelegate.swift       Menu bar item, permission flow, hotkey registration
  ExposeOverlay.swift     The overlay: panels, outlines, keyboard and mouse
  WindowArranger.swift    Fans windows out and puts them back, with crash recovery
  HotkeyManager.swift     Global hotkeys via the Carbon Hot Key API
  WindowManager.swift     Window enumeration and movement via the Accessibility API
  WindowSwapper.swift     Bulk swap and send operations
  DisplayManager.swift    Screen geometry and AppKit <-> CoreGraphics conversion
  PermissionsHelper.swift Accessibility checks and System Settings links
  Diagnostics.swift       Terminal verification modes
  Preferences.swift       Shortcut storage and launch-at-login
  Shortcut.swift          Key code + modifiers, with layout-aware display names
  ShortcutRecorder.swift  Click-to-record shortcut field
  PreferencesWindow.swift The settings window
  MoveHistory.swift       One level of undo for window moves
  Log.swift               Opt-in debug logging
```

Two coordinate spaces are in play throughout, and mixing them up is the classic
source of "window jumps to the wrong monitor" bugs:

- **AppKit** (`NSScreen.frame`): origin bottom-left of the primary display, y up.
- **CoreGraphics / Accessibility**: origin top-left of the primary display, y down.

`DisplayManager` owns the conversion between them; everything else should go
through it.

---

## Known limitations

- **Some apps cannot be moved.** A window is only movable if ScreenSwap can pair
  its CoreGraphics record with an Accessibility element, and some apps expose
  theirs inconsistently or refuse to have position written. Those windows appear in
  the overlay but are skipped by moves; `--debug` logging says which and why.
- **Full-screen windows live on their own Space**, so they only appear in the
  overlay when you open it from that Space.
- **Full screen is not universal.** Dialogs, panels and some non-native windows
  expose no writable full-screen state; ScreenSwap beeps rather than pretending it
  worked.
