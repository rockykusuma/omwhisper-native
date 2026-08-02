# Configurable Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Smart Dictation, Polish Selected Text and Brain-dump be reassigned or switched off, so OmWhisper stops firing on a shortcut you want another app to own.

**Architecture:** A pure `ShortcutValidation` decides whether a proposed combo conflicts with another OmWhisper feature or a reserved system combo. Three new `KeyCombo?` settings copy `dictationShortcut`'s proven persistence-and-reconfigure pattern exactly, with nil meaning the feature's `GlobalHotkey` is stopped. The Shortcuts section gains three rows plus a monitor-health line.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSEvent` monitors), UserDefaults, Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-02-configurable-shortcuts-design.md`. Read it before Task 1.
- **`GlobalHotkey` uses `NSEvent.addGlobalMonitorForEvents`, not Carbon.** A global monitor *observes*; it never owns a combo and never fails because another app holds it. **Do not add "another app has this shortcut" detection** — there is no supported API, and a false "no conflict" is a promise the app cannot keep.
- **Dictation cannot be disabled.** `dictationShortcut` stays non-optional; only the other three take `KeyCombo?`, where nil = the feature's hotkey is stopped.
- **`access(keyPath:)` / `withMutation(keyPath:)` are mandatory** on every new setting. A plain computed property over `UserDefaults` never notifies `@Observable`, which in this codebase has repeatedly shipped UI that silently fails to redraw.
- **Setters must reconfigure the live hotkey**, matching `dictationShortcut`. Do not capture a combo once at wiring time — that exact mistake left the chronicle scheduler using a stale backend.
- **Reserved system combos** to reject: ⌘Space, ⌘Tab, ⌘Q, ⌘W, ⌘H, ⌘M.
- **`KeyCombo` already exists** with `keyCode: UInt16`, `modifiers: UInt`, `label: String`, plus `flags`, `hasRequiredModifier`, `display`. Do not redefine it.
- **`KeyRecorderView(combo:)` already exists** and is bound to `dictationShortcut` in `GeneralSettingsView`. Reuse it.
- **Build/test:** `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteName>`.
- Suite is at **464 tests in 65 suites** before this plan. It must never go down.

---

### Task 1: The pure conflict rule

**Files:**
- Create: `omwhisper-native/Hotkeys/ShortcutValidation.swift`
- Test: `omwhisper-nativeTests/ShortcutValidationTests.swift`

**Interfaces:**
- Consumes: `KeyCombo` (existing).
- Produces:
  - `ShortcutSlot` — `enum: String, CaseIterable { case dictation, smartDictation, polishSelected, brainDump }`, with `title: String`
  - `ShortcutValidation.Conflict` — `enum { case alreadyUsed(by: ShortcutSlot); case reserved }`, `Equatable`, with `message: String`
  - `ShortcutValidation.conflict(for combo: KeyCombo, assigning slot: ShortcutSlot, current: [ShortcutSlot: KeyCombo]) -> Conflict?`
  - `ShortcutValidation.reservedCombos: [KeyCombo]`

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/ShortcutValidationTests.swift`:

```swift
//
//  ShortcutValidationTests.swift
//  omwhisper-nativeTests
//
//  Only conflicts OmWhisper can PROVE: duplicates among its own shortcuts and
//  reserved system combos. Another app's bindings are undetectable via NSEvent
//  monitors, so nothing here claims to know about them.
//

import AppKit
import Testing
@testable import OmWhisper

struct ShortcutValidationTests {
    private func combo(_ keyCode: UInt16, _ label: String,
                       _ mods: NSEvent.ModifierFlags = [.command, .shift]) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: mods.rawValue, label: label)
    }

    @Test("a combo held by another feature is rejected, naming the holder")
    func rejectsDuplicateAcrossFeatures() {
        let taken = combo(9, "V")
        let result = ShortcutValidation.conflict(
            for: taken, assigning: .polishSelected,
            current: [.dictation: taken])
        #expect(result == .alreadyUsed(by: .dictation))
        #expect(result?.message.contains("dictation") == true
                || result?.message.contains("Dictation") == true)
    }

    @Test("reassigning a feature to its OWN current combo is not a conflict")
    func ownComboIsNotAConflict() {
        // A naive "is this in use?" check gets this wrong and makes a shortcut
        // unsavable once set — you could never re-record the same keys.
        let mine = combo(35, "P")
        let result = ShortcutValidation.conflict(
            for: mine, assigning: .polishSelected,
            current: [.polishSelected: mine, .dictation: combo(9, "V")])
        #expect(result == nil)
    }

    @Test("two disabled features are not in conflict")
    func disabledFeaturesDoNotClash() {
        // Absent slots mean "disabled". A naive equality check over optionals
        // treats nil == nil as a duplicate and blocks disabling the second one.
        let proposed = combo(2, "D")
        let result = ShortcutValidation.conflict(
            for: proposed, assigning: .brainDump,
            current: [.dictation: combo(9, "V")])   // smartDictation & polishSelected absent
        #expect(result == nil)
    }

    @Test("reserved system combos are rejected")
    func rejectsReservedCombos() {
        for reserved in ShortcutValidation.reservedCombos {
            let result = ShortcutValidation.conflict(
                for: reserved, assigning: .brainDump, current: [:])
            #expect(result == .reserved, "should have reserved \(reserved.display)")
        }
        #expect(ShortcutValidation.reservedCombos.count >= 6)
    }

    @Test("an unused combo is accepted")
    func acceptsFreeCombo() {
        let result = ShortcutValidation.conflict(
            for: combo(17, "T", [.command, .control]),
            assigning: .brainDump,
            current: [.dictation: combo(9, "V"), .polishSelected: combo(35, "P")])
        #expect(result == nil)
    }

    @Test("same key, different modifiers, is a different shortcut")
    func modifiersDistinguishCombos() {
        let result = ShortcutValidation.conflict(
            for: combo(9, "V", [.command, .option]),
            assigning: .polishSelected,
            current: [.dictation: combo(9, "V", [.command, .shift])])
        #expect(result == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ShortcutValidationTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: build FAILS with "cannot find 'ShortcutValidation' in scope".

- [ ] **Step 3: Write the implementation**

Create `omwhisper-native/Hotkeys/ShortcutValidation.swift`:

```swift
//
//  ShortcutValidation.swift
//  OmWhisper
//
//  Whether a proposed shortcut can be assigned. Guards ONLY what is provable:
//  a duplicate among OmWhisper's own shortcuts, and reserved system combos.
//
//  It deliberately does NOT try to detect other applications' shortcuts.
//  GlobalHotkey uses NSEvent.addGlobalMonitorForEvents, which observes rather
//  than owns -- it never fails because another app holds a combo, and there is
//  no supported API to enumerate what other apps have bound. A false
//  "no conflict" would be a promise the app cannot keep.
//

import AppKit

nonisolated enum ShortcutSlot: String, CaseIterable, Identifiable {
    case dictation, smartDictation, polishSelected, brainDump

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Toggle dictation"
        case .smartDictation: "Smart Dictation"
        case .polishSelected: "Polish Selected Text"
        case .brainDump: "Brain-dump"
        }
    }
}

nonisolated enum ShortcutValidation {
    enum Conflict: Equatable {
        case alreadyUsed(by: ShortcutSlot)
        case reserved

        var message: String {
            switch self {
            case .alreadyUsed(let slot):
                "Already used by \(slot.title)."
            case .reserved:
                "That combination is reserved by macOS."
            }
        }
    }

    /// Combos macOS itself owns. Assigning these would either never fire or
    /// break something the user needs more than a dictation shortcut.
    static let reservedCombos: [KeyCombo] = [
        KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "Space"),
        KeyCombo(keyCode: 48, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "Tab"),
        KeyCombo(keyCode: 12, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "Q"),
        KeyCombo(keyCode: 13, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "W"),
        KeyCombo(keyCode: 4, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "H"),
        KeyCombo(keyCode: 46, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "M"),
    ]

    /// nil when `combo` may be assigned to `slot`.
    ///
    /// `current` holds only the slots that HAVE a shortcut -- an absent slot is
    /// a disabled feature, so two disabled features can never collide.
    static func conflict(
        for combo: KeyCombo,
        assigning slot: ShortcutSlot,
        current: [ShortcutSlot: KeyCombo]
    ) -> Conflict? {
        if reservedCombos.contains(where: { sameBinding($0, combo) }) { return .reserved }
        // Skip the slot being assigned: re-recording the keys a feature already
        // has is not a conflict with itself.
        for (other, assigned) in current where other != slot {
            if sameBinding(assigned, combo) { return .alreadyUsed(by: other) }
        }
        return nil
    }

    /// Same key AND same modifiers. `label` is display-only and is deliberately
    /// ignored: the same physical key can be captured with a different label
    /// under a different keyboard layout.
    private static func sameBinding(_ a: KeyCombo, _ b: KeyCombo) -> Bool {
        a.keyCode == b.keyCode
            && a.flags.intersection(KeyCombo.relevantMask) == b.flags.intersection(KeyCombo.relevantMask)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ShortcutValidationTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with|recorded an issue"`

Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Hotkeys/ShortcutValidation.swift omwhisper-nativeTests/ShortcutValidationTests.swift
git commit -m "✨ feat(hotkeys): pure shortcut conflict rule"
```

---

### Task 2: Three settable shortcuts

**Files:**
- Modify: `omwhisper-native/AppState.swift`
- Modify: `omwhisper-native/Hotkeys/GlobalHotkey.swift`

**Interfaces:**
- Consumes: `ShortcutSlot`, `KeyCombo`.
- Produces:
  - `AppState.smartDictationShortcut: KeyCombo?`
  - `AppState.polishSelectedShortcut: KeyCombo?`
  - `AppState.brainDumpShortcut: KeyCombo?`
  - `AppState.assignedShortcuts: [ShortcutSlot: KeyCombo]`
  - `AppState.defaultShortcut(for: ShortcutSlot) -> KeyCombo`
  - `GlobalHotkey.isInstalled: Bool`
  - `SettingsKeys.smartDictationShortcut`, `.polishSelectedShortcut`, `.brainDumpShortcut`

- [ ] **Step 1: Expose monitor health on `GlobalHotkey`**

In `omwhisper-native/Hotkeys/GlobalHotkey.swift`, add after the `localMonitor` property declaration:

```swift
    /// False when `start()` ran but AppKit refused the global monitor — which
    /// happens when the process isn't Accessibility-trusted. The shortcut then
    /// looks correctly configured and silently never fires, which is exactly
    /// the failure this app keeps hitting.
    var isInstalled: Bool { globalMonitor != nil }
```

- [ ] **Step 2: Add the three settings to `AppState`**

In `omwhisper-native/AppState.swift`, immediately after the `dictationShortcut` computed property's closing brace, add:

```swift
    /// nil means the feature has no global shortcut — its hotkey is stopped,
    /// not merely reassigned somewhere unreachable. Dictation deliberately has
    /// no such option: an app with no way to dictate is broken, not configured.
    var smartDictationShortcut: KeyCombo? {
        get {
            access(keyPath: \.smartDictationShortcut)
            return Self.decodeShortcut(SettingsKeys.smartDictationShortcut,
                                       default: Self.defaultSmartDictation)
        }
        set {
            withMutation(keyPath: \.smartDictationShortcut) {
                Self.encodeShortcut(newValue, SettingsKeys.smartDictationShortcut)
            }
            Self.apply(newValue, to: smartDictationHotkey)
        }
    }

    var polishSelectedShortcut: KeyCombo? {
        get {
            access(keyPath: \.polishSelectedShortcut)
            return Self.decodeShortcut(SettingsKeys.polishSelectedShortcut,
                                       default: Self.defaultPolishSelected)
        }
        set {
            withMutation(keyPath: \.polishSelectedShortcut) {
                Self.encodeShortcut(newValue, SettingsKeys.polishSelectedShortcut)
            }
            Self.apply(newValue, to: polishSelectedTextHotkey)
        }
    }

    var brainDumpShortcut: KeyCombo? {
        get {
            access(keyPath: \.brainDumpShortcut)
            return Self.decodeShortcut(SettingsKeys.brainDumpShortcut, default: Self.defaultBrainDump)
        }
        set {
            withMutation(keyPath: \.brainDumpShortcut) {
                Self.encodeShortcut(newValue, SettingsKeys.brainDumpShortcut)
            }
            Self.apply(newValue, to: brainDumpHotkey)
        }
    }

    static let defaultSmartDictation = KeyCombo(
        keyCode: 11, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "B")
    static let defaultPolishSelected = KeyCombo(
        keyCode: 35, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "P")
    static let defaultBrainDump = KeyCombo(
        keyCode: 2, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "D")

    func defaultShortcut(for slot: ShortcutSlot) -> KeyCombo {
        switch slot {
        case .dictation: .defaultDictation
        case .smartDictation: Self.defaultSmartDictation
        case .polishSelected: Self.defaultPolishSelected
        case .brainDump: Self.defaultBrainDump
        }
    }

    /// Only the slots that currently HAVE a shortcut. Absent = disabled, which
    /// is what lets ShortcutValidation treat two disabled features as
    /// non-conflicting rather than both-nil-therefore-equal.
    var assignedShortcuts: [ShortcutSlot: KeyCombo] {
        var out: [ShortcutSlot: KeyCombo] = [.dictation: dictationShortcut]
        if let combo = smartDictationShortcut { out[.smartDictation] = combo }
        if let combo = polishSelectedShortcut { out[.polishSelected] = combo }
        if let combo = brainDumpShortcut { out[.brainDump] = combo }
        return out
    }

    /// Three states, not two: an explicit "disabled" marker, a stored combo, or
    /// nothing stored yet (first run) which means the built-in default.
    private static let disabledMarker = "disabled"

    private static func decodeShortcut(_ key: String, default fallback: KeyCombo) -> KeyCombo? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: key) == disabledMarker { return nil }
        guard let data = defaults.data(forKey: key) else { return fallback }
        // Corrupt stored JSON falls back to the default rather than leaving the
        // feature permanently unreachable.
        return (try? JSONDecoder().decode(KeyCombo.self, from: data)) ?? fallback
    }

    private static func encodeShortcut(_ combo: KeyCombo?, _ key: String) {
        let defaults = UserDefaults.standard
        guard let combo else {
            defaults.set(disabledMarker, forKey: key)
            return
        }
        defaults.set(try? JSONEncoder().encode(combo), forKey: key)
    }

    private static func apply(_ combo: KeyCombo?, to hotkey: GlobalHotkey) {
        guard let combo else {
            hotkey.stop()
            return
        }
        hotkey.reconfigure(keyCode: combo.keyCode, modifiers: combo.flags)
    }
```

- [ ] **Step 3: Make the three hotkeys read their settings**

In `omwhisper-native/AppState.swift`, replace the three hardcoded `keyCode:`/`modifiers:` initialisers. Replace:

```swift
    @ObservationIgnored private lazy var smartDictationHotkey = GlobalHotkey(
        keyCode: 11,
```

with:

```swift
    @ObservationIgnored private lazy var smartDictationHotkey = GlobalHotkey(
        keyCode: smartDictationShortcut?.keyCode ?? Self.defaultSmartDictation.keyCode,
```

Replace:

```swift
    @ObservationIgnored private lazy var polishSelectedTextHotkey = GlobalHotkey(
        keyCode: 35,
```

with:

```swift
    @ObservationIgnored private lazy var polishSelectedTextHotkey = GlobalHotkey(
        keyCode: polishSelectedShortcut?.keyCode ?? Self.defaultPolishSelected.keyCode,
```

Replace:

```swift
    @ObservationIgnored private lazy var brainDumpHotkey = GlobalHotkey(
        keyCode: 2,
```

with:

```swift
    @ObservationIgnored private lazy var brainDumpHotkey = GlobalHotkey(
        keyCode: brainDumpShortcut?.keyCode ?? Self.defaultBrainDump.keyCode,
```

Then find where these three hotkeys are started (search for `smartDictationHotkey.start()`), and guard each so a disabled shortcut never installs a monitor. Replace the three `.start()` calls with:

```swift
        if smartDictationShortcut != nil { smartDictationHotkey.start() }
        if polishSelectedShortcut != nil { polishSelectedTextHotkey.start() }
        if brainDumpShortcut != nil { brainDumpHotkey.start() }
```

- [ ] **Step 4: Add the three settings keys**

In `omwhisper-native/AppState.swift`, in the `SettingsKeys` enum beside `dictationShortcut`:

```swift
    static let smartDictationShortcut = "smartDictationShortcut"
    static let polishSelectedShortcut = "polishSelectedShortcut"
    static let brainDumpShortcut = "brainDumpShortcut"
```

- [ ] **Step 5: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 470 tests PASS (464 + Task 1's 6).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/Hotkeys/GlobalHotkey.swift
git commit -m "✨ feat(hotkeys): Smart Dictation, Polish Selected and Brain-dump are settable"
```

---

### Task 3: The Shortcuts UI

**Files:**
- Modify: `omwhisper-native/UI/GeneralSettingsView.swift`

**Interfaces:**
- Consumes: `AppState.smartDictationShortcut`, `.polishSelectedShortcut`, `.brainDumpShortcut`, `.assignedShortcuts`, `.defaultShortcut(for:)`, `ShortcutSlot`, `ShortcutValidation.conflict(for:assigning:current:)`, `GlobalHotkey.isInstalled`.
- Produces: nothing for later tasks.

No unit tests — SwiftUI layout and the recorder are verified live, matching this project's convention.

- [ ] **Step 1: Add the three rows and the health line**

In `omwhisper-native/UI/GeneralSettingsView.swift`, inside the `PorcelainSection(eyebrow: "Shortcuts")`, immediately after the existing "Toggle dictation" `HStack`, add:

```swift
                // Three of four shortcuts used to be hardcoded. NSEvent global
                // monitors observe rather than own, so a combo another app uses
                // fires BOTH — OmWhisper then bails silently. Being able to turn
                // one off is the direct fix, not only moving it.
                optionalShortcutRow(.smartDictation, combo: $state.smartDictationShortcut)
                optionalShortcutRow(.polishSelected, combo: $state.polishSelectedShortcut)
                optionalShortcutRow(.brainDump, combo: $state.brainDumpShortcut)

                if let conflictMessage {
                    Text(conflictMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !appState.hasAccessibilityPermission {
                    Text("Shortcuts need Accessibility to fire in other apps. Until it's granted they're saved but inactive.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

Then, still inside the same section, extend the existing "Reset to defaults" button body to cover the new settings. Replace:

```swift
                Button("Reset to defaults") {
                    state.dictationShortcut = .defaultDictation
                    state.pttKey = .fn
                }
```

with:

```swift
                Button("Reset to defaults") {
                    state.dictationShortcut = .defaultDictation
                    state.smartDictationShortcut = AppState.defaultSmartDictation
                    state.polishSelectedShortcut = AppState.defaultPolishSelected
                    state.brainDumpShortcut = AppState.defaultBrainDump
                    state.pttKey = .fn
                    conflictMessage = nil
                }
```

- [ ] **Step 2: Add the row builder and validation state**

In the same file, add `@State private var conflictMessage: String?` beside the view's other `@State` properties, then add this method to the view:

```swift
    /// A shortcut row that can also be turned off. Validation runs on the way
    /// in, so an unusable assignment can't be saved — the alternative is a
    /// shortcut that looks correct in the UI and silently never fires.
    private func optionalShortcutRow(_ slot: ShortcutSlot, combo: Binding<KeyCombo?>) -> some View {
        @Bindable var state = appState
        return HStack {
            Text(slot.title).foregroundStyle(Color.Porcelain.ink)
            Spacer()
            if let existing = combo.wrappedValue {
                KeyRecorderView(combo: Binding(
                    get: { existing },
                    set: { proposed in
                        if let conflict = ShortcutValidation.conflict(
                            for: proposed, assigning: slot, current: appState.assignedShortcuts) {
                            conflictMessage = "\(slot.title): \(conflict.message)"
                        } else {
                            conflictMessage = nil
                            combo.wrappedValue = proposed
                        }
                    }))
                Button("Off") { combo.wrappedValue = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Porcelain.mint)
            } else {
                Text("Off").foregroundStyle(Color.Porcelain.dim)
                Button("Set") { combo.wrappedValue = appState.defaultShortcut(for: slot) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Porcelain.mint)
            }
        }
    }
```

- [ ] **Step 3: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 470 tests PASS. If the compiler cannot find `hasAccessibilityPermission`, check its actual name on `AppState` (it is used by `HubMemorySectionView`'s accessibility banner) and use that — do not invent a new property.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/GeneralSettingsView.swift
git commit -m "✨ feat(hotkeys): Shortcuts settings rows with off switches and conflict messages"
```

- [ ] **Step 5: Live verification — checks that can fail**

1. Run the debug build (⌘R), open Hub → Settings → Shortcuts. All four rows appear, three with an **Off** button.
2. **Reassign:** set Polish Selected to an unused combo — ⌃⌥P is a safe choice. Select text in TextEdit and press it. **Pass:** polish runs (text is replaced, or the Apple-Intelligence alert appears on this Mac). **Fail:** nothing happens.
3. **Disable:** set Polish Selected to **Off**. Press the combo from step 2 again. **Pass:** nothing happens. Then press ⌘⇧V — **dictation still starts**, proving one hotkey stopping didn't stop the others.
4. **Duplicate rejected:** try to assign ⌘⇧V (dictation's combo) to Brain-dump. **Pass:** a red message naming *Toggle dictation*, and the assignment is not saved. **Fail:** it saves — and one of the two features would then silently never fire.
5. **Re-record the same keys:** assign Brain-dump to its own current combo again. **Pass:** accepted, no error. This is the case a naive "is it in use?" check breaks.
6. **Both off:** set Smart Dictation and Brain-dump both to Off. **Pass:** both save. **Fail:** the second is rejected as a duplicate of the first — the nil == nil bug.
7. **Survives relaunch:** quit and relaunch; the assignments and Off states are as you left them.
8. **Reset:** press Reset to defaults; all four return to ⌘⇧V / ⌘⇧B / ⌘⇧P / ⌘⇧D.

- [ ] **Step 6: Record the result**

Append the outcome to the Progress Tracker in `CLAUDE.md` and commit. If step 4 or 6 failed, stop and debug rather than recording the feature as shipped.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| All four configurable; three can be disabled | 2 (`KeyCombo?` × 3), 3 (Off buttons) |
| Dictation cannot be disabled | 2 — `dictationShortcut` untouched, non-optional |
| Duplicate within OmWhisper rejected, naming the holder | 1 (`alreadyUsed(by:)`), 3 (message) |
| Reserved system combos rejected | 1 (`reservedCombos`) |
| No detection of other apps' shortcuts | not implemented — by design; stated in the file header |
| Monitor health surfaced | 2 (`isInstalled`), 3 (Accessibility line) |
| `access`/`withMutation` on new settings | 2 |
| Setter reconfigures the live hotkey | 2 (`apply(_:to:)`) |
| nil stops the hotkey rather than reassigning it | 2 (`apply` → `hotkey.stop()`) |
| Corrupt JSON falls back to the default | 2 (`decodeShortcut`) |
| Own-combo re-record is not a conflict | 1 (`ownComboIsNotAConflict`) |
| Two disabled features don't clash | 1 (`disabledFeaturesDoNotClash`), 2 (`assignedShortcuts` omits nils) |
| Live checks | 3 step 5 |

**Placeholders:** none — every code step carries full source. Task 3 step 3 contains one instruction to verify `hasAccessibilityPermission`'s real name rather than invent one; that is a verification instruction, not a gap.

**Type consistency:** `ShortcutSlot` and `ShortcutValidation.conflict(for:assigning:current:)` are defined in Task 1 and called with those exact labels in Task 3. `assignedShortcuts` returns `[ShortcutSlot: KeyCombo]` in Task 2 and is passed as `current:` in Task 3. `defaultShortcut(for:)` is defined in Task 2 and called in Task 3's `Set` button.

**One risk called out rather than designed away:** the three hotkeys are `lazy var`s that read their setting at first access. If any is touched before `UserDefaults` is readable, it captures the default and a stored custom combo would be ignored until the setter runs. The `.start()` guards in Task 2 step 3 force evaluation at wiring time, after settings are available — but if a shortcut ever appears stuck on its default, this laziness is the first place to look.
