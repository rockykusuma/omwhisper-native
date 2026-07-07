# M3 Sub-project 1: Core AI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a polish-style library, a Foundation Models (`SystemLLM`) backend, and two new hotkey-driven entry points (Smart Dictation, Polish Selected Text) that always run the user's active style through that backend before pasting — with an unconditional raw-text fallback on any failure.

**Architecture:** New `Polish/PolishStyles.swift` (built-in catalog) and `Polish/SystemLLM.swift` (Foundation Models wrapper) alongside the existing `Polish/PolishBackend.swift` stub. `AppState` gains persisted settings, two new `GlobalHotkey` instances, and orchestration that reuses the existing dictation state machine (`toggleDictation`/`stopDictation`) for Smart Dictation and a small parallel flow for Polish Selected Text. One new `OverlayPhase` case (`.polishing`) reuses the existing overlay pill — no new colors, no orb changes (it already renders calm when `dictation == .idle`, which is exactly Polish Selected Text's state throughout).

**Tech Stack:** Swift 6, SwiftUI, Apple's `FoundationModels` framework (`LanguageModelSession`, macOS 26+), Swift Testing.

## Global Constraints

- Swift 6 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every new type/function is implicitly `@MainActor` unless marked `nonisolated`. Follow the existing `nonisolated`/`nonisolated(unsafe)` conventions documented in `CLAUDE.md`'s "Concurrency" section.
- Regular dictation (Cmd+Shift+V) is **unaffected** by this plan — no polish, no new settings read, no behavior change. Only Smart Dictation (Cmd+Shift+B) and Polish Selected Text (Cmd+Shift+P) use the polish pipeline.
- Any reason polish doesn't produce text (backend Disabled, Foundation Models unavailable, model error, timeout) resolves to pasting the **original, unmodified text** — never silently drop it. This is the single most important behavior in this plan; get it right in every call site, not just the common path.
- No new colors in the overlay — `docs/OVERLAY_SPEC.md` §2 is explicit ("Define these once... No other colors in the overlay"). The `.polishing` phase reuses `omTeal`/`omMint`.
- `PolishBackendKind` only has `.disabled`/`.system` in this plan — do not add `.ollama`/`.cloud` cases (sub-project 2, separate plan).
- Settings persist via `UserDefaults`, same pattern as every existing setting in `AppState.swift` (a computed var backed by a `SettingsKeys` string constant) — no new persistence mechanism.
- Foundation Models real API (verified against the actual macOS 26 SDK's `FoundationModels.swiftinterface`, not guessed):
  ```swift
  import FoundationModels

  // Availability check:
  SystemLanguageModel.default.availability  // .available | .unavailable(UnavailableReason)
  // UnavailableReason: .deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady

  // Session + call:
  let session = LanguageModelSession(instructions: someString)  // fresh session per call — stateless, one-shot
  let response = try await session.respond(to: inputText)       // throws LanguageModelSession.GenerationError
  let text: String = response.content
  ```

## File Structure

```
omwhisper-native/
├── Polish/
│   ├── PolishBackend.swift       # MODIFY — expand PolishStyle, protocol gains targetLanguage param
│   ├── PolishStyles.swift        # CREATE — built-in catalog (7 styles)
│   └── SystemLLM.swift           # CREATE — Foundation Models backend
├── AppState.swift                # MODIFY — settings, hotkeys, Smart Dictation + Polish Selected Text orchestration, OverlayPhase.polishing
├── Paste/
│   └── PasteService.swift        # MODIFY — add copySelection()
├── UI/
│   ├── OverlayView.swift         # MODIFY — isVisible/statusLabel/labelColor account for .polishing
│   ├── AISettingsView.swift      # CREATE — new Settings tab
│   └── SettingsView.swift        # MODIFY — add AI tab
omwhisper-nativeTests/
├── PolishStylesTests.swift       # CREATE
└── SmartDictationLogicTests.swift # CREATE
```

---

### Task 1: PolishStyle model + built-in styles catalog + custom CRUD

**Files:**
- Modify: `omwhisper-native/Polish/PolishBackend.swift`
- Create: `omwhisper-native/Polish/PolishStyles.swift`
- Test: `omwhisper-nativeTests/PolishStylesTests.swift`

**Interfaces:**
- Produces: `PolishStyle` (id: UUID, name: String, prompt: String, isBuiltIn: Bool, requiresTargetLanguage: Bool), `PolishBackend` protocol with `polish(_:style:targetLanguage:)`, `PolishStyles.builtIns: [PolishStyle]`, `PolishStyles.all(customStyles:) -> [PolishStyle]`, `PolishStyles.style(id:customStyles:) -> PolishStyle?`.

- [ ] **Step 1: Write the failing tests**

```swift
// omwhisper-nativeTests/PolishStylesTests.swift
import Testing
@testable import OmWhisper

struct PolishStylesTests {
    @Test func builtInCatalogHasSevenStyles() {
        #expect(PolishStyles.builtIns.count == 7)
    }

    @Test func builtInNamesAreCorrect() {
        let names = Set(PolishStyles.builtIns.map(\.name))
        #expect(names == ["Professional", "Casual", "Concise", "Translate", "Email Format", "Meeting Notes", "Smart Correct"])
    }

    @Test func allBuiltInsAreMarkedBuiltIn() {
        #expect(PolishStyles.builtIns.allSatisfy(\.isBuiltIn))
    }

    @Test func onlyTranslateRequiresTargetLanguage() {
        let flagged = PolishStyles.builtIns.filter(\.requiresTargetLanguage)
        #expect(flagged.count == 1)
        #expect(flagged.first?.name == "Translate")
    }

    @Test func builtInIDsAreStableAcrossCalls() {
        // Fixed UUIDs, not regenerated per call — activePolishStyleID must survive relaunches.
        let first = PolishStyles.builtIns.map(\.id)
        let second = PolishStyles.builtIns.map(\.id)
        #expect(first == second)
    }

    @Test func allMergesBuiltInsAndCustomStyles() {
        let custom = PolishStyle(id: UUID(), name: "My Style", prompt: "Do the thing.", isBuiltIn: false)
        let merged = PolishStyles.all(customStyles: [custom])
        #expect(merged.count == 8)
        #expect(merged.contains { $0.id == custom.id })
    }

    @Test func styleLookupFindsBuiltIn() {
        let professional = PolishStyles.builtIns.first { $0.name == "Professional" }!
        #expect(PolishStyles.style(id: professional.id, customStyles: []) == professional)
    }

    @Test func styleLookupFindsCustom() {
        let custom = PolishStyle(id: UUID(), name: "Mine", prompt: "x", isBuiltIn: false)
        #expect(PolishStyles.style(id: custom.id, customStyles: [custom]) == custom)
    }

    @Test func styleLookupReturnsNilForUnknownID() {
        #expect(PolishStyles.style(id: UUID(), customStyles: []) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/PolishStylesTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: FAIL — `PolishStyles` doesn't exist yet, `PolishStyle` doesn't have `isBuiltIn`/`requiresTargetLanguage`.

- [ ] **Step 3: Expand `PolishBackend.swift`**

```swift
//
//  PolishBackend.swift
//  OmWhisper
//
//  AI text polish contract. Backends (M3): SystemLLM (Foundation Models, default),
//  Ollama, CloudLLM (OpenAI-compatible, keys in Keychain) — the latter two are a
//  separate sub-project. See docs/superpowers/specs/2026-07-07-m3-core-ai-polish-design.md.
//

import Foundation

struct PolishStyle: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var prompt: String
    var isBuiltIn: Bool
    /// Only meaningful for the Translate style; false for every other style.
    var requiresTargetLanguage: Bool = false
}

protocol PolishBackend: Sendable {
    /// `targetLanguage` is non-nil only when `style.requiresTargetLanguage`.
    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String
}
```

- [ ] **Step 4: Create `PolishStyles.swift`**

```swift
//
//  PolishStyles.swift
//  OmWhisper
//
//  Built-in style catalog. 7 styles, not the stale "6" referenced in some
//  older docs — Smart Correct was added later upstream (the old Tauri app's
//  PR #31) and this project's docs hadn't caught up. One canonical prompt per
//  style (not the old app's short/blunt-for-tiny-model variant — Foundation
//  Models is meaningfully more capable than that app's bundled 0.5B GGUF).
//
//  Fixed UUIDs (not `UUID()` per-launch) so `activePolishStyleID` survives
//  relaunches — these are permanent identifiers, never change them.
//

import Foundation

nonisolated enum PolishStyles {
    static let builtIns: [PolishStyle] = [
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000001")!,
            name: "Professional",
            prompt: """
            Rewrite the following dictated text in a formal, polished tone suitable \
            for professional communication. Preserve the original meaning and \
            approximate length. Output only the rewritten text, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000002")!,
            name: "Casual",
            prompt: """
            Lightly clean up the following dictated text: remove filler words \
            ("um", "uh", "like") and fix obvious grammar mistakes, but keep \
            contractions and an informal, conversational tone. Output only the \
            cleaned text, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000003")!,
            name: "Concise",
            prompt: """
            Rewrite the following dictated text to be 30-50% shorter, using active \
            voice, while preserving every piece of information. Output only the \
            rewritten text, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000004")!,
            name: "Translate",
            prompt: """
            Translate the following dictated text into {language}. Preserve the \
            original meaning and tone. Output only the translated text, nothing else.
            """,
            isBuiltIn: true,
            requiresTargetLanguage: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000005")!,
            name: "Email Format",
            prompt: """
            Rewrite the following dictated text as a well-formatted email: add an \
            appropriate greeting and closing, and organize the body into clear \
            paragraphs. Output only the formatted email text, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000006")!,
            name: "Meeting Notes",
            prompt: """
            Rewrite the following dictated text as structured meeting notes: use \
            bullet points, section headers where appropriate, and call out action \
            items clearly. Output only the formatted notes, nothing else.
            """,
            isBuiltIn: true
        ),
        PolishStyle(
            id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000007")!,
            name: "Smart Correct",
            prompt: """
            Clean up the following dictated text: remove filler words, fix grammar, \
            and handle spoken self-corrections (e.g. "wait no I meant Tuesday" means \
            replace the earlier day with Tuesday). Preserve the speaker's own voice \
            and wording as closely as possible — do not add content, do not rephrase \
            sentences that are already clean. Output only the corrected text, nothing else.

            Example: "so um the meeting is at 3pm wait no 4pm tomorrow" -> \
            "The meeting is at 4pm tomorrow."
            Example: "I think we should uh go with option B" -> \
            "I think we should go with option B."
            """,
            isBuiltIn: true
        ),
    ]

    static func all(customStyles: [PolishStyle]) -> [PolishStyle] {
        builtIns + customStyles
    }

    static func style(id: UUID, customStyles: [PolishStyle]) -> PolishStyle? {
        all(customStyles: customStyles).first { $0.id == id }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/PolishStylesTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 9/9 tests.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Polish/PolishBackend.swift omwhisper-native/Polish/PolishStyles.swift omwhisper-nativeTests/PolishStylesTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(polish): add PolishStyle model + built-in styles catalog" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 2: `SystemLLM` backend (Foundation Models)

**Files:**
- Create: `omwhisper-native/Polish/SystemLLM.swift`

**Interfaces:**
- Consumes: `PolishStyle`, `PolishBackend` protocol (Task 1).
- Produces: `SystemLLM: PolishBackend`, `SystemLLM.isAvailable() -> Bool`, `SystemLLM.PolishError` (thrown on timeout).

No unit tests for this task — Foundation Models can't be meaningfully mocked (same reasoning as `AppleEngine`, which also has no unit tests). Live-verified in Task 7.

- [ ] **Step 1: Create `SystemLLM.swift`**

```swift
//
//  SystemLLM.swift
//  OmWhisper
//
//  PolishBackend backed by Apple's Foundation Models framework — the default,
//  on-device polish backend. API verified directly against the macOS 26 SDK's
//  FoundationModels.swiftinterface (not guessed):
//    SystemLanguageModel.default.availability -> .available | .unavailable(reason)
//    LanguageModelSession(instructions: String?) — fresh session per call, stateless
//    session.respond(to: String) async throws -> Response<String>, .content is the text
//
//  A fresh LanguageModelSession per polish() call, not a shared/reused session —
//  each call is a one-shot rewrite with its own style-specific instructions, not
//  a multi-turn conversation.
//

import FoundationModels
import Foundation

nonisolated struct SystemLLM: PolishBackend {
    /// Wraps a slow/stuck model call so it can never stall a paste — the old
    /// app hard-capped its (much smaller, bundled) model at 2.5s for the same
    /// reason. 5s starting point for Foundation Models; tune from live testing.
    struct PolishError: Error, LocalizedError {
        var errorDescription: String? { "Polish timed out" }
    }

    static func isAvailable() -> Bool {
        SystemLanguageModel.default.availability == .available
    }

    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        let instructions = Self.instructions(for: style, targetLanguage: targetLanguage)
        let session = LanguageModelSession(instructions: instructions)

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let response = try await session.respond(to: text)
                return response.content
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw PolishError()
            }
            guard let result = try await group.next() else { throw PolishError() }
            group.cancelAll()
            return result
        }
    }

    private static func instructions(for style: PolishStyle, targetLanguage: String?) -> String {
        guard style.requiresTargetLanguage, let targetLanguage else { return style.prompt }
        return style.prompt.replacingOccurrences(of: "{language}", with: targetLanguage)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Polish/SystemLLM.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(polish): add SystemLLM (Foundation Models) backend" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 3: `AppState` wiring — settings, Smart Dictation orchestration

**Files:**
- Modify: `omwhisper-native/AppState.swift`
- Test: `omwhisper-nativeTests/SmartDictationLogicTests.swift`

**Interfaces:**
- Consumes: `PolishStyle`, `PolishStyles` (Task 1), `SystemLLM` (Task 2).
- Produces: `AppState.polishBackend`, `AppState.activePolishStyleID`, `AppState.translateTargetLanguage`, `AppState.customPolishStyles`, `AppState.activePolishStyle: PolishStyle?`, `AppState.beginSmartDictation()`, `AppState.minWordsGuardText(_:) -> Bool` (pure, testable — true means "too short, skip polish").

This task reuses the existing `toggleDictation()`/`stopDictation()` state machine rather than duplicating it — `toggleDictation()` and the new `beginSmartDictation()` both funnel through a shared private starter that takes a `smart: Bool` flag.

- [ ] **Step 1: Write the failing test for the pure min-words guard**

```swift
// omwhisper-nativeTests/SmartDictationLogicTests.swift
import Testing
@testable import OmWhisper

struct SmartDictationLogicTests {
    @Test func emptyTextFailsMinWordsGuard() {
        #expect(AppState.tooShortForPolish(""))
    }

    @Test func oneWordFailsMinWordsGuard() {
        #expect(AppState.tooShortForPolish("Hello"))
    }

    @Test func twoWordsFailsMinWordsGuard() {
        #expect(AppState.tooShortForPolish("Hello there"))
    }

    @Test func threeWordsPassesMinWordsGuard() {
        #expect(!AppState.tooShortForPolish("Hello there friend"))
    }

    @Test func extraWhitespaceDoesNotInflateWordCount() {
        #expect(AppState.tooShortForPolish("  Hello   there  "))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SmartDictationLogicTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: FAIL — `AppState.tooShortForPolish` doesn't exist yet.

- [ ] **Step 3: Add settings, in `AppState.swift`, right after the existing `fuzzyVocabCorrection` block and before `contextAwareDictationEnabled`**

Find:
```swift
    var fuzzyVocabCorrection: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.fuzzyVocabCorrection) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.fuzzyVocabCorrection) }
    }
    /// Off by default — every Smriti-derived feature in this project ships off
```

Replace with:
```swift
    var fuzzyVocabCorrection: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.fuzzyVocabCorrection) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.fuzzyVocabCorrection) }
    }
    /// Disabled by default — polish is opt-in.
    var polishBackend: PolishBackendKind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.polishBackend) else { return .disabled }
            return PolishBackendKind(rawValue: raw) ?? .disabled
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.polishBackend) }
    }
    /// Defaults to Smart Correct — the least presumptuous built-in (cleanup only,
    /// preserves the speaker's own wording), a safe universal default.
    var activePolishStyleID: UUID {
        get {
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.activePolishStyleID),
                  let id = UUID(uuidString: raw) else { return PolishStyles.builtIns[6].id }
            return id
        }
        set { UserDefaults.standard.set(newValue.uuidString, forKey: SettingsKeys.activePolishStyleID) }
    }
    var activePolishStyle: PolishStyle? {
        PolishStyles.style(id: activePolishStyleID, customStyles: customPolishStyles)
    }
    var translateTargetLanguage: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.translateTargetLanguage) ?? "English" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.translateTargetLanguage) }
    }
    var customPolishStyles: [PolishStyle] {
        get {
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.customPolishStyles) else { return [] }
            return (try? JSONDecoder().decode([PolishStyle].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.customPolishStyles) }
    }
    /// Off by default — every Smriti-derived feature in this project ships off
```
(the trailing `/// Off by default...` line is the start of the existing `contextAwareDictationEnabled` doc comment immediately after — left unchanged, just shown here as the anchor for where the new block ends.)

- [ ] **Step 4: Add `PolishBackendKind` enum, right before `nonisolated enum SettingsKeys`**

Find:
```swift
nonisolated enum SettingsKeys {
    static let pasteAfterStop = "pasteAfterStop"
```

Replace with:
```swift
nonisolated enum PolishBackendKind: String, Codable, CaseIterable {
    case disabled, system
    // Sub-project 2 adds: case ollama, cloud
}

nonisolated enum SettingsKeys {
    static let pasteAfterStop = "pasteAfterStop"
    static let polishBackend = "polishBackend"
    static let activePolishStyleID = "activePolishStyleID"
    static let translateTargetLanguage = "translateTargetLanguage"
    static let customPolishStyles = "customPolishStyles"
```

- [ ] **Step 5: Add the pure min-words guard as a `nonisolated static` function, right after `exitPhase`**

Find:
```swift
        if text.isEmpty {
            return .error(label: hadPartial ? "SOMETHING BROKE — TEXT COPIED" : "NOTHING HEARD")
        }
        return .pasting
    }
```

Replace with:
```swift
        if text.isEmpty {
            return .error(label: hadPartial ? "SOMETHING BROKE — TEXT COPIED" : "NOTHING HEARD")
        }
        return .pasting
    }

    /// True means "skip polish, paste raw" — near-silent/hallucinated
    /// recordings aren't worth an LLM call. Matches the old app's guard.
    nonisolated static func tooShortForPolish(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count < 3
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SmartDictationLogicTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 5/5 tests.

- [ ] **Step 7: Add the smart-dictation flag, the `systemLLM` collaborator, and the one-time nudge flag**

Find:
```swift
    /// Fired the instant dictation=.starting is claimed (S2 context-aware
    /// dictation), concurrently with permission checks/audioCapture.start() so
    /// the AX read doesn't add latency on top of work already happening. Awaited
    /// once, right before engine.transcribe(). nil when the feature is off.
    private var contextCaptureTask: Task<[String], Never>?
```

Replace with:
```swift
    /// Fired the instant dictation=.starting is claimed (S2 context-aware
    /// dictation), concurrently with permission checks/audioCapture.start() so
    /// the AX read doesn't add latency on top of work already happening. Awaited
    /// once, right before engine.transcribe(). nil when the feature is off.
    private var contextCaptureTask: Task<[String], Never>?

    private let systemLLM = SystemLLM()

    /// Set at the start of a session in beginSmartDictation()/toggleDictation(),
    /// read in stopDictation() to decide whether to run polish before pasting.
    /// Reset alongside the other per-session flags at the end of stopDictation().
    private var isSmartDictationSession = false

    /// Per-app-launch, not persisted — the Foundation-Models-unavailable nudge
    /// (errorMessage) only needs to fire once per run, not every polish attempt.
    private var didNudgeFoundationModelsUnavailable = false
```

- [ ] **Step 8: Refactor `toggleDictation()` into a shared starter, and add `beginSmartDictation()`**

Find:
```swift
    func toggleDictation() {
        switch dictation {
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            pttPressedAt = nil   // toggle has no "hold" concept — never inherit a stale PTT timestamp
            dictation = .starting
            overlay.show(appState: self)   // instant — warming look, before any permission/capture work
            contextCaptureTask = startContextCapture(enabled: contextAwareDictationEnabled)
            Task { await startDictation() }
        case .recording:
            Task { await stopDictation() }
        case .starting, .finalizing:
            break   // ignore toggles while a transition is in flight
        }
    }
```

Replace with:
```swift
    func toggleDictation() {
        toggleOrStop(smart: false)
    }

    /// Cmd+Shift+B — identical to toggleDictation() except it flags the session
    /// as smart, so stopDictation() runs the active polish style before pasting.
    /// Toggle-style, like Cmd+Shift+V — no separate PTT variant for this one.
    func beginSmartDictation() {
        toggleOrStop(smart: true)
    }

    private func toggleOrStop(smart: Bool) {
        switch dictation {
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            pttPressedAt = nil   // toggle has no "hold" concept — never inherit a stale PTT timestamp
            isSmartDictationSession = smart
            dictation = .starting
            overlay.show(appState: self)   // instant — warming look, before any permission/capture work
            contextCaptureTask = startContextCapture(enabled: contextAwareDictationEnabled)
            Task { await startDictation() }
        case .recording:
            Task { await stopDictation() }
        case .starting, .finalizing:
            break   // ignore toggles while a transition is in flight
        }
    }
```

- [ ] **Step 9: Inject polish into `stopDictation()`, between text computation and the paste call**

Find:
```swift
        let text = (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // errorMessage is nil'd at the top of every startDictation() and only the
        // transcriptionTask's catch block sets it during a session — so non-nil
        // here means the engine genuinely threw, not just "recording was silent."
        let hadEngineError = errorMessage != nil
        let phase = Self.exitPhase(heldFor: heldFor, text: text, hadPartial: hadEngineError)
        overlayPhase = phase

        if phase != .cancelled, soundEnabled {
            SoundPlayer.play(.stop, volume: Float(soundVolume))
        }

        if phase == .pasting, pasteAfterStop {
            if PasteService.hasAccessibilityPermission() {
                PasteService.paste(text)
                latencyLog.info("stop-to-paste: \(stopRequestedAt.duration(to: .now))")
```

Replace with:
```swift
        var text = (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // errorMessage is nil'd at the top of every startDictation() and only the
        // transcriptionTask's catch block sets it during a session — so non-nil
        // here means the engine genuinely threw, not just "recording was silent."
        let hadEngineError = errorMessage != nil
        let phase = Self.exitPhase(heldFor: heldFor, text: text, hadPartial: hadEngineError)
        overlayPhase = phase

        if phase != .cancelled, soundEnabled {
            SoundPlayer.play(.stop, volume: Float(soundVolume))
        }

        if phase == .pasting, isSmartDictationSession, !Self.tooShortForPolish(text) {
            overlayPhase = .polishing
            text = await polishedText(for: text)
            overlayPhase = phase
        }

        if phase == .pasting, pasteAfterStop {
            if PasteService.hasAccessibilityPermission() {
                PasteService.paste(text)
                latencyLog.info("stop-to-paste: \(stopRequestedAt.duration(to: .now))")
```

- [ ] **Step 10: Reset the smart-dictation flag alongside the existing per-session resets**

Find:
```swift
        pttPressedAt = nil
        recordingStartedAt = nil
        contextCaptureTask = nil
        await finishOverlayExit(exitDuration(for: phase))
```

Replace with:
```swift
        pttPressedAt = nil
        recordingStartedAt = nil
        contextCaptureTask = nil
        isSmartDictationSession = false
        await finishOverlayExit(exitDuration(for: phase))
```

- [ ] **Step 11: Add the shared `polishedText(for:)` helper, right after `stopDictation()` and before `exitPhase`**

Find:
```swift
    /// Pure decision: what the overlay's exit flourish should be. Evaluated
    /// *after* the transcript drains (not at key-release), so a quick-but-real
    /// utterance isn't wrongly cancelled. `heldFor` is nil for a toggle-stop
    /// (no hold concept — cancel is PTT-only, see OVERLAY_SPEC.md §9).
    nonisolated static func exitPhase(heldFor: Duration?, text: String, hadPartial: Bool) -> OverlayPhase {
```

Replace with:
```swift
    /// Runs the active style through the current backend; returns `original`
    /// unconditionally on any failure (backend Disabled, Foundation Models
    /// unavailable, model error, timeout) — dictated/selected text must never
    /// be silently dropped. Shows the one-time-per-launch Settings nudge
    /// specifically when the cause is Foundation Models being unavailable.
    private func polishedText(for original: String) async -> String {
        guard polishBackend == .system, let style = activePolishStyle else { return original }
        guard SystemLLM.isAvailable() else {
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = "Apple Intelligence is off — enable it in Settings > AI to use polish, or pasted raw text for now."
            }
            return original
        }
        do {
            let target = style.requiresTargetLanguage ? translateTargetLanguage : nil
            return try await systemLLM.polish(original, style: style, targetLanguage: target)
        } catch {
            log.error("polishedText — polish failed: \(error)")
            return original
        }
    }

    /// Pure decision: what the overlay's exit flourish should be. Evaluated
    /// *after* the transcript drains (not at key-release), so a quick-but-real
    /// utterance isn't wrongly cancelled. `heldFor` is nil for a toggle-stop
    /// (no hold concept — cancel is PTT-only, see OVERLAY_SPEC.md §9).
    nonisolated static func exitPhase(heldFor: Duration?, text: String, hadPartial: Bool) -> OverlayPhase {
```

- [ ] **Step 12: Add the `.polishing` case to `OverlayPhase`, at the top of the file**

Find:
```swift
nonisolated enum OverlayPhase: Equatable {
    case none
    case pasting
    case error(label: String)   // "NOTHING HEARD" | "SOMETHING BROKE — TEXT COPIED"
    case cancelled
}
```

Replace with:
```swift
nonisolated enum OverlayPhase: Equatable {
    case none
    case pasting
    case polishing               // Smart Dictation / Polish Selected Text running the active style
    case error(label: String)   // "NOTHING HEARD" | "SOMETHING BROKE — TEXT COPIED"
    case cancelled
}
```

- [ ] **Step 13: Add the Cmd+Shift+B `GlobalHotkey` instance**

Find:
```swift
    @ObservationIgnored private lazy var pushToTalk = PushToTalkMonitor(
        onStart: { [weak self] in self?.beginPushToTalk() },
        onEnd: { [weak self] in self?.endPushToTalk() }
    )
```

Replace with:
```swift
    @ObservationIgnored private lazy var pushToTalk = PushToTalkMonitor(
        onStart: { [weak self] in self?.beginPushToTalk() },
        onEnd: { [weak self] in self?.endPushToTalk() }
    )
    /// kVK_ANSI_B — Smart Dictation, always polishes with the active style.
    @ObservationIgnored private lazy var smartDictationHotkey = GlobalHotkey(
        keyCode: 11,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginSmartDictation()
    }
```

- [ ] **Step 14: Start the new hotkey alongside the existing ones in `init()`**

Find:
```swift
        if !isRunningUnderTests {
            hotkey.start()
            pushToTalk.start()
```

Replace with:
```swift
        if !isRunningUnderTests {
            hotkey.start()
            pushToTalk.start()
            smartDictationHotkey.start()
```

- [ ] **Step 15: Run the full suite to verify no regressions**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 78/78 tests (64 existing + 9 PolishStyles + 5 SmartDictationLogic).

- [ ] **Step 16: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-nativeTests/SmartDictationLogicTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(polish): wire Smart Dictation (Cmd+Shift+B) into AppState" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 4: Polish Selected Text (Cmd+Shift+P)

**Files:**
- Modify: `omwhisper-native/Paste/PasteService.swift`
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `PasteService.paste(_:)` (existing), `AppState.polishedText(for:)` (Task 3).
- Produces: `PasteService.copySelection() -> String?`, `AppState.beginPolishSelectedText()`.

No new tests — `copySelection()` drives real keyboard/pasteboard I/O (same category as `PasteService.paste()`, which also has no tests); the orchestration in `AppState` has no new pure logic beyond what Task 3 already covers. Live-verified in Task 7.

- [ ] **Step 1: Add `copySelection()` to `PasteService.swift`, mirroring `paste()`'s save/restore pattern in reverse**

Find:
```swift
    private static func sendCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
```

Replace with:
```swift
    private static func sendCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Reads whatever's selected in the frontmost app, for Polish Selected Text.
    /// Simulates Cmd+C rather than reading kAXSelectedTextAttribute — AX text
    /// selection is inconsistently supported across third-party/cross-toolkit
    /// apps, whereas Cmd+C works everywhere copy already works. Returns nil if
    /// nothing was selected (pasteboard content unchanged after the copy) or if
    /// the pasteboard had no prior string content to compare against a fresh one.
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.string(forType: .string)
        let beforeChangeCount = pasteboard.changeCount

        sendCmdC()
        // Cmd+C is asynchronous (goes through the target app's own event
        // handling) — give it a moment to land before reading the pasteboard.
        try? await Task.sleep(for: .milliseconds(150))

        guard pasteboard.changeCount != beforeChangeCount else { return nil }
        let after = pasteboard.string(forType: .string)
        guard let after, after != before else { return nil }
        return after
    }

    private static func sendCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: Add the Cmd+Shift+P hotkey and `beginPolishSelectedText()` in `AppState.swift`**

Find:
```swift
    /// kVK_ANSI_B — Smart Dictation, always polishes with the active style.
    @ObservationIgnored private lazy var smartDictationHotkey = GlobalHotkey(
        keyCode: 11,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginSmartDictation()
    }
```

Replace with:
```swift
    /// kVK_ANSI_B — Smart Dictation, always polishes with the active style.
    @ObservationIgnored private lazy var smartDictationHotkey = GlobalHotkey(
        keyCode: 11,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginSmartDictation()
    }
    /// kVK_ANSI_P — Polish Selected Text: copy the frontmost app's selection,
    /// polish it, paste it back in place. Not a dictation session — dictation
    /// stays .idle throughout; overlayPhase alone drives the brief pill.
    @ObservationIgnored private lazy var polishSelectedTextHotkey = GlobalHotkey(
        keyCode: 35,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginPolishSelectedText()
    }
```

- [ ] **Step 3: Start the new hotkey alongside the others**

Find:
```swift
        if !isRunningUnderTests {
            hotkey.start()
            pushToTalk.start()
            smartDictationHotkey.start()
```

Replace with:
```swift
        if !isRunningUnderTests {
            hotkey.start()
            pushToTalk.start()
            smartDictationHotkey.start()
            polishSelectedTextHotkey.start()
```

- [ ] **Step 4: Add `beginPolishSelectedText()`, right after `endPushToTalk()`**

Find:
```swift
    func endPushToTalk() {
        switch dictation {
        case .starting:
            stopRequestedWhilePTTStarting = true
        case .recording:
            Task { await stopDictation() }
        case .idle, .finalizing:
            break   // stray release with no matching press (e.g. focus changed mid-hold) — no-op
        }
    }
```

Replace with:
```swift
    func endPushToTalk() {
        switch dictation {
        case .starting:
            stopRequestedWhilePTTStarting = true
        case .recording:
            Task { await stopDictation() }
        case .idle, .finalizing:
            break   // stray release with no matching press (e.g. focus changed mid-hold) — no-op
        }
    }

    /// Cmd+Shift+P. Guarded on dictation == .idle so this can't fire mid-session
    /// and race the dictation state machine — press it while dictating and it's
    /// simply ignored. Nothing is selected -> silent no-op (no overlay, no paste).
    func beginPolishSelectedText() {
        guard dictation == .idle else { return }
        Task { await runPolishSelectedText() }
    }

    private func runPolishSelectedText() async {
        guard let original = await PasteService.copySelection() else { return }
        overlayPhase = .polishing
        overlay.show(appState: self)
        let result = await polishedText(for: original)
        overlay.hide()
        overlayPhase = .none
        PasteService.paste(result)
    }
```

- [ ] **Step 5: Build and run full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 78/78 (no new tests this task).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Paste/PasteService.swift omwhisper-native/AppState.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(polish): add Polish Selected Text (Cmd+Shift+P)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 5: Overlay `.polishing` visual state

**Files:**
- Modify: `omwhisper-native/UI/OverlayView.swift`

**Interfaces:**
- Consumes: `OverlayPhase.polishing` (Task 3).

No new tests — `OverlayView` is a SwiftUI view, matching this project's existing no-UI-tests convention. Live-verified in Task 7. No orb changes needed: `OmOrbView`'s `floor(for:)`/`targetGlow(for: .idle)` already return 0, so it renders calm/at-rest during Polish Selected Text (which never leaves `dictation == .idle`) with zero code changes — confirmed by reading the existing implementation.

- [ ] **Step 1: Make the pill visible during `.polishing` even when `dictation == .idle`**

Find:
```swift
    private var isVisible: Bool { appState.dictation != .idle }
```

Replace with:
```swift
    private var isVisible: Bool {
        appState.dictation != .idle || appState.overlayPhase == .polishing
    }
```

- [ ] **Step 2: Add the `POLISHING` label**

Find:
```swift
    private var statusLabel: String {
        switch appState.overlayPhase {
        case .pasting, .cancelled:
            return ""
        case .error(let label):
            return label
        case .none:
```

Replace with:
```swift
    private var statusLabel: String {
        switch appState.overlayPhase {
        case .pasting, .cancelled:
            return ""
        case .polishing:
            return "POLISHING"
        case .error(let label):
            return label
        case .none:
```

- [ ] **Step 3: Color the label — reuse `omTeal` (the "actively working" color already used for `LISTENING`)**

Find:
```swift
    private var labelColor: Color {
        if case .error = appState.overlayPhase { return .omError }
        switch appState.dictation {
        case .recording: return .omTeal
        case .finalizing: return .omMint
        default: return .omVolatile
        }
    }
```

Replace with:
```swift
    private var labelColor: Color {
        if case .error = appState.overlayPhase { return .omError }
        if case .polishing = appState.overlayPhase { return .omTeal }
        switch appState.dictation {
        case .recording: return .omTeal
        case .finalizing: return .omMint
        default: return .omVolatile
        }
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`. (`OverlayPhase` is `Equatable` already — the `switch appState.overlayPhase` in `statusLabel` must handle every case or the compiler will flag it; `.polishing` is exhaustively covered by Step 2.)

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/OverlayView.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(polish): add POLISHING overlay state" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 6: Settings AI tab

**Files:**
- Create: `omwhisper-native/UI/AISettingsView.swift`
- Modify: `omwhisper-native/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `AppState.polishBackend`, `.activePolishStyleID`, `.translateTargetLanguage`, `.customPolishStyles` (Task 3), `PolishStyles.builtIns`/`.all(customStyles:)` (Task 1).

No new tests — SwiftUI view, matching this project's convention. Live-verified in Task 7.

- [ ] **Step 1: Create `AISettingsView.swift`, following `VocabularySettingsView`'s form/list/add-row pattern**

```swift
//
//  AISettingsView.swift
//  OmWhisper
//
//  AI polish backend + style settings (M3 sub-project 1: System/Foundation
//  Models only — Ollama/Cloud are a separate sub-project). See
//  docs/superpowers/specs/2026-07-07-m3-core-ai-polish-design.md.
//

import SwiftUI

private let translateLanguages = [
    "English", "Spanish", "French", "German", "Japanese", "Chinese",
    "Hindi", "Portuguese", "Korean", "Arabic", "Russian",
]

struct AISettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newStyleName = ""
    @State private var newStylePrompt = ""

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Backend") {
                Picker("Polish backend", selection: $state.polishBackend) {
                    Text("Disabled").tag(PolishBackendKind.disabled)
                    Text("System (Apple Intelligence)").tag(PolishBackendKind.system)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Smart Dictation & Polish Selected Text") {
                Picker("Default style", selection: $state.activePolishStyleID) {
                    ForEach(PolishStyles.all(customStyles: state.customPolishStyles)) { style in
                        Text(style.name).tag(style.id)
                    }
                }
                if appState.activePolishStyle?.requiresTargetLanguage == true {
                    Picker("Target language", selection: $state.translateTargetLanguage) {
                        ForEach(translateLanguages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                }
                Text("Cmd+Shift+B always polishes what you just said. Cmd+Shift+P polishes whatever's selected in the frontmost app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Built-in Styles") {
                ForEach(PolishStyles.builtIns) { style in
                    Text(style.name)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Custom Styles") {
                ForEach(state.customPolishStyles) { style in
                    HStack {
                        Text(style.name)
                        Spacer()
                        Button {
                            removeStyle(style)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(style.name)")
                    }
                }
                VStack(alignment: .leading) {
                    TextField("Style name", text: $newStyleName)
                    TextField("Prompt", text: $newStylePrompt, axis: .vertical)
                        .lineLimit(2...4)
                    Button("Add Style", action: addStyle)
                        .disabled(trimmed(newStyleName).isEmpty || trimmed(newStylePrompt).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addStyle() {
        let name = trimmed(newStyleName)
        let prompt = trimmed(newStylePrompt)
        guard !name.isEmpty, !prompt.isEmpty else { return }
        appState.customPolishStyles.append(PolishStyle(id: UUID(), name: name, prompt: prompt, isBuiltIn: false))
        newStyleName = ""
        newStylePrompt = ""
    }

    private func removeStyle(_ style: PolishStyle) {
        appState.customPolishStyles.removeAll { $0.id == style.id }
        // Falling back to Smart Correct if the just-removed style was active —
        // activePolishStyleID would otherwise point at a style that no longer exists.
        if appState.activePolishStyleID == style.id {
            appState.activePolishStyleID = PolishStyles.builtIns[6].id
        }
    }
}

#Preview {
    AISettingsView().environment(AppState())
}
```

- [ ] **Step 2: Add the AI tab to `SettingsView.swift`**

Find:
```swift
            Tab("Vocabulary", systemImage: "textformat.abc") {
                VocabularySettingsView()
            }
            Tab("About", systemImage: "info.circle") {
```

Replace with:
```swift
            Tab("Vocabulary", systemImage: "textformat.abc") {
                VocabularySettingsView()
            }
            Tab("AI", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("About", systemImage: "info.circle") {
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/AISettingsView.swift omwhisper-native/UI/SettingsView.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(polish): add AI settings tab" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 7: Live verification + progress tracker update

**Files:**
- Modify: `CLAUDE.md`

No code changes beyond the doc update — this task is live verification of Tasks 1-6 together, on real hardware.

- [ ] **Step 1: Full clean build + test**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' clean build test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`, 78/78 tests passing.

- [ ] **Step 2: Live-verify System backend + Smart Dictation**

Launch the built app (not a test host). In Settings > AI: set backend to System, confirm the default style (Smart Correct). Bring a text-heavy window to front, run a real Cmd+Shift+B session (speak a short sentence with an obvious filler word or self-correction, e.g. "so um, the meeting is at 3pm, wait no, 4pm tomorrow"), confirm the overlay shows POLISHING before pasting, and confirm the pasted text is actually polished (fillers/self-correction handled), not raw. Try a second style (e.g. Concise) to confirm style switching works.

- [ ] **Step 3: Live-verify Polish Selected Text**

Select some rough text in a text editor, press Cmd+Shift+P, confirm the overlay briefly appears and the selection is replaced with polished text in place. Press Cmd+Shift+P with nothing selected — confirm silent no-op (no overlay, no paste, no crash).

- [ ] **Step 4: Live-verify the raw-fallback path**

Turn off Apple Intelligence in System Settings (or set backend to Disabled), run Cmd+Shift+B again — confirm the raw transcript still pastes (not lost), and confirm the one-time Settings nudge appears in `errorMessage`/the menu bar's error line. Repeat the same session type — confirm the nudge does NOT repeat (once-per-launch).

- [ ] **Step 5: Check for stray processes**

Run: `ps aux | grep "OmWhisper.app/Contents/MacOS/OmWhisper" | grep -v grep`
Expected: no output after the live-verification app instance is quit — clean up with `pkill -f "OmWhisper.app/Contents/MacOS/OmWhisper"` if anything lingers.

- [ ] **Step 6: Update `CLAUDE.md`'s Progress Tracker**

Add a row (or extend the `M3–M5` row) describing what shipped: styles catalog (7 built-ins), `SystemLLM` backend, Smart Dictation (Cmd+Shift+B), Polish Selected Text (Cmd+Shift+P), AI settings tab, unconditional raw-fallback fix (vs. the old app's `llm_not_ready` gap), and the actual measured/observed timeout behavior from Step 4. Note Ollama/Cloud backends + Keychain remain a separate, not-yet-started sub-project.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "$(printf '%s\n\n%s' "📝 docs: mark M3 sub-project 1 (core AI polish) shipped" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```
