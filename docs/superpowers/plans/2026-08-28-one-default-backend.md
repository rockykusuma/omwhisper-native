# One default backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "Default" resolve through one setting for all five AI features, and turn "Disabled" from a backend value into dictation polish's own toggle.

**Architecture:** `dictationPolishEnabled` replaces `polishBackend`'s Disabled case. `activePolishBackend` falls through to `defaultBackend` instead of `polishBackend`, via a new pure resolver mirroring `LongFormBackends`. A one-time pure migration copies the old global into the two feature slots it actually governed — never into the global, which would silently route meeting transcripts to cloud.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), SwiftUI, Swift Testing, UserDefaults.

**Spec:** `docs/superpowers/specs/2026-08-28-one-default-backend-design.md`

## Global Constraints

- **Mark every new type `nonisolated`.** This project defaults declarations to `@MainActor`; an unannotated type cannot be called from a plain test function. Has bitten `ParakeetEngine`, `MCPServer`, `CloudEngine`, `OllamaPresence`.
- **No test may construct `AppState`** — it opens the real history and memory stores and touches the real Keychain (the `KeychainTests` trap).
- **The migration must never write `defaultAIBackend`, `aiBackend.meetings`, `aiBackend.chronicles` or `aiBackend.brainDump`.** `polishBackend` governed only dictation polish and Reply Assist. Writing it to the global would route recorded calls and chronicles to whatever polish backend the user had, cloud included — a privacy regression with nothing visible on screen.
- **`dictationPolishEnabled` defaults to `false`.** `polishBackend` defaults to `.disabled` today, so polish is off on a fresh install; defaulting to `true` is a product change disguised as a refactor.
- **Cloud stays unreachable as a fallback.** No change to `LongFormBackends.candidates`.
- Build: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build`
- Test: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test`
- Baseline before starting: **620 tests in 93 suites**.

---

### Task 1: The migration, as a pure plan

**Files:**
- Create: `omwhisper-native/Polish/PolishBackendMigration.swift`
- Test: `omwhisper-nativeTests/PolishBackendMigrationTests.swift`

**Interfaces:**
- Consumes: `FeatureBackend` from `omwhisper-native/Polish/AIFeature.swift` — cases `useDefault | system | ollama(model: String) | cloud`, `init?(rawValue:)`, `var rawValue: String` encoding as `"default" | "system" | "cloud" | "ollama:<model>"`.
- Produces: `PolishBackendMigration.Plan` (fields `dictationPolishEnabled: Bool`, `dictationBackend: FeatureBackend?`, `replyAssistBackend: FeatureBackend?`) and `PolishBackendMigration.plan(old:existingDictation:existingReplyAssist:ollamaModel:) -> Plan`. Task 2 calls this once from `AppState.init()`.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/PolishBackendMigrationTests.swift`:

```swift
import Testing
@testable import OmWhisper

/// `polishBackend` governed exactly two features: dictation polish and Reply
/// Assist, when those were left on Default. Migrating it anywhere else changes
/// where data goes without anything appearing on screen.
struct PolishBackendMigrationTests {
    @Test func absentKeyChangesNothing() {
        let p = PolishBackendMigration.plan(old: nil, existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationPolishEnabled == false)
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
    }

    @Test func disabledTurnsTheFeatureOffAndTouchesNoBackend() {
        let p = PolishBackendMigration.plan(old: "disabled", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationPolishEnabled == false)
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
    }

    @Test func systemMigratesToBothShortFormFeatures() {
        let p = PolishBackendMigration.plan(old: "system", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationPolishEnabled)
        #expect(p.dictationBackend == .system)
        #expect(p.replyAssistBackend == .system)
    }

    @Test func cloudMigratesToBothShortFormFeatures() {
        let p = PolishBackendMigration.plan(old: "cloud", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationBackend == .cloud)
        #expect(p.replyAssistBackend == .cloud)
    }

    /// The old global stored only the KIND; the model lived in `ollamaModel`.
    /// Dropping it would migrate to an Ollama backend with no model, which
    /// resolves to nil and silently stops polishing.
    @Test func ollamaCarriesTheModelAcross() {
        let p = PolishBackendMigration.plan(old: "ollama", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault,
                                            ollamaModel: "qwen3.5:latest")
        #expect(p.dictationBackend == .ollama(model: "qwen3.5:latest"))
        #expect(p.replyAssistBackend == .ollama(model: "qwen3.5:latest"))
    }

    @Test func anExplicitPerFeatureChoiceIsNeverOverwritten() {
        let p = PolishBackendMigration.plan(old: "cloud", existingDictation: .system,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationBackend == nil, "an explicit choice was overwritten")
        #expect(p.replyAssistBackend == .cloud)
    }

    /// The spec's load-bearing rule, enforced by the TYPE: Plan has no field for
    /// the global or for any long-form feature, so the privacy regression is
    /// unrepresentable. This pins the field set so adding one is a deliberate
    /// act that turns a test red rather than a quiet change.
    @Test func planCannotNameTheGlobalOrALongFormFeature() {
        let fields = Mirror(reflecting: PolishBackendMigration.Plan(
            dictationPolishEnabled: false, dictationBackend: nil, replyAssistBackend: nil
        )).children.compactMap(\.label).sorted()
        #expect(fields == ["dictationBackend", "dictationPolishEnabled", "replyAssistBackend"])
    }

    /// A value we do not recognise must not enable a feature that was off.
    @Test func anUnrecognisedValueIsTreatedAsNothingToDo() {
        let p = PolishBackendMigration.plan(old: "gibberish", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationPolishEnabled == false)
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with"`

Expected: FAIL to compile — `cannot find 'PolishBackendMigration' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `omwhisper-native/Polish/PolishBackendMigration.swift`:

```swift
//
//  PolishBackendMigration.swift
//  OmWhisper
//
//  One-time move from the old global `polishBackend` to per-feature slots.
//
//  The rule that matters is what this does NOT touch. `polishBackend` governed
//  dictation polish and Reply Assist, and only when those were left on Default.
//  Meetings, chronicles and brain-dump have always resolved through
//  `defaultBackend`. Writing the old global into `defaultAIBackend` would
//  therefore move a recorded call's transcript to whatever the user had picked
//  for polishing a sentence — cloud included — with nothing on screen changing.
//
//  `Plan` has no field for the global or for the long-form features, so that
//  mistake is unrepresentable rather than merely discouraged.
//

import Foundation

nonisolated enum PolishBackendMigration {
    struct Plan: Equatable {
        var dictationPolishEnabled: Bool
        /// nil means "leave that slot exactly as it is".
        var dictationBackend: FeatureBackend?
        var replyAssistBackend: FeatureBackend?
    }

    /// `old` is the raw stored `polishBackend` string, nil when absent.
    /// `ollamaModel` is the separate setting the old global did not carry.
    static func plan(old: String?,
                     existingDictation: FeatureBackend,
                     existingReplyAssist: FeatureBackend,
                     ollamaModel: String) -> Plan {
        let off = Plan(dictationPolishEnabled: false, dictationBackend: nil, replyAssistBackend: nil)
        guard let old else { return off }

        let migrated: FeatureBackend
        switch old {
        case "disabled": return off
        case "system":   migrated = .system
        case "cloud":    migrated = .cloud
        case "ollama":   migrated = .ollama(model: ollamaModel)
        default:         return off   // unrecognised must not switch anything on
        }

        // Only fill a slot the user never set themselves.
        func fill(_ existing: FeatureBackend) -> FeatureBackend? {
            existing == .useDefault ? migrated : nil
        }
        return Plan(dictationPolishEnabled: true,
                    dictationBackend: fill(existingDictation),
                    replyAssistBackend: fill(existingReplyAssist))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"`

Expected: PASS, **628 tests in 94 suites**.

- [ ] **Step 5: Prove the overwrite guard can fail**

Temporarily change `fill` to ignore the existing value:

```swift
        func fill(_ existing: FeatureBackend) -> FeatureBackend? { migrated }   // TEMP
```

Run the tests. Expected: `anExplicitPerFeatureChoiceIsNeverOverwritten` FAILS with "an explicit choice was overwritten". Revert and confirm green. A guard that cannot fail is not a guard.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Polish/PolishBackendMigration.swift omwhisper-nativeTests/PolishBackendMigrationTests.swift
git commit -m "✨ feat(ai): plan the move off the old global polish backend"
```

---

### Task 2: One resolver, one default

**Files:**
- Create: `omwhisper-native/Polish/ShortFormBackend.swift`
- Test: `omwhisper-nativeTests/ShortFormBackendTests.swift`
- Modify: `omwhisper-native/AppState.swift` — add `dictationPolishEnabled` beside `defaultBackend` (~line 1010), rewrite `activePolishBackend` (~line 2609), `usesCloud` (line 1727-1729), the two nudge sites (lines 2650 and 2708), and run the migration in `init()` near line 1991.

**Interfaces:**
- Consumes: `PolishBackendMigration.plan(...)` from Task 1; `AppState.backend(for:)`, `setBackend(_:for:)`, `defaultBackend`, `AIFeature`, `FeatureBackend`.
- Produces: `AppState.dictationPolishEnabled: Bool`, `ShortFormBackend.resolve(feature:choice:defaultChoice:dictationPolishEnabled:) -> FeatureBackend?`. Tasks 3 and 4 use `dictationPolishEnabled`.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/ShortFormBackendTests.swift`:

```swift
import Testing
@testable import OmWhisper

/// Mirrors LongFormBackends: the whole decision is pure, so "which backend does
/// this feature actually use" is answerable without constructing AppState.
struct ShortFormBackendTests {
    @Test func defaultResolvesThroughTheDefaultRow() {
        #expect(ShortFormBackend.resolve(feature: .dictationPolish, choice: .useDefault,
                                         defaultChoice: .system, dictationPolishEnabled: true)
                == .system)
    }

    @Test func anExplicitChoiceWinsOverTheDefaultRow() {
        #expect(ShortFormBackend.resolve(feature: .dictationPolish, choice: .cloud,
                                         defaultChoice: .system, dictationPolishEnabled: true)
                == .cloud)
    }

    /// The toggle governs dictation polish ONLY. Reply Assist has its own
    /// enable flag and must not be switched off by another feature's control —
    /// that coupling is the bug this whole change exists to remove.
    @Test func theToggleGovernsDictationPolishAlone() {
        #expect(ShortFormBackend.resolve(feature: .dictationPolish, choice: .system,
                                         defaultChoice: .useDefault, dictationPolishEnabled: false)
                == nil)
        #expect(ShortFormBackend.resolve(feature: .replyAssist, choice: .system,
                                         defaultChoice: .useDefault, dictationPolishEnabled: false)
                == .system)
    }

    /// Both left on Default means "no backend chosen", not a silent fallback to
    /// something. The caller treats nil as a configuration state, not a fault.
    @Test func defaultOnDefaultIsNoChoice() {
        #expect(ShortFormBackend.resolve(feature: .replyAssist, choice: .useDefault,
                                         defaultChoice: .useDefault, dictationPolishEnabled: true)
                == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with"`

Expected: FAIL to compile — `cannot find 'ShortFormBackend' in scope`.

- [ ] **Step 3: Write the pure resolver**

Create `omwhisper-native/Polish/ShortFormBackend.swift`:

```swift
//
//  ShortFormBackend.swift
//  OmWhisper
//
//  The short-form half of what LongFormBackends does for meetings, chronicles
//  and brain-dump: resolve a feature's choice against the Default row.
//
//  It exists because that resolution used to fall through to `polishBackend`
//  here and to `defaultBackend` there, so "Default" meant two different things
//  depending on which feature asked, and "Disabled" silenced two features out
//  of five while reading as global.
//

import Foundation

nonisolated enum ShortFormBackend {
    /// nil means "no backend" — either dictation polish is switched off, or
    /// nothing has been chosen at any level. Callers treat nil as a
    /// configuration state, never as a failure.
    static func resolve(feature: AIFeature,
                        choice: FeatureBackend,
                        defaultChoice: FeatureBackend,
                        dictationPolishEnabled: Bool) -> FeatureBackend? {
        // The toggle is dictation polish's own off-switch, not a global one.
        if feature == .dictationPolish, !dictationPolishEnabled { return nil }
        let resolved = (choice == .useDefault) ? defaultChoice : choice
        return resolved == .useDefault ? nil : resolved
    }
}
```

- [ ] **Step 4: Add the setting**

In `omwhisper-native/AppState.swift`, immediately **before** `var defaultBackend: FeatureBackend {` (currently ~line 1012), insert:

```swift
    /// Dictation polish's own off-switch, replacing `polishBackend == .disabled`.
    ///
    /// Defaults to FALSE: `polishBackend` defaulted to `.disabled`, so polish is
    /// off on a fresh install today. Defaulting this to true would switch it on
    /// for every new user — latency on every dictation and a new way to fail —
    /// which is a product change disguised as a refactor.
    ///
    /// Meetings, Reply Assist and Memory already own equivalent flags; this is
    /// the one feature that had none, which is the entire reason "Disabled"
    /// ended up inside a backend enum.
    var dictationPolishEnabled: Bool {
        get {
            access(keyPath: \.dictationPolishEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.dictationPolishEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.dictationPolishEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.dictationPolishEnabled)
            }
        }
    }
```

Then add to `SettingsKeys` beside `defaultAIBackend` (currently line 2860):

```swift
    static let dictationPolishEnabled = "dictationPolishEnabled"
    static let hasMigratedPolishBackend = "hasMigratedPolishBackend"
```

- [ ] **Step 5: Route resolution through the new resolver**

Replace the whole body of `activePolishBackend(for:)` (currently ~line 2609) — everything from `switch backend(for: feature) {` to the closing brace of the second `switch` — with:

```swift
        guard let resolved = ShortFormBackend.resolve(
            feature: feature,
            choice: backend(for: feature),
            defaultChoice: defaultBackend,
            dictationPolishEnabled: dictationPolishEnabled
        ) else { return nil }

        switch resolved {
        case .system:
            return SystemLLM.isAvailable() ? systemLLM : nil
        case .ollama(let model):
            // Unchanged from today: an empty model resolves to nil rather than
            // falling back to the global `ollamaModel`. Making it more forgiving
            // here would be a behaviour change smuggled into a refactor.
            return model.isEmpty ? nil : Ollama(baseURL: ollamaBaseURL, model: model)
        case .cloud:
            guard let key = Keychain.loadCloudLLMKey(), !key.isEmpty else { return nil }
            return CloudLLM(apiURL: cloudAPIURL, model: cloudModel, apiKey: key)
        case .useDefault:
            return nil   // unreachable: resolve() never returns .useDefault
        }
```

Also update its doc comment: replace the line `/// A feature left on Default falls through to `polishBackend`, which keeps` and the line after it, plus the whole **KNOWN DEFECT** paragraph, with:

```swift
    /// A feature left on Default falls through to the Default row
    /// (`defaultBackend`) — the same one the long-form path uses, so "Default"
    /// now means one thing for all five features.
```

- [ ] **Step 6: Rehome `usesCloud` and the two nudges**

Replace `usesCloud` (lines 1727-1729) with:

```swift
    var usesCloud: Bool {
        if engineKind == .cloud || crossLingualUsesSarvam { return true }
        return AIFeature.allCases.contains { feature in
            ShortFormBackend.resolve(feature: feature, choice: backend(for: feature),
                                     defaultChoice: defaultBackend,
                                     dictationPolishEnabled: true) == .cloud
        }
    }
```

`dictationPolishEnabled: true` is passed deliberately: this answers "is a cloud path configured", and a feature switched off should not make the privacy line claim less than the configuration does.

At **both** nudge sites (currently lines 2650 and 2708), replace:

```swift
        if polishBackend == .system, !SystemLLM.isAvailable() {
```

with:

```swift
        if activePolishBackendKind(for: feature) == .system, !SystemLLM.isAvailable() {
```

and add this helper next to `activePolishBackend`:

```swift
    /// The resolved choice without building the backend — the nudge needs to
    /// know Apple Intelligence was ASKED for, which a nil backend cannot say.
    func activePolishBackendKind(for feature: AIFeature = .dictationPolish) -> FeatureBackend? {
        ShortFormBackend.resolve(feature: feature, choice: backend(for: feature),
                                 defaultChoice: defaultBackend,
                                 dictationPolishEnabled: dictationPolishEnabled)
    }
```

The site at line 2708 is inside `brainDumpStructured`, which is a long-form feature — pass `.brainDump` there and `.dictationPolish` at the other.

**One deliberate behaviour change to expect here.** The nudge used to fire whenever the single global said System and Apple Intelligence was unavailable. It now fires only when *that feature* resolves to System. So with everything left on Default (automatic on-device), an unavailable Apple Intelligence no longer nudges — the automatic order simply picks Ollama or nothing, which is what the user asked for by leaving it on Default. The nudge still fires for anyone who explicitly chose System.

- [ ] **Step 7: Run the migration once at startup**

In `AppState.init()`, immediately **before** the existing `if !isRunningUnderTests, let store = meetingStore` block (~line 1991), insert:

```swift
        // One-time move off the old global. Guarded so a user who later clears a
        // per-feature choice does not get the old value pushed back at them.
        if !UserDefaults.standard.bool(forKey: SettingsKeys.hasMigratedPolishBackend) {
            let plan = PolishBackendMigration.plan(
                old: UserDefaults.standard.string(forKey: SettingsKeys.polishBackend),
                existingDictation: backend(for: .dictationPolish),
                existingReplyAssist: backend(for: .replyAssist),
                ollamaModel: ollamaModel)
            dictationPolishEnabled = plan.dictationPolishEnabled
            if let b = plan.dictationBackend { setBackend(b, for: .dictationPolish) }
            if let b = plan.replyAssistBackend { setBackend(b, for: .replyAssist) }
            UserDefaults.standard.set(true, forKey: SettingsKeys.hasMigratedPolishBackend)
        }
```

`SettingsKeys.polishBackend` stays defined for this read even after the property is deleted in Task 3.

- [ ] **Step 8: Run tests**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`

Expected: PASS, **632 tests in 95 suites**.

- [ ] **Step 9: Commit**

```bash
git add omwhisper-native/Polish/ShortFormBackend.swift omwhisper-nativeTests/ShortFormBackendTests.swift omwhisper-native/AppState.swift
git commit -m "✨ feat(ai): one Default row for all five features, and a toggle for dictation polish"
```

---

### Task 3: Delete the old global and its picker

**Files:**
- Modify: `omwhisper-native/UI/AISettingsView.swift` — Backend section (lines 39-50), Ollama reveal (line 78), Cloud reveal (line 135)
- Modify: `omwhisper-native/AppState.swift` — delete `polishBackend` (~line 275) and `enum PolishBackendKind` (~line 2838)
- Modify: `omwhisper-native/DebugInfo.swift:92`
- Modify: `omwhisper-native/Meetings/MeetingAIDiagnostics.swift:218`

**Interfaces:**
- Consumes: `AppState.dictationPolishEnabled` and `activePolishBackendKind(for:)` from Task 2.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Replace the Backend section with the toggle**

In `AISettingsView.swift`, replace the `PorcelainSection(eyebrow: "Backend")`'s `Picker` (lines 40-49) with:

```swift
                Toggle("Polish my dictation with AI", isOn: $state.dictationPolishEnabled)
                    .toggleStyle(.switch)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                Text("Off by default. Meetings, Reply Assist and Memory have their own switches — this one governs dictation only.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
```

- [ ] **Step 2: Reveal the config sections from actual usage**

Add these computed properties to `AISettingsView` next to `cloudFeatures` (~line 332):

```swift
    /// A backend's settings appear when something actually resolves to it, so a
    /// Cloud API-key field never greets someone who chose nothing cloud-related.
    private func anyRowUses(_ match: (FeatureBackend) -> Bool) -> Bool {
        if match(appState.defaultBackend) { return true }
        return AIFeature.allCases.contains { match(appState.backend(for: $0)) }
    }
    private var usesOllamaAnywhere: Bool {
        anyRowUses { if case .ollama = $0 { return true } else { return false } }
    }
    private var usesCloudAnywhere: Bool {
        anyRowUses { $0 == .cloud }
    }
```

Then change line 78 from `if state.polishBackend == .ollama {` to `if usesOllamaAnywhere {`, and line 135 from `if state.polishBackend == .cloud {` to `if usesCloudAnywhere {`.

- [ ] **Step 3: Update the two diagnostics**

`DebugInfo.swift:92` — replace:

```swift
          Backend: \(state.polishBackend.rawValue)
```

with:

```swift
          Default backend: \(state.defaultBackend.rawValue)
          Dictation polish: \(state.dictationPolishEnabled ? "on" : "off")
```

`MeetingAIDiagnostics.swift:218` — replace:

```swift
        let kind = defaults.string(forKey: "polishBackend")
```

with:

```swift
        let kind = defaults.string(forKey: "defaultAIBackend") ?? "default"
```

- [ ] **Step 4: Delete the old property and enum**

Delete the whole `var polishBackend: PolishBackendKind { ... }` block from `AppState.swift` (~line 275), and delete `nonisolated enum PolishBackendKind: String, Codable, CaseIterable { case disabled, system, ollama, cloud }` (~line 2838).

**Keep `SettingsKeys.polishBackend`** — Task 2's migration still reads that key.

- [ ] **Step 5: Verify nothing references them**

Run:

```bash
grep -rn "polishBackend" omwhisper-native omwhisper-nativeTests | grep -v "SettingsKeys.polishBackend\|static let polishBackend\|hasMigratedPolishBackend\|PolishBackendMigration"
```

Expected: **no output.** Any hit is a call site this task missed.

- [ ] **Step 6: Run tests**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`

Expected: PASS, **632 tests in 95 suites**.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/UI/AISettingsView.swift omwhisper-native/AppState.swift omwhisper-native/DebugInfo.swift omwhisper-native/Meetings/MeetingAIDiagnostics.swift
git commit -m "♻️ refactor(ai): delete the second global backend setting"
```

---

### Task 4: Onboarding switches dictation polish on

**Files:**
- Modify: `omwhisper-native/UI/OnboardingView.swift` — `AIPolishStep`'s two choice buttons

**Interfaces:**
- Consumes: `AppState.dictationPolishEnabled` from Task 2.
- Produces: nothing.

Without this the onboarding step chooses a backend for a feature that stays off, so it appears to do nothing — the exact failure this project spent the week removing.

- [ ] **Step 1: Set the toggle alongside the backend**

In `AIPolishStep`, replace:

```swift
                OnboardingButton("Use Apple Intelligence") {
                    appState.setBackend(.system, for: .dictationPolish)
                    onNext()
                }
```

with:

```swift
                OnboardingButton("Use Apple Intelligence") {
                    appState.setBackend(.system, for: .dictationPolish)
                    // Without this the step picks a backend for a feature that
                    // stays off, and appears to do nothing.
                    appState.dictationPolishEnabled = true
                    onNext()
                }
```

and replace:

```swift
                OnboardingButton("Use Ollama") {
                    appState.setBackend(.ollama(model: picked), for: .dictationPolish)
                    onNext()
                }
```

with:

```swift
                OnboardingButton("Use Ollama") {
                    appState.setBackend(.ollama(model: picked), for: .dictationPolish)
                    appState.dictationPolishEnabled = true
                    onNext()
                }
```

**Not now** stays as it is — it must still write nothing.

- [ ] **Step 2: Run tests and build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`

Expected: PASS, **632 tests in 95 suites**.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/OnboardingView.swift
git commit -m "🐛 fix(onboarding): choosing a backend must also switch dictation polish on"
```

---

## Live verification (owed — no test above can replace it)

Run on the dev build. Each names a result that could come back negative. Read
`defaults` only after quitting the app: cfprefsd serves other processes stale
values, which already produced one false pass in this project.

1. **The migration moves two slots and only two.** With the app quit:
   `defaults write com.omwhisper.mac.dev polishBackend -string cloud`,
   `defaults delete com.omwhisper.mac.dev hasMigratedPolishBackend`, and delete
   all five `aiBackend.*` keys plus `defaultAIBackend`. Launch, quit, then read:
   `aiBackend.dictationPolish` and `aiBackend.replyAssist` are `cloud`;
   `defaultAIBackend`, `aiBackend.meetings`, `aiBackend.chronicles` and
   `aiBackend.brainDump` are **all still absent**.
2. **Disabled survives as off.** Same reset but `polishBackend = disabled` →
   after launch the Polish toggle is off, and a dictation pastes raw text with
   no error capsule.
3. **Dictation polish off does not silence meetings.** Toggle off, then
   Transcribe & Summarize a recorded meeting → a summary still appears.
   **Control:** turn Meetings' own toggle off and confirm the feature is then
   unavailable, or "a summary appeared" is equally explained by the toggle being
   wired to nothing.
4. **The Default row governs meetings.** Set it to Ollama, regenerate a meeting
   summary → the stored caption reads `Ollama (<model>)`. A summary merely
   appearing proves nothing; the on-device fallback produces one too.
5. **The Cloud key field is gone when nothing uses cloud.** With every row on
   Default or on-device, the Cloud section is absent; set any row to Cloud and
   it appears.
