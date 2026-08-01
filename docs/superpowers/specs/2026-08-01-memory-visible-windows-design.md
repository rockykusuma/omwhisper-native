# Memory — Capture Visible Windows — Design

**Date:** 2026-08-01
**Status:** Approved. Pending an implementation plan.
**Area:** S1 Memory capture. Follows `2026-08-01-memory-capture-web-area-design.md`
(content quality) and `2026-08-01-memory-semantic-search-design.md` (retrieval).

## Problem

`WindowSnapshotReader.captureFrontmost()` reads `NSWorkspace.shared.frontmostApplication`
and its `kAXFocusedWindowAttribute`. Memory therefore records **one window: the one you are
typing in**. On a multi-monitor desk the reference material — the spec you are reading, the
dashboard you are watching, the PR you are reviewing — is on the other display and is never
captured, even though it is fully visible and is often the thing you would later search for.

Confirmed on this machine with `CGWindowListCopyWindowInfo`: three normal windows on screen —
`Orca` at `2056×1290, x=-2056` (second display, negative origin) and two overlapping `Code`
windows on the main display. Only whichever one held focus was ever stored.

## Decision (brainstorming, 2026-08-01)

**Capture the focused window plus the frontmost window on each *other* display.**

Rejected alternatives: every on-screen window (captures windows fully hidden behind others —
volume for content you cannot see); focused-app-only-all-windows (misses the actual
multi-monitor case); screenshot/OCR (out of scope, and a much larger privacy surface).

Occluded windows on the *same* display are deliberately skipped. The second `Code` window in
the probe above is listed as on-screen but sits behind the first — it is not "what is in front
of me".

## Architecture

Two capture paths, kept separate so the existing one carries no regression risk:

| Piece | Responsibility |
|---|---|
| `captureFrontmost()` | **Unchanged.** Still the focused-window path, still the first thing captured each tick. |
| `VisibleWindows.select(...)` | **Pure.** Window descriptors + the focused window's display → the descriptors to additionally capture. All the logic worth testing lives here. |
| `captureWindow(pid:bounds:deadline:)` | Effectful. AX-reads one specific window, reusing the web-area targeting, exclusion check and text walk `captureFrontmost` already uses. |
| `MemoryCapture.tick()` | Captures focused first, then each selected other-display window, inside one shared per-tick time budget. |

### Enumeration needs no new permission

`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` returns each
window's `kCGWindowNumber`, owning PID, bounds and layer **without any permission**. Only
`kCGWindowName` is gated behind Screen Recording — the probe confirmed titles come back empty.

We never read the CG title. AX supplies it, exactly as it does today. **No new TCC prompt, no
new entitlement.**

### Selection (the pure part)

1. Keep layer 0 only — drops menu-bar items, the Dock, our own overlay HUD, and every panel.
2. Drop windows smaller than a minimum size — floating inspectors and tool palettes.
3. Drop our own process.
4. Assign each window to a display by which display's bounds contain its **centre**.
5. `CGWindowListCopyWindowInfo` returns front-to-back order, so the first window per display
   is that display's frontmost.
6. Drop the display the focused window is on — `captureFrontmost()` already covered it.

**Coordinate-space gotcha, stated because it is the easy bug here:** CG window bounds use a
top-left origin with y growing downward; `NSScreen.frame` uses bottom-left with y growing
upward. Display bounds must come from `CGDisplayBounds`, which is in the *same* space as the
window bounds. Mixing the two silently assigns every window on a secondary display to the
wrong display, or to none.

### Linking a CG window to its AX element

`AXUIElementCreateApplication(pid)` gives the app, `kAXWindowsAttribute` gives its windows —
but AX exposes no window number, so there is nothing to match on directly. Match on
**geometry**: the AX window whose `kAXPositionAttribute`/`kAXSizeAttribute` equal the CG
bounds. If no AX window matches, skip that window for this tick rather than guessing.

## The constraint that actually bites: time

Capture currently allows a **2.0 s AX budget**, against a **5 s poll**. Three windows at 2 s
each would overrun the poll and let ticks pile up.

The budget becomes **per tick, not per window**: ~3 s total, the focused window keeps its
existing 2 s, and the remainder is divided among the other-display windows, each capped at
1 s. Windows that do not fit are skipped and picked up on the next tick. Cost stays flat no
matter how many displays are attached.

## Privacy

`ScreenContextReader.isExcluded(bundleID:windowTitle:)` and the domain-exclusion check both
run **per window**, so password managers and private browsing are filtered on a second display
exactly as on the first. No change needed — but the per-window placement is load-bearing and
must not be hoisted out of the loop.

The honest part: this stores windows you are not attending to. A Slack conversation parked on
a second monitor now gets recorded where it previously did not. **No new toggle** — a second
switch inside an already-off-by-default feature is config nobody finds — but the Memory
settings copy must say Memory captures **visible windows**, not "what you're working on".
Anything narrower would be untrue.

## Storage

Volume scales with display count, but content-hash dedup absorbs the common case: a reference
page left open unchanged for ten minutes yields one row, not 120. Retention and prune are
unchanged.

Per-app boilerplate stripping in the semantic index is unaffected — more snapshots per app
sharpen the document-frequency estimate rather than blunting it.

## Testing

**Pure — unit tests, the project's convention:**

- Two displays, focused on one → the other display's frontmost is selected.
- Single display → nothing extra selected (the focused path already covered it).
- Two overlapping windows on the same other-display → only the front one.
- Layer ≠ 0 and undersized windows are filtered.
- Our own PID is never selected.
- Centre-based display assignment with a **negative-origin** display, the real layout here.

**Live — and it must be able to fail.** Put a distinctive page on the second monitor, work in
a *different* app on the main display for a minute, then query `memory.db` for rows whose
`appName` is the second-monitor app. Zero rows fails the feature; the failure mode this
replaces produced exactly zero. Checking only that "capture still works" would pass whether or
not a single line of this shipped.

## Out of scope

Screenshots or OCR · capturing occluded windows · per-window enable/disable UI · a
capture-frequency setting · minimised or other-Space windows (`.optionOnScreenOnly` excludes
them, correctly — they are not visible).

## Exit criteria

With two displays and focus on the main one, content from the second display's frontmost
window is searchable in Memory; exclusions still suppress a password manager on either
display; one tick with three windows completes inside the 5 s poll; and with one display,
behaviour and volume are unchanged from today.
