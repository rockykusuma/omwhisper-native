# Memory Capture Off MainActor — Design

**Date:** 2026-08-02
**Status:** Approved. Pending an implementation plan.
**Area:** S1 Memory capture. Fixes a regression introduced the same day by
`2026-08-01-memory-visible-windows-design.md`.

## Problem

**The app freezes.** Global shortcuts stop responding, Fn push-to-talk stops responding, and
the UI stalls.

`MemoryCapture` is `@MainActor` and its `tick()` calls
`WindowSnapshotReader.captureVisible(exclusions:)` **synchronously**. That call performs
accessibility tree walks across every visible window, up to a 3-second budget. So the main
thread is blocked for up to 3 seconds out of every 5-second poll.

Observed live, 2026-08-02:

```
23:28:44  WindowSnapshot  tick budget spent, 1 window(s) deferred
23:28:50  WindowSnapshot  tick budget spent, 1 window(s) deferred
23:28:57  WindowSnapshot  tick budget spent, 1 window(s) deferred
```

**"Tick budget spent" on every tick** — the walk was consuming its entire allowance, every
time, on the main thread.

Everything the hotkeys need runs on that same thread: `GlobalHotkey`'s `NSEvent` monitor
callbacks, `PushToTalkMonitor`, and the SwiftUI views. They were not broken; they were starved.

### How it got here

`MemoryCapture`'s header explains the original choice: *"@MainActor: a lightweight poll, not a
real-time audio path — matches MeetingWatcher's isolation, not AudioCapture's
nonisolated+lock pattern."* That was true when capture read **one** focused window in
milliseconds.

Visible-windows capture (shipped the same day) changed both terms: it walks the frontmost
window on **every display**, and raised the budget from 2s to 3s. Its spec called the time
budget *"the constraint that actually bites"* and sized it against the 5-second poll interval —
**but never considered that the work happens on the main thread.** Bounding total work per tick
does nothing about which thread pays for it.

Three rounds of debugging were spent chasing an unresponsive shortcut that was really this
stall. The shortcut was almost certainly fine.

## The fix

**Everything below `MemoryCapture` is already `nonisolated`** and was designed to run off the
main thread — `WindowSnapshotReader`, `ScreenContextReader`, `VisibleWindows`, and
`MemoryStore` (which is `Sendable`). `ScreenContextReader`'s own header states it:
*"AXUIElement calls are cross-process IPC with no MainActor affinity."*

Only `MemoryCapture` puts them back on main.

| Piece | Change |
|---|---|
| `MemoryCapture.tick()` | Reads the settings it needs on MainActor — suppression, exclusions, excluded domains — then hands off. Does no AX work itself. |
| A new `nonisolated` capture function | Performs the walk and the store write on the cooperative pool. |
| Collaborator callbacks | `onSnapshotStored` and `onDegradation` hop back to MainActor; they touch `AppState`. |
| In-flight guard | An `OSAllocatedUnfairLock`-protected flag. A tick that arrives while a capture is running is **skipped**. |

This is `AudioCapture`'s established pattern — `nonisolated` work with a real lock over the
small mutable state — which exists in this codebase for exactly this reason.

### The in-flight guard is essential, not defensive

The poll fires every 5 seconds and a slow tick now takes about 3. Without a guard, a tick that
overruns lets the next one start alongside it. Moving work off the main thread removes the
freeze but makes pile-up *easier*, because nothing serialises the walks any more — several
concurrent AX sweeps would leave the machine worse off than the bug being fixed.

The flag must clear on **every** exit path, including a thrown error, or capture stops forever
after one failure — silently, which is this project's most expensive failure mode.

### What is deliberately unchanged

The 5-second interval, the 3-second budget, exclusions, content-hash dedup, retention, and the
store schema. **The budget was never the bug; where it was spent was.**

## Why not simply lower the budget

A smaller budget reduces the stall without removing it. Any main-thread AX walk starves
hotkeys, push-to-talk and the UI, because all of them run there. A one-second stall every five
seconds is still a stutter felt while typing — and it would return the moment someone attached
a third display or opened a slow Electron window.

## Failure handling

- A capture that throws clears the in-flight flag and logs; the next tick proceeds normally.
- A store write failing is logged per snapshot, as today, and does not abort the remaining ones.
- Suppression is read fresh on MainActor at the start of each tick, so pausing Memory still
  takes effect on the next tick rather than after the current capture.

## Testing

The in-flight guard is the testable part:

- A second call while one is in flight is skipped — **and the first still completes**. A test
  asserting only "the second returned early" would pass even if the guard wedged permanently.
- The flag clears after a normal completion, so a later tick runs.
- The flag clears after a **thrown** capture, so one failure does not stop capture forever.

Live, and this is the check that matters: **with Memory enabled, press the dictation shortcut
repeatedly while capture is running.** Dictation must start immediately every time. Today it
demonstrably does not — that is the regression, and it is what "fixed" has to mean.

Also confirm the app remains responsive with two displays attached and a slow Electron window
frontmost, since that is the configuration that produced "tick budget spent" on every tick.

## Out of scope

Changing the capture interval or budget · reducing how many windows are captured · the chronicle
pipeline · `MeetingWatcher`, which polls CoreAudio state cheaply and has no AX walk.

## Exit criteria

With Memory enabled and two displays attached, the dictation shortcut, Fn push-to-talk and the
hub UI all respond without perceptible delay while capture is running; snapshots continue to be
written at the same rate as before; a capture that overruns the poll interval causes the next
tick to be skipped rather than run concurrently; and a capture that throws does not stop
subsequent captures.
