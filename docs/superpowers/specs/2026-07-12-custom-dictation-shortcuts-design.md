# Custom dictation shortcut + push-to-talk key — Design

**Date:** 2026-07-12
**Status:** Approved, ready for implementation plan

## Problem

Every dictation trigger is hardcoded: ⌘⇧V toggles dictation, holding Fn/Globe is
push-to-talk. Users on different keyboards/layouts, or who've reassigned those keys,
have no way to change them. This adds a Settings UI to configure the **toggle
shortcut** and the **push-to-talk key** (scope decided: those two only — smart /
brain-dump / polish-selected keep fixed defaults).

## Design

### 1. Data model — `Hotkeys/KeyCombo.swift` (new)

```swift
nonisolated struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt          // NSEvent.ModifierFlags rawValue (masked to ⌘⌥⇧⌃)
    var label: String            // base key captured at record time, e.g. "V"
    // default = ⌘⇧V: keyCode 9, NSEvent.ModifierFlags([.command, .shift]).rawValue
    static let defaultDictation = KeyCombo(keyCode: 9, modifiers: /* ⌘⇧ rawValue */, label: "V")
    var display: String          // "⌘⇧V" — modifier glyphs + label
}

nonisolated enum PTTKey: String, CaseIterable {
    case fn, rightCommand, rightOption, rightControl
    var display: String          // "Fn / Globe", "Right ⌘", …
}
```

- `KeyCombo` persists in UserDefaults as JSON. `label` captured at record time
  (`charactersIgnoringModifiers`, uppercased) avoids needing a keyCode→string table.
- `PTTKey` persists as its rawValue. Right-modifier keyCodes: Right ⌘ = 54,
  Right ⌥ = 61, Right ⌃ = 62 (standard kVK values). `.fn` has no stable keyCode —
  detected via the `.function` flag as today.

### 2. Toggle-shortcut recorder — `UI/KeyRecorderView.swift` (new)

A SwiftUI control bound to `KeyCombo`:
- Idle: a button showing `combo.display` ("⌘⇧V").
- Click → "Press keys…" state; installs a **local** `NSEvent` `.keyDown` monitor.
- On the next keyDown: read `keyCode`, `modifierFlags` (masked to ⌘⌥⇧⌃),
  `charactersIgnoringModifiers`. **Validate**: must contain at least one of ⌘/⌃/⌥
  (a ⇧-only or bare key would fire during normal typing) — else reject with a hint,
  stay recording. Valid → store, swallow the event (return nil), exit recording.
- **Esc** cancels (keeps the old combo). The monitor returns nil while recording so
  keystrokes don't leak into any focused field.

### 3. PTT picker

A dropdown of `PTTKey.allCases` (Fn/Globe · Right ⌘ · Right ⌥ · Right ⌃).
`PushToTalkMonitor.handleFlagsChanged` generalizes:
- `.fn` → `event.modifierFlags.contains(.function)` (unchanged behavior).
- right-modifier → `event.keyCode == target && event.modifierFlags.contains(flag)`
  for down, flag-cleared for up (the `ReplyAssistMonitor` right-⌥ pattern).

**Known overlap:** picking Right ⌥ collides with Reply Assist's double-tap-right-⌥.
A one-line caption warns; it isn't blocked.

### 4. Live reconfigure (no relaunch)

- `GlobalHotkey`: `keyCode`/`modifiers` become `var`; add
  `reconfigure(keyCode:modifiers:)` that updates them and calls `start()` (which
  already `stop()`s first). 
- `PushToTalkMonitor`: holds a `var key: PTTKey`; add `reconfigure(key:)` that
  updates it and restarts.
- `AppState`:
  - `dictationShortcut: KeyCombo` and `pttKey: PTTKey` computed settings
    (access/withMutation over UserDefaults, JSON / rawValue). Setters call
    `hotkey.reconfigure(...)` / `pushToTalk.reconfigure(...)`.
  - `init()` builds `hotkey`/`pushToTalk` from the stored values instead of the
    hardcoded ⌘⇧V / Fn. (Reading `dictationShortcut` returns the ⌘⇧V default when
    unset, so existing users are unaffected.)

### 5. Settings UI — General → "Shortcuts"

A new `PorcelainSection(eyebrow: "Shortcuts")` in `GeneralSettingsView`:
- "Toggle dictation" row → `KeyRecorderView` bound to `dictationShortcut`.
- "Push-to-talk" row → `Picker` bound to `pttKey` (with the Right-⌥ caution line).
- "Reset to defaults" button → restores ⌘⇧V / Fn.

## Out of scope (YAGNI)

- Custom shortcuts for smart dictation / brain-dump / polish-selected.
- Recording arbitrary non-modifier keys for PTT (regular keys type + auto-repeat).
- Per-app shortcuts; conflict-detection against system shortcuts.

## Files

| File | Change |
|---|---|
| `Hotkeys/KeyCombo.swift` | New — `KeyCombo` + `PTTKey` + display helpers |
| `UI/KeyRecorderView.swift` | New — the combo recorder control |
| `Hotkeys/GlobalHotkey.swift` | `var` keyCode/modifiers + `reconfigure(keyCode:modifiers:)` |
| `Hotkeys/PushToTalkMonitor.swift` | `PTTKey` detection + `reconfigure(key:)` |
| `AppState.swift` | `dictationShortcut`/`pttKey` settings; init from stored values; reconfigure wiring |
| `UI/GeneralSettingsView.swift` | Shortcuts section |

## Testing

- `KeyCombo.display` (modifier-glyph rendering) and the recorder's validation rule
  (rejects modifier-less combos) — pure, unit-tested.
- `PTTKey` keyCode/flag mapping — pure, unit-tested.
- The `NSEvent`-monitor recording, live reconfigure, and Settings UI — verified live
  (per project convention for AppKit/event-monitor code).
- Live exit criteria: recording a new toggle combo makes it fire globally + the old
  one stop; switching the PTT key makes the new key start/stop dictation; Reset
  restores ⌘⇧V / Fn; a modifier-less combo is refused.
