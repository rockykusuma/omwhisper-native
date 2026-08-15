# Per-feature AI backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each feature choose its own AI backend — including cloud — so an hour-long meeting summarises in one call instead of 7–8, without any feature reaching the cloud unless explicitly told to.

**Architecture:** Two new pure types (`AIFeature`, `FeatureBackend`) describe the choice; `LongFormBackends` gains a `.cloud` case and one pure `candidates(...)` function that resolves a choice into an ordered candidate list. `AppState` stores one setting per feature and routes every existing call site through the resolver. The UI is a `Default` row plus per-feature overrides in the AI Polish section.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), SwiftUI, Swift Testing, UserDefaults via `access`/`withMutation`.

## Global Constraints

- **Fallback must never cross to cloud.** A feature set to an on-device backend that fails falls back to the *other on-device* backend and then fails honestly. Cloud appears as a candidate **only** when explicitly chosen. This is the rule the whole design rests on; it gets a dedicated test that must fail if anyone appends cloud to a fallback chain.
- **Cloud is never the shipped default.** Every feature ships as `.useDefault`, and `Default` ships as today's automatic order.
- **The existing guard is rewritten, not deleted.** `LongFormBackendsTests.noCloudCase` asserts `Kind.allCases == [.ollama, .system]` precisely to stop this change being made carelessly. Replace it with a test pinning the *new* guarantee.
- **`@Observable` computed properties over UserDefaults need `access(keyPath:)`/`withMutation(keyPath:)`.** Pickers expose the missing-notification bug that Toggles mask — see the M3 notes. Every new setting here backs a Picker.
- **No new provider integration.** `CloudLLM` already speaks OpenAI-compatible `/chat/completions` with a Keychain key and runs `Redactor`. This lifts a restriction.
- **Constructing `AppState` in a test opens the real stores.** No test here may construct it; `LongFormBackends` is pure for exactly this reason.
- Full suite before this work: **569 tests in 85 suites**. Run `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test` after every task.

---

### Task 1: Describe the choice

Two pure types, no behaviour yet. Separated from Task 2 so the storage encoding — the part a bad refactor silently breaks — is pinned before anything depends on it.

**Files:**
- Create: `omwhisper-native/Polish/AIFeature.swift`
- Test: `omwhisper-nativeTests/AIFeatureTests.swift`

**Interfaces:**
- Produces: `AIFeature` (CaseIterable, `displayName`, `settingsKey`), `FeatureBackend` (`rawValue`, `init?(rawValue:)`)

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import OmWhisper

@Suite("Per-feature backend choice")
struct AIFeatureTests {
    @Test("every feature has a stable settings key and a display name")
    func featuresAreComplete() {
        // Keys are PERSISTED. Renaming one silently resets that feature to
        // Default on the next launch, which for a cloud-enabled feature would
        // read as the setting being forgotten.
        #expect(AIFeature.allCases.count == 5)
        for f in AIFeature.allCases {
            #expect(!f.displayName.isEmpty)
            #expect(f.settingsKey.hasPrefix("aiBackend."))
        }
        #expect(Set(AIFeature.allCases.map(\.settingsKey)).count == AIFeature.allCases.count)
    }

    @Test("choices round-trip through their stored string")
    func choicesRoundTrip() {
        let all: [FeatureBackend] = [
            .useDefault, .system, .cloud,
            .ollama(model: "qwen3.5:latest"), .ollama(model: "gemma4"),
        ]
        for choice in all {
            #expect(FeatureBackend(rawValue: choice.rawValue) == choice,
                    "\(choice) did not survive a round trip")
        }
    }

    @Test("an unknown or corrupt stored value falls back to Default")
    func unknownValuesFallBackToDefault() {
        // The half that matters: a stored value from a future version, or a
        // typo, must not resolve to something arbitrary — and above all must
        // never resolve to cloud.
        #expect(FeatureBackend(rawValue: "") == nil)
        #expect(FeatureBackend(rawValue: "gibberish") == nil)
        #expect(FeatureBackend(rawValue: "ollama:") == nil)
    }

    @Test("an Ollama model containing a colon survives")
    func ollamaModelWithColon() {
        // Real model names are "qwen3.5:latest" — splitting on the first colon
        // only is load-bearing, and a naive split would store "qwen3.5" and
        // quietly select a model the user does not have.
        let choice = FeatureBackend.ollama(model: "qwen3.5:latest")
        #expect(choice.rawValue == "ollama:qwen3.5:latest")
        #expect(FeatureBackend(rawValue: "ollama:qwen3.5:latest") == choice)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with"`
Expected: compile failure — no `AIFeature`, no `FeatureBackend`.

- [ ] **Step 3: Implement**

Create `omwhisper-native/Polish/AIFeature.swift`:

```swift
//
//  AIFeature.swift
//  OmWhisper
//
//  Which AI backend each feature uses. One choice per feature rather than one
//  global setting, because cloud introduces an axis a single control cannot
//  express: whether that feature's data leaves the Mac. A day of screen text,
//  a recorded call with other people in it, and one dictated sentence are not
//  the same decision.
//
//  Pure and free of AppState on purpose -- constructing AppState in a test
//  opens the real history and memory stores.
//

import Foundation

/// The features that choose a backend. Granularity follows the DATA that would
/// egress, not the button pressed: all five meeting functions (summary, title,
/// regenerate, Ask, follow-up email) touch the same recording, so splitting
/// them would let a user send a summary to the cloud but refuse a question
/// about it -- incoherent, since the summary already went.
nonisolated enum AIFeature: String, CaseIterable, Sendable {
    case dictationPolish
    case replyAssist
    case meetings
    case chronicles
    case brainDump

    var displayName: String {
        switch self {
        case .dictationPolish: return "Dictation polish"
        case .replyAssist:     return "Reply Assist"
        case .meetings:        return "Meeting summaries"
        case .chronicles:      return "Chronicles"
        case .brainDump:       return "Brain-dump"
        }
    }

    /// Persisted. Never rename one: a changed key silently resets that feature
    /// to Default on the next launch.
    var settingsKey: String { "aiBackend.\(rawValue)" }
}

/// One feature's choice. `useDefault` defers to the Default row, which is what
/// keeps the common case a single control.
nonisolated enum FeatureBackend: Equatable, Hashable, Sendable {
    case useDefault
    case system
    case ollama(model: String)
    case cloud

    /// Stored as a string rather than Codable JSON: it goes in UserDefaults,
    /// is read on every backend selection, and is worth being able to read by
    /// eye in a defaults dump.
    var rawValue: String {
        switch self {
        case .useDefault:          return "default"
        case .system:              return "system"
        case .cloud:               return "cloud"
        case .ollama(let model):   return "ollama:\(model)"
        }
    }

    /// nil for anything unrecognised, so the caller falls back to Default.
    /// Deliberately never guesses -- above all it must never resolve an
    /// unknown value to `.cloud`.
    init?(rawValue: String) {
        switch rawValue {
        case "default": self = .useDefault
        case "system":  self = .system
        case "cloud":   self = .cloud
        default:
            // Split on the FIRST colon only: real model names are
            // "qwen3.5:latest", and splitting on all of them would store
            // "qwen3.5" and quietly select a model the user does not have.
            guard rawValue.hasPrefix("ollama:") else { return nil }
            let model = String(rawValue.dropFirst("ollama:".count))
            guard !model.isEmpty else { return nil }
            self = .ollama(model: model)
        }
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, count above 569.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Polish/AIFeature.swift omwhisper-nativeTests/AIFeatureTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(ai): describe a per-feature backend choice

Five features, not eight: granularity follows the data that would
egress, not the button pressed. All five meeting functions touch the
same recording, so splitting them would let a user send a summary to
the cloud but refuse a question about it.

Stored as a string, split on the FIRST colon only — real Ollama model
names are "qwen3.5:latest", and a naive split would persist "qwen3.5"
and quietly select a model the user does not have.

An unrecognised stored value resolves to nil so the caller falls back
to Default. It must never resolve to cloud.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 2: Resolve a choice into candidates, and rewrite the guard

The heart of the change, and the only place the privacy rule can be enforced. Pure, so it is fully testable.

**Files:**
- Modify: `omwhisper-native/Polish/LongFormBackends.swift`
- Modify: `omwhisper-nativeTests/LongFormBackendsTests.swift`

**Interfaces:**
- Consumes: `FeatureBackend` (Task 1).
- Produces: `LongFormBackends.Kind.cloud`; `LongFormBackends.candidates(choice:defaultChoice:ollamaConfigured:systemAvailable:cloudConfigured:) -> [Kind]`

- [ ] **Step 1: Write the failing tests**

Replace `noCloudCase` in `omwhisper-nativeTests/LongFormBackendsTests.swift` with:

```swift
    @Test("cloud is a candidate ONLY when explicitly chosen")
    func cloudOnlyWhenChosen() {
        // Replaces the old `Kind.allCases == [.ollama, .system]` guard. That
        // test existed to stop this change being made carelessly; this one
        // pins what replaced it. Cloud must never appear for a feature that
        // did not ask for it, however unavailable everything else is.
        let everythingOff = LongFormBackends.candidates(
            choice: .useDefault, defaultChoice: .useDefault,
            ollamaConfigured: false, systemAvailable: false, cloudConfigured: true)
        #expect(everythingOff.isEmpty, "cloud leaked in as a last resort")

        let chosen = LongFormBackends.candidates(
            choice: .cloud, defaultChoice: .useDefault,
            ollamaConfigured: true, systemAvailable: true, cloudConfigured: true)
        #expect(chosen.first == .cloud)
    }

    @Test("an on-device choice never falls back to cloud")
    func onDeviceNeverFallsBackToCloud() {
        // THE rule. A fallback that reached for cloud when Ollama was down
        // would look like resilience and be a privacy breach.
        for choice in [FeatureBackend.system, .ollama(model: "qwen3.5")] {
            let list = LongFormBackends.candidates(
                choice: choice, defaultChoice: .useDefault,
                ollamaConfigured: true, systemAvailable: true, cloudConfigured: true)
            #expect(!list.contains(.cloud), "\(choice) offered cloud as a fallback")
        }
    }

    @Test("a cloud choice may fall back to on-device")
    func cloudMayFallBackLocally() {
        // The reverse direction is fine: less capable, never less private.
        let list = LongFormBackends.candidates(
            choice: .cloud, defaultChoice: .useDefault,
            ollamaConfigured: true, systemAvailable: true, cloudConfigured: true)
        #expect(list == [.cloud, .ollama, .system])
    }

    @Test("useDefault defers to the Default row")
    func useDefaultDefers() {
        let list = LongFormBackends.candidates(
            choice: .useDefault, defaultChoice: .cloud,
            ollamaConfigured: true, systemAvailable: true, cloudConfigured: true)
        #expect(list.first == .cloud, "the Default row was ignored")
    }

    @Test("Default set to Default means today's automatic order")
    func defaultOfDefaultIsAutomatic() {
        // Shipping behaviour: nothing configured, everything on-device,
        // Ollama preferred for its larger envelope.
        let list = LongFormBackends.candidates(
            choice: .useDefault, defaultChoice: .useDefault,
            ollamaConfigured: true, systemAvailable: true, cloudConfigured: false)
        #expect(list == [.ollama, .system])
    }

    @Test("an unconfigured backend is skipped, not offered")
    func unconfiguredIsSkipped() {
        #expect(LongFormBackends.candidates(
            choice: .cloud, defaultChoice: .useDefault,
            ollamaConfigured: false, systemAvailable: false, cloudConfigured: false).isEmpty)
        #expect(LongFormBackends.candidates(
            choice: .ollama(model: "x"), defaultChoice: .useDefault,
            ollamaConfigured: false, systemAvailable: true, cloudConfigured: false) == [.system])
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with"`
Expected: compile failure — no `.cloud` case, no `candidates(...)`.

- [ ] **Step 3: Implement**

In `omwhisper-native/Polish/LongFormBackends.swift`, add the case and the resolver, and update the header note that says cloud is absent by construction:

```swift
    enum Kind: Equatable, CaseIterable {
        case ollama
        case system
        /// Only ever reachable when a feature is EXPLICITLY set to cloud --
        /// see candidates(). Never a fallback.
        case cloud
    }

    /// Ordered candidates for one feature.
    ///
    /// The rule this function exists to enforce: **cloud appears only when
    /// explicitly chosen.** An on-device choice that is unavailable falls back
    /// to the other on-device backend and then to nothing. A fallback that
    /// reached for cloud because Ollama was not answering would look like
    /// resilience and be a privacy breach.
    ///
    /// The reverse is allowed: a cloud choice may fall back on-device, which
    /// is less capable but never less private.
    static func candidates(choice: FeatureBackend,
                           defaultChoice: FeatureBackend,
                           ollamaConfigured: Bool,
                           systemAvailable: Bool,
                           cloudConfigured: Bool) -> [Kind] {
        // Resolve the sentinel once. A Default row left on Default means the
        // automatic on-device order, which is exactly today's behaviour.
        var resolved = choice
        if case .useDefault = choice { resolved = defaultChoice }

        let onDevice = order(ollamaConfigured: ollamaConfigured, systemAvailable: systemAvailable)

        switch resolved {
        case .useDefault:
            return onDevice
        case .system:
            return systemAvailable ? [.system] + onDevice.filter { $0 != .system } : onDevice
        case .ollama:
            return ollamaConfigured ? [.ollama] + onDevice.filter { $0 != .ollama } : onDevice
        case .cloud:
            return (cloudConfigured ? [.cloud] : []) + onDevice
        }
    }
```

Extend `displayName` for the new case:

```swift
        case .cloud: return "Cloud"
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Prove the privacy rule is load-bearing**

Temporarily change the `.system` case to `[.system] + onDevice.filter { $0 != .system } + [.cloud]`, run the suite, and confirm `onDeviceNeverFallsBackToCloud` fails. Restore it. A rule nothing exercises is decoration, and this is the one rule the design rests on.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Polish/LongFormBackends.swift omwhisper-nativeTests/LongFormBackendsTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(ai): resolve a feature's backend choice, cloud only when asked

Kind gains .cloud, and candidates() is the single place the privacy
rule lives: cloud appears ONLY when a feature is explicitly set to it.
An on-device choice that is unavailable falls back to the other
on-device backend and then to nothing — never to cloud, because a
fallback that reached for the network when Ollama was down would look
like resilience and be a privacy breach. The reverse is allowed: cloud
may fall back on-device, which is less capable but never less private.

Replaces LongFormBackendsTests.noCloudCase rather than deleting it.
That test asserted Kind.allCases == [.ollama, .system] precisely to
stop this change being made carelessly; its replacement pins what the
guarantee became. Proven load-bearing by appending cloud to the
on-device fallback and watching the suite go red.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 3: Store the choices and route every call site

**Files:**
- Modify: `omwhisper-native/AppState.swift`
- Modify: `omwhisper-native/Meetings/MeetingSummarizer.swift`, `omwhisper-native/Memory/Chronicler.swift`, `omwhisper-native/Polish/BrainDumpStructurer.swift`
- Test: `omwhisper-nativeTests/AIFeatureTests.swift`

**Interfaces:**
- Consumes: `AIFeature`, `FeatureBackend` (Task 1); `LongFormBackends.candidates` (Task 2).
- Produces: `AppState.backend(for:)` / `setBackend(_:for:)`; `AppState.defaultBackend`; `cloudChunkLimit` on all three long-form types.

- [ ] **Step 1: Add the chunk limit that makes this worth doing**

In each of `MeetingSummarizer`, `Chronicler` and `BrainDumpStructurer`, beside the existing limits:

```swift
    /// One call, not a map-reduce. A 59-minute meeting is ~51,000 characters
    /// -- about 13,000 tokens -- which every current cloud model takes whole,
    /// where Ollama's 12,000-char envelope makes it 5 chunks plus collapse
    /// rounds and a reduce: 7-8 sequential calls, 3-4 minutes of local
    /// inference. Shipping cloud WITHOUT raising this would deliver the egress
    /// and only a fraction of the speed-up.
    static let cloudChunkLimit = 120_000
```

- [ ] **Step 2: Write the failing test**

Append to `omwhisper-nativeTests/AIFeatureTests.swift`:

```swift
@Suite("Chunk limits follow the backend")
struct ChunkLimitTests {
    @Test("cloud takes a whole meeting in one chunk where Ollama needs five")
    func cloudNeedsOneChunk() {
        // The performance claim, asserted rather than assumed. 50,967 is the
        // real longest transcript on this machine.
        let transcript = String(repeating: "word ", count: 10_193)   // ~50,965 chars
        #expect(transcript.count > 50_000)
        #expect(MeetingSummarizer.chunk(transcript, limit: MeetingSummarizer.cloudChunkLimit).count == 1)
        #expect(MeetingSummarizer.chunk(transcript, limit: MeetingSummarizer.ollamaChunkLimit).count >= 4)
    }
}
```

- [ ] **Step 3: Run it and verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|recorded an issue|Test run with"`
Expected: compile failure — no `cloudChunkLimit` — until Step 1 is in, then it should pass.

- [ ] **Step 4: Add the settings**

In `omwhisper-native/AppState.swift`, beside the other polish settings:

```swift
    /// The Default row. Ships as `.useDefault`, which means today's automatic
    /// on-device order -- so an existing user sees no change until they
    /// deliberately choose something.
    var defaultBackend: FeatureBackend {
        get {
            access(keyPath: \.defaultBackend)
            let raw = UserDefaults.standard.string(forKey: SettingsKeys.defaultAIBackend) ?? ""
            return FeatureBackend(rawValue: raw) ?? .useDefault
        }
        set {
            withMutation(keyPath: \.defaultBackend) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.defaultAIBackend)
            }
        }
    }

    /// One feature's choice. Unrecognised or missing resolves to `.useDefault`
    /// -- never to cloud.
    func backend(for feature: AIFeature) -> FeatureBackend {
        access(keyPath: \.aiBackendsVersion)
        let raw = UserDefaults.standard.string(forKey: feature.settingsKey) ?? ""
        return FeatureBackend(rawValue: raw) ?? .useDefault
    }

    func setBackend(_ choice: FeatureBackend, for feature: AIFeature) {
        withMutation(keyPath: \.aiBackendsVersion) {
            UserDefaults.standard.set(choice.rawValue, forKey: feature.settingsKey)
            aiBackendsVersion &+= 1
        }
    }

    /// Bumped on every per-feature change. `backend(for:)` is a FUNCTION, not a
    /// property, so Observation has no key path of its own to track -- this is
    /// the observable token the Pickers read. Without it the menus would not
    /// re-render, which is the same @Observable gap that made the AI tab's
    /// radio buttons stick in M3.
    @ObservationIgnored private(set) var aiBackendsVersion: Int = 0
```

Add `static let defaultAIBackend = "defaultAIBackend"` to `SettingsKeys`.

- [ ] **Step 5: Route the call sites**

Replace `longFormBackends(ollamaChunkLimit:systemChunkLimit:)` with a feature-aware version:

```swift
    private func backends(for feature: AIFeature,
                          ollamaChunkLimit: Int, systemChunkLimit: Int, cloudChunkLimit: Int)
        -> [(kind: LongFormBackends.Kind, polish: PolishBackend, chunkLimit: Int)] {
        let cloudKey = Keychain.loadCloudLLMKey()
        return LongFormBackends.candidates(
            choice: backend(for: feature),
            defaultChoice: defaultBackend,
            ollamaConfigured: !ollamaModel.isEmpty,
            systemAvailable: SystemLLM.isAvailable(),
            cloudConfigured: !(cloudKey ?? "").isEmpty
        ).compactMap { kind in
            switch kind {
            case .ollama:
                return (kind, Ollama(baseURL: ollamaBaseURL, model: ollamaModel,
                                     timeout: Ollama.longFormTimeout), ollamaChunkLimit)
            case .system:
                return (kind, systemLLM, systemChunkLimit)
            case .cloud:
                guard let key = cloudKey, !key.isEmpty else { return nil }
                return (kind, CloudLLM(apiURL: cloudAPIURL, model: cloudModel, apiKey: key),
                        cloudChunkLimit)
            }
        }
    }
```

Then point the three existing wrappers at it — `meetingSummaryBackends()` passes `.meetings`, `chronicleBackends()` passes `.chronicles`, and the brain-dump call site at `brainDumpStructured` passes `.brainDump` — each supplying its own type's three limits.

For the two dictation-path features, `activePolishBackend()` gains a feature parameter and resolves the same way, taking the first candidate:

```swift
    func activePolishBackend(for feature: AIFeature = .dictationPolish) -> PolishBackend? {
```

`polishedText(for:)` keeps the default; `draftAndStream` passes `.replyAssist`.

- [ ] **Step 6: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. The pre-existing meeting, chronicle and brain-dump tests staying green is the regression proof that default behaviour is unchanged.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/Meetings/MeetingSummarizer.swift omwhisper-native/Memory/Chronicler.swift omwhisper-native/Polish/BrainDumpStructurer.swift omwhisper-nativeTests/AIFeatureTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(ai): store a backend per feature and route every call site

Five features now resolve through LongFormBackends.candidates, so the
privacy rule is enforced in one place rather than at six call sites.

cloudChunkLimit = 120_000 is where the reported problem actually gets
fixed: a 59-minute meeting is ~51,000 chars, one cloud call instead of
5 chunks plus collapse rounds and a reduce. Shipping cloud without it
would deliver the egress and a fraction of the speed-up.

aiBackendsVersion exists because backend(for:) is a function, so
Observation has no key path to track and the Pickers would never
re-render — the same @Observable gap that made the AI tab's radio
buttons stick in M3.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 4: The interface

**Files:**
- Modify: `omwhisper-native/UI/AISettingsView.swift`

**Interfaces:** consumes everything above. No new API.

- [ ] **Step 1: Add the section**

Below the existing backend-configuration sections, add a `PorcelainSection` titled "Which backend each feature uses", per the design system (Porcelain tokens, native controls, no invented colors):

```swift
            PorcelainSection(eyebrow: "Which backend each feature uses") {
                backendRow(title: "Default", choice: state.defaultBackend,
                           includeDefaultOption: false) { state.defaultBackend = $0 }
                Divider().overlay(Color.Porcelain.hair)
                ForEach(AIFeature.allCases, id: \.self) { feature in
                    backendRow(title: feature.displayName,
                               choice: state.backend(for: feature),
                               includeDefaultOption: true) { state.setBackend($0, for: feature) }
                }
                if !cloudFeatures.isEmpty {
                    Text(egressSentence)
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                }
            }
```

Each row is a `Picker` with `.pickerStyle(.menu)`, whose contents are grouped by where the data goes rather than by vendor — the design system's rule to state the mechanism rather than shout the slogan:

```swift
    @ViewBuilder
    private func backendRow(title: String, choice: FeatureBackend,
                            includeDefaultOption: Bool,
                            set: @escaping (FeatureBackend) -> Void) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.Porcelain.ink)
            Spacer()
            Menu(label(for: choice)) {
                if includeDefaultOption {
                    Button("Default") { set(.useDefault) }
                    Divider()
                }
                Section("On this Mac") {
                    Button("Apple Intelligence") { set(.system) }
                    ForEach(state.availableOllamaModels, id: \.self) { model in
                        Button("Ollama · \(model)") { set(.ollama(model: model)) }
                    }
                }
                Section("Leaves this Mac") {
                    Button("Cloud · \(state.cloudModel)") { set(.cloud) }
                }
            }
            .menuStyle(.button)
            .tint(Color.Porcelain.emerald)
            .fixedSize()
        }
    }
```

`.menuStyle(.button)` + `.tint` + `.fixedSize()` is not optional styling: a bare `Menu` inside a Porcelain card **renders as blank space** with no chrome and no label — found by screenshot during the Memory exclusions work, and the reason the Apps section there had no visible way to add anything.

- [ ] **Step 2: Write the egress sentence**

One factual line naming the real host, not a banner and not repeated per row:

```swift
    private var cloudFeatures: [AIFeature] {
        AIFeature.allCases.filter { f in
            var c = state.backend(for: f)
            if case .useDefault = c { c = state.defaultBackend }
            return c == .cloud
        }
    }

    private var egressSentence: String {
        let names = cloudFeatures.map(\.displayName).joined(separator: ", ")
        let host = URL(string: state.cloudAPIURL)?.host ?? state.cloudAPIURL
        return "\(names) \(cloudFeatures.count == 1 ? "is" : "are") sent to \(host). Everything else stays on this Mac."
    }
```

- [ ] **Step 3: Build and check the suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. SwiftUI layout is verified live in this project, not by unit test.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/AISettingsView.swift
git commit -m "$(cat <<'EOF'
✨ feat(ai): choose a backend per feature in AI Polish

A Default row plus per-feature overrides. Rows read "Default" until
deliberately changed, so a user who does not care sets one thing and
never opens this again — today's behaviour, preserved.

Each menu groups its options by where the data goes rather than by
vendor: "On this Mac" / "Leaves this Mac". That is the design system's
rule to state the mechanism rather than shout the slogan, and it means
cloud cannot be selected without reading which side of the line it is
on. One factual sentence below names the actual host.

.menuStyle(.button) + .tint + .fixedSize() is required, not cosmetic: a
bare Menu inside a Porcelain card renders as blank space with no chrome
and no label, found by screenshot during the Memory exclusions work.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

## Live verification owed

None of this is provable by unit test:

1. **The performance claim.** Summarise a real ~50k-char meeting with `.meetings` set to cloud, and time it against the 3–4 minutes local currently takes. Confirm from the log that it made **one** call, not five — a cloud path that still chunked would be faster and still wrong.
2. **The menus render.** Every row shows a working menu with the two sections, and the Default row has no "Default" option of its own.
3. **The egress sentence** updates as choices change, and names the real host.
4. **Nothing changed for an existing user.** With every row on Default, meetings, chronicles and brain-dump behave exactly as before.
5. **The written-by caption** still names the backend that actually did the work, now including cloud.
