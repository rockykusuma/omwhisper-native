# Configurable Shortcuts — Design

**Date:** 2026-08-02
**Status:** Approved. Pending an implementation plan.
**Area:** `Hotkeys/`, `AppState`, General settings.

## Problem

Four global shortcuts exist; **only one is configurable**:

| Feature | Shortcut | Configurable |
|---|---|---|
| Dictation | ⌘⇧V | **yes** — `dictationShortcut`, a recorded `KeyCombo` |
| Smart Dictation | ⌘⇧B | no — hardcoded `keyCode: 11` |
| Polish Selected Text | ⌘⇧P | no — hardcoded `keyCode: 35` |
| Brain-dump | ⌘⇧D | no — hardcoded `keyCode: 2` |

⌘⇧P in particular collides with common command-palette bindings (VS Code, Chrome, others),
and it is not reassignable.

### What the collision actually does — and it is not what it looks like

`GlobalHotkey` uses `NSEvent.addGlobalMonitorForEvents`, **not** Carbon's
`RegisterEventHotKey`. A global monitor is a passive observer: it never *owns* a combo, never
fails to register because another app holds it, and cannot consume the event.

So when two apps want ⌘⇧P, **both fire**. OmWhisper's `beginPolishSelectedText` runs, the other
app opens its palette and takes focus, and
`guard let original = await PasteService.copySelection() else { return }` bails because there is
no selection. Nothing happens, nothing is logged, nothing is recorded.

**The defect is therefore not "OmWhisper's shortcut doesn't work" but "OmWhisper fires on a
shortcut you are using for something else", invisibly, every time.** That reframing matters:
the most direct fix is being able to switch a feature's shortcut *off*, not only to move it.

Observed 2026-08-02: a ten-press ⌘⇧P test recorded zero degradation events for exactly this
reason — the presses reached OmWhisper and returned early.

## Decisions

1. **All four configurable**, with Smart Dictation / Polish Selected / Brain-dump each also
   settable to **None** (disabled). Dictation stays non-optional — an app with no way to
   dictate is broken, not configured.
2. **Guard only what can be proven.** Enforce what is detectable; never claim what is not.

| Detectable — enforced | Not detectable — not claimed |
|---|---|
| Two OmWhisper features on one combo | Another application using the same combo |
| A reserved system combo (⌘Space, ⌘Tab, ⌘Q, ⌘W, ⌘H, ⌘M) | |
| The global monitor failing to install (Accessibility not granted) | |

**Rejected: detecting other apps' shortcuts.** There is no supported API. The alternatives —
the private Carbon hot-key table, reading other apps' preference files, or a hardcoded list of
common bindings — are respectively unsupported, fragile, and stale within months. **A false
"no conflict" is a promise the app cannot keep**, and an unreliable warning is worse than none.

## Architecture

| Piece | Responsibility |
|---|---|
| `ShortcutValidation` | **Pure.** `conflict(for:assignedTo:) -> Conflict?` — duplicate within OmWhisper, or reserved system combo. All the logic worth testing. |
| `AppState` | Three new `KeyCombo?` settings beside `dictationShortcut`, each persisted as JSON in `UserDefaults` with `access`/`withMutation`, each setter reconfiguring or stopping its `GlobalHotkey`. |
| `GlobalHotkey` | Gains `isInstalled` so settings can show when the monitor never attached. Its `start()` already logs this. |
| General settings | One Shortcuts section, four rows, reusing the recorder UI that already exists for dictation. |

### Following the proven pattern, not inventing one

`dictationShortcut` already does persistence, Observation instrumentation and hotkey
reconfiguration correctly. The three new settings copy it exactly. The `access`/`withMutation`
calls are mandatory: a plain computed property over `UserDefaults` never notifies, which in this
codebase has repeatedly produced UI that silently fails to redraw.

### Disabling

A nil combo means the feature's `GlobalHotkey` is stopped, not merely reassigned to something
unreachable. The feature remains available from the menu where one exists; only the global
shortcut goes away.

### Monitor health

`addGlobalMonitorForEvents` returns nil when the process is not Accessibility-trusted, and the
existing `start()` already logs whether each monitor attached. Surfacing that in the Shortcuts
section matters because **a correctly-configured shortcut that silently never fires is the
exact failure class this project keeps hitting** — the shortcut looks right and does nothing.

## Failure handling

- A rejected assignment is refused at record time with the reason, so an unusable combo cannot
  be saved.
- A combo that decodes to nothing (corrupt stored JSON) falls back to that feature's original
  default rather than leaving the feature unreachable.
- Setting a shortcut never affects any other feature's assignment.

## Testing

`ShortcutValidation` is pure and carries the real tests:

- A combo already assigned to another OmWhisper feature is rejected, and the message names
  which feature holds it.
- Reassigning a feature to **its own current combo** is not a conflict — the naive
  "is it in use?" check gets this wrong and makes a shortcut unsavable once set.
- **Two disabled features are not in conflict.** A naive equality check treats nil == nil as a
  duplicate and blocks the second feature from being disabled at all.
- Reserved system combos are rejected.
- Distinct combos are accepted.

Live: reassign Polish Selected to an unused combo and confirm it fires; set it to None and
confirm it no longer fires while Dictation still does; with Accessibility revoked, confirm the
Shortcuts section says the monitor is not installed rather than showing a healthy assignment.

## Out of scope

Detecting other applications' shortcuts · per-app shortcut profiles · changing the push-to-talk
key (already configurable, a different mechanism) · in-app menu items for these features ·
migrating anyone's existing dictation shortcut.

## Exit criteria

Each of Smart Dictation, Polish Selected and Brain-dump can be reassigned or switched off, and
the change takes effect without a relaunch. Assigning one feature's combo to another is refused
with a message naming the holder. Two features can both be disabled. Dictation cannot be
disabled. When Accessibility is not granted, the Shortcuts section says so instead of implying
the shortcuts work.
