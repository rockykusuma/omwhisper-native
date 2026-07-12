# Custom Dictation Shortcut + PTT Key Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users set their own toggle-dictation keyboard shortcut and push-to-talk key from Settings, applied live without relaunch.

**Architecture:** A `KeyCombo` value type + `PTTKey` enum persisted in UserDefaults. `GlobalHotkey` and `PushToTalkMonitor` gain `reconfigure(...)`; AppState builds them from the stored settings and reconfigures on change. A `KeyRecorderView` captures a combo via a local `NSEvent` monitor. A "Shortcuts" section in General settings hosts both.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSEvent` monitors), `@Observable` AppState.

## Global Constraints

- **Xcode scheme is `omwhisper-native`.** Build/test: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`.
- **Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** — mark the pure data types (`KeyCombo`, `PTTKey`) `nonisolated` so tests and the monitors can use them off MainActor. `GlobalHotkey`/`PushToTalkMonitor` stay `@MainActor`.
- **Defaults unchanged:** unset → ⌘⇧V (keyCode 9, [.command,.shift]) / Fn. Existing users see no change.
- **Validation:** a recorded toggle combo MUST contain at least one of ⌘/⌃/⌥ (a ⇧-only or bare key fires during normal typing).
- **Right-modifier keyCodes:** Right ⌘ = 54, Right ⌥ = 61, Right ⌃ = 62 (standard kVK). Fn has no stable keyCode — detected via the `.function` flag.
- **Settings persistence:** UserDefaults-backed computed properties need `access(keyPath:)`/`withMutation(keyPath:)` (Observation) — see `customPolishStyles` for the JSON pattern.
- Full suite is currently **295**; must stay green.

---

## File Structure

| File | Responsibility |
|---|---|
| `omwhisper-native/Hotkeys/KeyCombo.swift` | New — `KeyCombo` value type + `PTTKey` enum + display/validation/detection |
| `omwhisper-nativeTests/KeyComboTests.swift` | New — display, validation, PTT detection |
| `omwhisper-native/Hotkeys/GlobalHotkey.swift` | `var` keyCode/modifiers + `reconfigure(keyCode:modifiers:)` |
| `omwhisper-native/Hotkeys/PushToTalkMonitor.swift` | `PTTKey` detection + `reconfigure(key:)` |
| `omwhisper-native/AppState.swift` | `dictationShortcut`/`pttKey` settings; init from stored values; reconfigure wiring |
| `omwhisper-native/UI/KeyRecorderView.swift` | New — the combo recorder control |
| `omwhisper-native/UI/GeneralSettingsView.swift` | "Shortcuts" section |

---

## Task 1: KeyCombo + PTTKey (pure data model)

**Files:**
- Create: `omwhisper-native/Hotkeys/KeyCombo.swift`
- Test: `omwhisper-nativeTests/KeyComboTests.swift`

**Interfaces:**
- Produces: `KeyCombo { keyCode: UInt16; modifiers: UInt; label: String }` with `.defaultDictation`, `.flags`, `.hasRequiredModifier`, `.display`, `.relevantMask`; `PTTKey` (`.fn/.rightCommand/.rightOption/.rightControl`) with `.display`, `.pressState(keyCode:flags:) -> Bool?`.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/KeyComboTests.swift`:

```swift
import Testing
import AppKit
@testable import OmWhisper

struct KeyComboTests {
    @Test func displayOrdersModifiersThenLabel() {
        let c = KeyCombo(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "V")
        #expect(c.display == "⇧⌘V")
    }

    @Test func displayFullModifierOrder() {
        let c = KeyCombo(keyCode: 0, modifiers: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue, label: "A")
        #expect(c.display == "⌃⌥⇧⌘A")
    }

    @Test func requiresCommandControlOrOption() {
        let shiftOnly = KeyCombo(keyCode: 9, modifiers: NSEvent.ModifierFlags([.shift]).rawValue, label: "V")
        #expect(shiftOnly.hasRequiredModifier == false)
        let withCmd = KeyCombo(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command]).rawValue, label: "V")
        #expect(withCmd.hasRequiredModifier == true)
    }

    @Test func defaultIsCommandShiftV() {
        #expect(KeyCombo.defaultDictation.display == "⇧⌘V")
    }

    @Test func fnPressStateReadsFunctionFlag() {
        #expect(PTTKey.fn.pressState(keyCode: 999, flags: [.function]) == true)
        #expect(PTTKey.fn.pressState(keyCode: 999, flags: []) == false)
    }

    @Test func rightModifierPressStateMatchesKeyCodeAndFlag() {
        #expect(PTTKey.rightCommand.pressState(keyCode: 54, flags: [.command]) == true)
        #expect(PTTKey.rightCommand.pressState(keyCode: 54, flags: []) == false)
        // A different modifier's event (e.g. shift, keyCode 60) is not this key.
        #expect(PTTKey.rightCommand.pressState(keyCode: 60, flags: [.command]) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "KeyCombo|error:"`
Expected: FAIL — `Cannot find 'KeyCombo'`/`PTTKey` in scope.

- [ ] **Step 3: Create KeyCombo.swift**

```swift
//
//  KeyCombo.swift
//  OmWhisper
//
//  User-configurable dictation trigger data: a recorded keyboard combo for the
//  toggle shortcut, and a curated push-to-talk modifier key. Pure value types —
//  the GlobalHotkey / PushToTalkMonitor monitors consume these.
//

import AppKit

nonisolated struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags rawValue, masked to relevantMask
    var label: String     // base key captured at record time, e.g. "V"

    static let relevantMask: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    static let defaultDictation = KeyCombo(
        keyCode: 9,
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        label: "V")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// A shortcut needs at least one of ⌘/⌃/⌥ — a ⇧-only or bare key would fire
    /// during normal typing.
    var hasRequiredModifier: Bool {
        !flags.intersection([.command, .control, .option]).isEmpty
    }

    /// Canonical glyph order ⌃⌥⇧⌘ + the base key.
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + label
    }
}

nonisolated enum PTTKey: String, CaseIterable, Identifiable {
    case fn, rightCommand, rightOption, rightControl

    var id: String { rawValue }

    var display: String {
        switch self {
        case .fn: "Fn / Globe"
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        }
    }

    /// keyCode + flag for the right-modifier variants; nil for .fn (flag-only —
    /// Fn has no reliable keyCode).
    private var keyCodeAndFlag: (UInt16, NSEvent.ModifierFlags)? {
        switch self {
        case .fn: nil
        case .rightCommand: (54, .command)
        case .rightOption: (61, .option)
        case .rightControl: (62, .control)
        }
    }

    /// Given a `.flagsChanged` event's keyCode + flags, is this PTT key now down?
    /// Returns nil when the event isn't about this key (so the caller ignores it).
    func pressState(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard let (kc, flag) = keyCodeAndFlag else {
            return flags.contains(.function)   // .fn: read the flag every event
        }
        guard keyCode == kc else { return nil }
        return flags.contains(flag)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "KeyComboTests|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: PASS; **301** tests (295 + 6).

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Hotkeys/KeyCombo.swift omwhisper-nativeTests/KeyComboTests.swift
git commit -m "✨ feat(hotkeys): KeyCombo + PTTKey value types with display/validation/detection"
```

---

## Task 2: GlobalHotkey + PushToTalkMonitor reconfigure

Make both monitors reconfigurable at runtime.

**Files:**
- Modify: `omwhisper-native/Hotkeys/GlobalHotkey.swift`
- Modify: `omwhisper-native/Hotkeys/PushToTalkMonitor.swift`

**Interfaces:**
- Consumes: `PTTKey` (Task 1).
- Produces: `GlobalHotkey.reconfigure(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)`; `PushToTalkMonitor.init(key:onStart:onEnd:)` + `reconfigure(key: PTTKey)`.

- [ ] **Step 1: Make GlobalHotkey reconfigurable**

In `GlobalHotkey.swift`, change the stored `keyCode`/`modifiers` from `let` to `var`:

```swift
    private var keyCode: UInt16
    private var modifiers: NSEvent.ModifierFlags
```

Add, after `stop()`:

```swift
    /// Swap the binding and restart (start() stops first). Live shortcut changes.
    func reconfigure(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        start()
    }
```

- [ ] **Step 2: Generalize PushToTalkMonitor to a PTTKey**

In `PushToTalkMonitor.swift`, replace the stored flag-tracking and init/handler. Change `private var isFunctionKeyDown = false` to `private var isKeyDown = false`, add `private var key: PTTKey`, and update:

```swift
    init(key: PTTKey = .fn, onStart: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.key = key
        self.onStart = onStart
        self.onEnd = onEnd
    }

    /// Swap the PTT key and restart (start() stops first, resetting isKeyDown).
    func reconfigure(key: PTTKey) {
        self.key = key
        start()
    }
```

In `stop()`, change `isFunctionKeyDown = false` to `isKeyDown = false`.

Replace `handleFlagsChanged`:

```swift
    private func handleFlagsChanged(_ event: NSEvent) {
        guard let isDown = key.pressState(keyCode: event.keyCode, flags: event.modifierFlags) else { return }
        guard isDown != isKeyDown else { return }
        isKeyDown = isDown
        if isDown { onStart() } else { onEnd() }
    }
```

- [ ] **Step 3: Build + full suite (regression)**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`, **301** tests. (AppState still constructs `PushToTalkMonitor(onStart:onEnd:)` — the `key:` default keeps that call valid until Task 3 passes one.)

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/Hotkeys/GlobalHotkey.swift omwhisper-native/Hotkeys/PushToTalkMonitor.swift
git commit -m "✨ feat(hotkeys): reconfigurable GlobalHotkey + PTTKey-driven PushToTalkMonitor"
```

---

## Task 3: AppState settings + init wiring

Persist the two settings, build the monitors from them, reconfigure on change.

**Files:**
- Modify: `omwhisper-native/AppState.swift` (settings block ~248; hotkey/PTT decls ~724–733; `SettingsKeys` ~1418)

**Interfaces:**
- Consumes: `KeyCombo`, `PTTKey` (Task 1); `GlobalHotkey.reconfigure`, `PushToTalkMonitor.init(key:...)`/`reconfigure` (Task 2).
- Produces: `AppState.dictationShortcut: KeyCombo`, `AppState.pttKey: PTTKey`.

- [ ] **Step 1: Add the settings**

In `AppState.swift`, after the `brainDumpShapes` property (~line 261+), add:

```swift
    // MARK: Custom dictation triggers
    var dictationShortcut: KeyCombo {
        get {
            access(keyPath: \.dictationShortcut)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.dictationShortcut),
                  let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) else {
                return .defaultDictation
            }
            return combo
        }
        set {
            withMutation(keyPath: \.dictationShortcut) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.dictationShortcut)
            }
            hotkey.reconfigure(keyCode: newValue.keyCode, modifiers: newValue.flags)
        }
    }
    var pttKey: PTTKey {
        get {
            access(keyPath: \.pttKey)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.pttKey),
                  let k = PTTKey(rawValue: raw) else { return .fn }
            return k
        }
        set {
            withMutation(keyPath: \.pttKey) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.pttKey)
            }
            pushToTalk.reconfigure(key: newValue)
        }
    }
```

- [ ] **Step 2: Add the SettingsKeys**

In `SettingsKeys` (~line 1418), add:

```swift
    static let dictationShortcut = "dictationShortcut"
    static let pttKey = "pttKey"
```

- [ ] **Step 3: Build the monitors from the stored settings**

Replace the `hotkey`/`pushToTalk` declarations (~lines 724–733):

```swift
    @ObservationIgnored private lazy var hotkey = GlobalHotkey(
        keyCode: dictationShortcut.keyCode,
        modifiers: dictationShortcut.flags
    ) { [weak self] in
        self?.toggleDictation()
    }
    @ObservationIgnored private lazy var pushToTalk = PushToTalkMonitor(
        key: pttKey,
        onStart: { [weak self] in self?.beginPushToTalk() },
        onEnd: { [weak self] in self?.endPushToTalk() }
    )
```

- [ ] **Step 4: Build + full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`, **301** tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(hotkeys): AppState dictationShortcut/pttKey settings + reconfigure wiring"
```

---

## Task 4: KeyRecorderView

The combo recorder control.

**Files:**
- Create: `omwhisper-native/UI/KeyRecorderView.swift`

**Interfaces:**
- Consumes: `KeyCombo` (Task 1).
- Produces: `KeyRecorderView(combo: Binding<KeyCombo>)`.

- [ ] **Step 1: Create the view**

```swift
//
//  KeyRecorderView.swift
//  OmWhisper
//
//  Records a keyboard shortcut for a KeyCombo binding. Click → "Press keys…" →
//  the next keyDown (captured by a LOCAL NSEvent monitor, so it never leaks into
//  a field) becomes the combo, provided it has a ⌘/⌃/⌥ modifier. Esc cancels.
//

import SwiftUI
import AppKit

struct KeyRecorderView: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? "Press keys…" : combo.display) {
                recording ? stop() : startRecording()
            }
            .buttonStyle(.bordered)
            .tint(Color.Porcelain.emerald)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func startRecording() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // swallow keystrokes while recording
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }   // Esc = cancel, keep old combo
        let mods = event.modifierFlags.intersection(KeyCombo.relevantMask)
        let candidate = KeyCombo(
            keyCode: event.keyCode,
            modifiers: mods.rawValue,
            label: (event.charactersIgnoringModifiers ?? "").uppercased())
        guard candidate.hasRequiredModifier, !candidate.label.isEmpty else {
            hint = "Use at least one of ⌘ ⌃ ⌥."
            return   // stay recording
        }
        combo = candidate
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/KeyRecorderView.swift
git commit -m "✨ feat(hotkeys): KeyRecorderView shortcut recorder control"
```

---

## Task 5: General settings — Shortcuts section

**Files:**
- Modify: `omwhisper-native/UI/GeneralSettingsView.swift` (after the "General" section, ~line 55)

**Interfaces:**
- Consumes: `state.dictationShortcut`, `state.pttKey` (Task 3); `KeyRecorderView` (Task 4); `PTTKey` (Task 1).

- [ ] **Step 1: Add the Shortcuts section**

In `GeneralSettingsView.body`, after the `PorcelainSection(eyebrow: "General") { … }` block (~line 55), insert:

```swift
            PorcelainSection(eyebrow: "Shortcuts") {
                HStack {
                    Text("Toggle dictation").foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    KeyRecorderView(combo: $state.dictationShortcut)
                }
                HStack {
                    Text("Push-to-talk").foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    Picker("", selection: $state.pttKey) {
                        ForEach(PTTKey.allCases) { Text($0.display).tag($0) }
                    }
                    .labelsHidden()
                    .tint(Color.Porcelain.emerald)
                }
                if state.pttKey == .rightOption {
                    Text("Right ⌥ is also Reply Assist's double-tap gesture — they may interfere.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                }
                Button("Reset to defaults") {
                    state.dictationShortcut = .defaultDictation
                    state.pttKey = .fn
                }
                .tint(Color.Porcelain.emerald)
            }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/GeneralSettingsView.swift
git commit -m "✨ feat(hotkeys): Shortcuts section in General settings (recorder + PTT picker + reset)"
```

---

## Live verification (after all tasks, on real hardware)

1. **Record a toggle shortcut** — Settings → General → Shortcuts → click the toggle recorder, press e.g. ⌃⌥Space. It displays "⌃⌥Space"; the new combo now starts/stops dictation globally, and the old ⌘⇧V no longer does.
2. **Reject bare combo** — click record, press just a letter (no ⌘/⌃/⌥) → "Use at least one of ⌘ ⌃ ⌥", stays recording.
3. **Esc cancels** — record → Esc → keeps the previous combo.
4. **Change PTT key** — pick Right ⌘; holding Right ⌘ starts dictation, releasing stops. Fn no longer does.
5. **Right ⌥ caution** — selecting Right ⌥ shows the Reply Assist overlap note.
6. **Reset** — Reset to defaults restores ⌘⇧V / Fn (both fire again).
7. **No regression** — with no changes made, ⌘⇧V and Fn work exactly as before (defaults).

## Self-Review

- **Spec coverage:** data model → Task 1; reconfigure → Task 2; settings/init → Task 3; recorder → Task 4; settings UI → Task 5. All spec sections mapped.
- **Placeholders:** none — every code step is complete, reusing verified patterns (the UserDefaults JSON setting from `customPolishStyles`, the `GlobalHotkey`/`PushToTalkMonitor` structure, the `PorcelainSection` layout).
- **Type consistency:** `KeyCombo`(keyCode/modifiers/label/flags/hasRequiredModifier/display/defaultDictation/relevantMask), `PTTKey`(pressState/display), `reconfigure(keyCode:modifiers:)`, `reconfigure(key:)`, `dictationShortcut`, `pttKey`, `KeyRecorderView(combo:)` are named identically across every task and call site.
