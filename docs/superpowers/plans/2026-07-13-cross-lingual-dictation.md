# Cross-Lingual Dictation (F4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A persistent "I speak…" profile so normal dictation transcribes the user's mother tongue (Telugu/Hinglish/etc.) and pastes polished English.

**Architecture:** When `crossLingualEnabled`, `activeEngine` resolves to the multilingual Whisper engine (in the chosen spoken language); on stop, the shared `polishedText(for:)` pass swaps the active style for a combined *translate + normalize + apply-active-style-tone* prompt on the user's polish backend. If no backend is configured, Whisper's built-in `.translate` task produces raw English instead (never drops text).

**Tech Stack:** Swift 6 (MainActor-by-default), SwiftUI, WhisperKit (app-target only), Swift Testing.

## Global Constraints

- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Types callable from tests or off-MainActor must be marked `nonisolated` (see `EngineKind`, `PolishStyle`, `WhisperEngine`).
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), `@testable import OmWhisper`. Never add XCUITest.
- **WhisperKit must stay out of the test target** — anything importing `WhisperKit` (e.g. `Constants`) is not unit-testable here. Pure decisions must not import WhisperKit.
- Build/test command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test`. Swift Testing summary line is `Test run with N tests…`; the XCTest `Executed 0 tests` line is the empty shim, ignore it. Full suite is **301 tests** today.
- SourceKit often shows false "cannot find X / No such module 'FluidAudio'" errors across the whole file — trust `** BUILD SUCCEEDED **`, not the inline diagnostics.
- `@Observable` computed settings over `UserDefaults` MUST call `access(keyPath:)` in the getter and `withMutation(keyPath:)` in the setter (Pickers/Toggles need the Observation signal).
- UI follows `omwhisper-design`: Porcelain tokens, native controls, `.tint(Color.Porcelain.emerald)`, calm copy, no new colors.
- Feature is **off by default**.

## File Structure

- **Create** `omwhisper-native/CrossLingual.swift` — pure, nonisolated, WhisperKit-free decisions: engine override, in-engine-translate fallback, and the combined prompt builder. One responsibility: the cross-lingual decisions, isolated so they're testable.
- **Create** `omwhisper-nativeTests/CrossLingualTests.swift` — Swift Testing coverage for the three pure functions.
- **Modify** `omwhisper-native/Transcription/WhisperEngine.swift` — add a `setTranslateToEnglish(_:)` toggle + `languageName(forCode:)` helper; honor the translate task in `DecodingOptions`.
- **Modify** `omwhisper-native/AppState.swift` — `crossLingualEnabled` setting + `SettingsKeys` key; `activeEngine` and the vocab-merge use the effective engine kind; `startDictation` sets the translate flag + one-time engine nudge; `polishedText(for:)` uses the cross-lingual style; `spokenLanguageName` helper.
- **Modify** `omwhisper-native/UI/TranscriptionSettingsView.swift` — a "Cross-lingual dictation" `PorcelainSection` (toggle + "I speak…" picker + explainer).

---

### Task 1: CrossLingual pure decisions + prompt builder

**Files:**
- Create: `omwhisper-native/CrossLingual.swift`
- Test: `omwhisper-nativeTests/CrossLingualTests.swift`

**Interfaces:**
- Consumes: `EngineKind` (from `Transcription/TranscriptionEngine.swift`, already `nonisolated`), `PolishStyle` (from `Polish/PolishBackend.swift`, already `nonisolated`).
- Produces:
  - `CrossLingual.engineKind(base: EngineKind, crossLingual: Bool) -> EngineKind`
  - `CrossLingual.whisperTranslatesInEngine(crossLingual: Bool, hasBackend: Bool) -> Bool`
  - `CrossLingual.style(spokenLanguage: String, activeStyle: PolishStyle?) -> PolishStyle`
  - `CrossLingual.translateStyleID: UUID`

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/CrossLingualTests.swift`:

```swift
import Testing
import Foundation
@testable import OmWhisper

@Suite("CrossLingual")
struct CrossLingualTests {
    // A stand-in for the built-in Professional style.
    private var professional: PolishStyle {
        PolishStyle(id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000001")!,
                    name: "Professional", prompt: "Rewrite in a formal, polished tone.", isBuiltIn: true)
    }
    // The built-in Translate style (same fixed UUID as PolishStyles).
    private var translate: PolishStyle {
        PolishStyle(id: CrossLingual.translateStyleID,
                    name: "Translate", prompt: "Translate into {language}.", isBuiltIn: true,
                    requiresTargetLanguage: true)
    }

    @Test func forcesWhisperWhenOn() {
        #expect(CrossLingual.engineKind(base: .apple, crossLingual: true) == .whisper)
        #expect(CrossLingual.engineKind(base: .cloud, crossLingual: true) == .whisper)
    }

    @Test func passesThroughWhenOff() {
        #expect(CrossLingual.engineKind(base: .apple, crossLingual: false) == .apple)
        #expect(CrossLingual.engineKind(base: .parakeet, crossLingual: false) == .parakeet)
    }

    @Test func inEngineTranslateOnlyWhenNoBackend() {
        #expect(CrossLingual.whisperTranslatesInEngine(crossLingual: true, hasBackend: false) == true)
        #expect(CrossLingual.whisperTranslatesInEngine(crossLingual: true, hasBackend: true) == false)
        #expect(CrossLingual.whisperTranslatesInEngine(crossLingual: false, hasBackend: false) == false)
    }

    @Test func promptNamesLanguageAndFoldsActiveStyle() {
        let p = CrossLingual.style(spokenLanguage: "Telugu", activeStyle: professional).prompt
        #expect(p.contains("Telugu"))
        #expect(p.contains("Translate and normalize"))
        #expect(p.contains("formal, polished tone"))   // active style folded in
        #expect(p.hasSuffix("Output only the English text, nothing else."))
    }

    @Test func translateStyleIsSupersededNotAppended() {
        let p = CrossLingual.style(spokenLanguage: "Hindi", activeStyle: translate).prompt
        #expect(!p.contains("Additionally, follow this style instruction"))
        #expect(!p.contains("{language}"))
    }

    @Test func autoAndNilStyleGiveNeutralPrompt() {
        let p = CrossLingual.style(spokenLanguage: "auto", activeStyle: nil).prompt
        #expect(p.contains("another language"))
        #expect(!p.contains("Additionally, follow this style instruction"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "cannot find 'CrossLingual'|BUILD FAILED"`
Expected: build failure — `cannot find 'CrossLingual' in scope`.

- [ ] **Step 3: Write the implementation**

Create `omwhisper-native/CrossLingual.swift`:

```swift
//
//  CrossLingual.swift
//  OmWhisper
//
//  Pure decisions for cross-lingual dictation (F4). Deliberately nonisolated and
//  WhisperKit-free so they unit-test without MainActor or the app-only engine.
//  See docs/superpowers/specs/2026-07-13-cross-lingual-dictation-design.md.
//

import Foundation

nonisolated enum CrossLingual {
    /// The built-in Translate style's fixed UUID (see PolishStyles). Cross-lingual
    /// supersedes it — folding "translate into {language}" on top of our own
    /// translate prompt would double-translate.
    static let translateStyleID = UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000004")!

    /// Which engine actually transcribes. Cross-lingual forces Whisper (the only
    /// multilingual engine); otherwise the user's pick stands.
    static func engineKind(base: EngineKind, crossLingual: Bool) -> EngineKind {
        crossLingual ? .whisper : base
    }

    /// True when Whisper should translate to English in-engine (the degraded
    /// "lane b" fallback): only when cross-lingual is on AND there's no polish
    /// backend to do the higher-quality LLM translate.
    static func whisperTranslatesInEngine(crossLingual: Bool, hasBackend: Bool) -> Bool {
        crossLingual && !hasBackend
    }

    /// The combined translate + normalize + apply-active-style prompt, as a
    /// PolishStyle the existing backend call consumes. `spokenLanguage` is the
    /// human-readable name ("Telugu"); "" or "auto" means auto-detect.
    static func style(spokenLanguage: String, activeStyle: PolishStyle?) -> PolishStyle {
        let source = spokenLanguage.isEmpty || spokenLanguage.lowercased() == "auto"
            ? "another language (possibly mixed with English)"
            : "\(spokenLanguage) (possibly mixed with English)"
        var prompt = """
            The following was dictated in \(source). Translate and normalize it \
            into fluent, natural English — fix the code-switching, do not \
            translate word-for-word.
            """
        // Compose the user's active style, EXCEPT the Translate style (would
        // double-translate) and the no-style case → neutral clean English.
        if let activeStyle, activeStyle.id != translateStyleID {
            prompt += "\n\nAdditionally, follow this style instruction: \(activeStyle.prompt)"
        }
        prompt += "\n\nOutput only the English text, nothing else."
        return PolishStyle(
            id: UUID(uuidString: "F4000000-0000-4000-8000-000000000001")!,
            name: "Cross-Lingual",
            prompt: prompt,
            isBuiltIn: true
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "Test run with|BUILD FAILED"`
Expected: `Test run with 307 tests…` (301 + 6 new), no BUILD FAILED.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/CrossLingual.swift omwhisper-nativeTests/CrossLingualTests.swift
git commit -m "✨ feat(f4): cross-lingual pure decisions + prompt builder"
```

---

### Task 2: WhisperEngine — in-engine translate + language-name helper

**Files:**
- Modify: `omwhisper-native/Transcription/WhisperEngine.swift`

**Interfaces:**
- Produces:
  - `WhisperEngine.setTranslateToEnglish(_ on: Bool)` — off by default; when on, `transcribe` uses `DecodingOptions(task: .translate, …)`.
  - `WhisperEngine.languageName(forCode code: String) -> String` (`nonisolated static`) — "te" → "Telugu", "auto"/unknown → "".

No new unit test: `transcribe` needs WhisperKit (not in the test target) and the helpers are trivial wiring. Verified by build + Task 5 live run.

- [ ] **Step 1: Add `translateToEnglish` to State**

In `WhisperEngine.swift`, the `private struct State` (currently lines 35-40) — add one field:

```swift
    private struct State {
        var pipe: WhisperKit?
        var loadedModel: WhisperModel?
        var requestedModel: WhisperModel = .largeV3Turbo
        var requestedLanguage: String = "auto"
        var translateToEnglish: Bool = false
    }
```

- [ ] **Step 2: Add the setter + language-name helper**

Right after `setLanguage(_:)` (currently ending at line 83), add:

```swift
    /// When true, transcribe() runs Whisper's built-in translate task (any
    /// language → English) instead of transcribing the source. Used only as the
    /// no-polish-backend fallback for cross-lingual dictation.
    func setTranslateToEnglish(_ on: Bool) {
        state.withLockUnchecked { $0.translateToEnglish = on }
    }

    /// Human-readable name for a WhisperKit language code ("te" → "Telugu");
    /// "" for auto/unknown. Reverse of Constants.languages ([name: code]).
    nonisolated static func languageName(forCode code: String) -> String {
        guard code != "auto" else { return "" }
        return Constants.languages.first { $0.value == code }?.key.capitalized ?? ""
    }
```

- [ ] **Step 3: Honor the translate flag in transcribe()**

In `transcribe(...)`, the snapshot tuple (currently lines 123-129) and the `DecodingOptions` (currently lines 153-157). Replace the snapshot to also carry the flag, and set the task from it:

```swift
                let snapshot = state.withLockUnchecked { st -> (WhisperKit, String, Bool)? in
                    guard let p = st.pipe, st.loadedModel == st.requestedModel else { return nil }
                    return (p, st.requestedLanguage, st.translateToEnglish)
                }
                guard let (pipe, language, translate) = snapshot else {
                    throw EngineError.modelNotDownloaded
                }
```

and:

```swift
                let options = DecodingOptions(
                    task: translate ? .translate : .transcribe,
                    language: WhisperModel.decodeLanguage(language),
                    promptTokens: promptTokens
                )
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Transcription/WhisperEngine.swift
git commit -m "✨ feat(f4): WhisperEngine translate-to-English task + language-name helper"
```

---

### Task 3: AppState wiring

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `CrossLingual.engineKind`, `CrossLingual.whisperTranslatesInEngine`, `CrossLingual.style` (Task 1); `WhisperEngine.setTranslateToEnglish`, `WhisperEngine.languageName(forCode:)` (Task 2).
- Produces: `AppState.crossLingualEnabled: Bool` (settable, for the UI in Task 4).

No new unit test: this is wiring; the decisions are covered in Task 1 and the paths are verified live (Task 5). The existing 307-test suite staying green is the regression proof.

- [ ] **Step 1: Add the setting + SettingsKey**

Add the `crossLingualEnabled` computed property. Put it right after the `whisperLanguage` property (which currently ends at line 691, the closing brace of its setter):

```swift
    /// When on, normal dictation transcribes via Whisper in `whisperLanguage` and
    /// pastes polished English (translate + normalize + your active style, one
    /// backend pass). Off by default. See the F4 design spec.
    var crossLingualEnabled: Bool {
        get {
            access(keyPath: \.crossLingualEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.crossLingualEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.crossLingualEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.crossLingualEnabled)
            }
        }
    }

    /// Human-readable name of the spoken language, for the cross-lingual prompt.
    private var spokenLanguageName: String {
        WhisperEngine.languageName(forCode: whisperLanguage)
    }
```

Then add the key next to `whisperLanguage` in the `SettingsKeys` enum (the `whisperLanguage` key is currently at line 1650):

```swift
    static let crossLingualEnabled = "crossLingualEnabled"
```

- [ ] **Step 2: Add the one-time engine-nudge flag**

Next to `didNudgeFoundationModelsUnavailable` (currently line 863), add:

```swift
    private var didNudgeCrossLingualEngine = false
```

- [ ] **Step 3: Make `activeEngine` honor the override**

Replace the `activeEngine` computed property (currently lines 715-722):

```swift
    private var activeEngine: TranscriptionEngine {
        switch CrossLingual.engineKind(base: engineKind, crossLingual: crossLingualEnabled) {
        case .apple: appleEngine
        case .parakeet: parakeetEngine
        case .cloud: CloudEngine(provider: cloudProvider)   // stateless; built per session
        case .whisper: whisperEngine
        }
    }
```

- [ ] **Step 4: Wire the translate flag, nudge, and effective vocab kind at dictation start**

In `startDictation`, immediately before `let events = activeEngine.transcribe(...)` (currently line 1177). The `mergeEngineVocabulary` call and cloud-log check just above (lines 1168-1175) currently pass the raw `engineKind`; switch them to the effective kind and set up the engine:

```swift
            let effectiveEngineKind = CrossLingual.engineKind(base: engineKind, crossLingual: crossLingualEnabled)
            let engineVocabulary = mergeEngineVocabulary(
                customTerms: vocabSnapshot,
                screenTerms: screenTerms,
                engineKind: effectiveEngineKind
            )
            if effectiveEngineKind == .cloud, !screenTerms.isEmpty {
                log.debug("cloud engine active: excluding \(screenTerms.count) screen term(s) from vocabulary")
            }
            // Cross-lingual: nudge once if we're overriding the user's engine, and
            // pick Whisper's in-engine translate only when there's no polish backend.
            if crossLingualEnabled, engineKind != .whisper, !didNudgeCrossLingualEngine {
                didNudgeCrossLingualEngine = true
                errorMessage = "Cross-lingual dictation uses the Whisper engine."
            }
            whisperEngine.setTranslateToEnglish(
                CrossLingual.whisperTranslatesInEngine(crossLingual: crossLingualEnabled, hasBackend: activePolishBackend() != nil)
            )

            let events = activeEngine.transcribe(audioStream, vocabulary: engineVocabulary)
```

(Delete the original lines 1168-1175 — the `let engineVocabulary = mergeEngineVocabulary(… engineKind: engineKind)` block and its `if engineKind == .cloud …` log — they're replaced above.)

- [ ] **Step 5: Route `polishedText` through the cross-lingual style**

Replace the body of `polishedText(for:)` (currently lines 1467-1485) with a version that picks the style up front:

```swift
    private func polishedText(for original: String) async -> String {
        // The one-time nudge fires only when System is selected but off — not for
        // Disabled or an unconfigured Ollama, which are deliberate "no polish" states.
        if polishBackend == .system, !SystemLLM.isAvailable() {
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = "Apple Intelligence is off — enable it in Settings > AI to use polish, or pasted raw text for now."
            }
            return original
        }
        guard let backend = activePolishBackend() else { return original }
        let style: PolishStyle
        let target: String?
        if crossLingualEnabled {
            // original is the source-language transcript (backend present → we run
            // the LLM translate here) — or already English if Whisper's .translate
            // fallback ran, in which case a second polish pass is harmless cleanup.
            style = CrossLingual.style(spokenLanguage: spokenLanguageName, activeStyle: activePolishStyle)
            target = nil
        } else {
            guard let active = activePolishStyle else { return original }
            style = active
            target = active.requiresTargetLanguage ? translateTargetLanguage : nil
        }
        do {
            return try await backend.polish(original, style: style, targetLanguage: target)
        } catch {
            log.error("polishedText — polish failed: \(error)")
            return original
        }
    }
```

- [ ] **Step 6: Build + run the suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "error:|Test run with|BUILD FAILED" | tail -5`
Expected: `Test run with 307 tests…`, no errors. (No new tests; the pure decisions were covered in Task 1.)

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(f4): wire cross-lingual into engine selection + polish pass"
```

---

### Task 4: Transcription settings UI

**Files:**
- Modify: `omwhisper-native/UI/TranscriptionSettingsView.swift`

**Interfaces:**
- Consumes: `AppState.crossLingualEnabled` (Task 3), the existing `whisperLanguageOptions` helper (currently lines 204-206) and `$state.whisperLanguage` binding.

No new unit test (pure SwiftUI, verified live per project convention).

- [ ] **Step 1: Add the cross-lingual section**

In `TranscriptionSettingsView.swift`, immediately after the `PorcelainSection(eyebrow: "Engine") { … }` block (the engine picker, currently starting line 32) and before the per-engine sections, add:

```swift
            PorcelainSection(eyebrow: "Cross-Lingual") {
                Toggle("Speak another language, write English", isOn: $state.crossLingualEnabled)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                if state.crossLingualEnabled {
                    Picker("I speak", selection: $state.whisperLanguage) {
                        Text("Auto-detect").tag("auto")
                        ForEach(whisperLanguageOptions, id: \.code) { opt in
                            Text(opt.name).tag(opt.code)
                        }
                    }
                }
                Text("Dictate in your language; polished English comes out. Uses the Whisper engine — download it below if you haven't.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/TranscriptionSettingsView.swift
git commit -m "✨ feat(f4): cross-lingual settings section (toggle + I-speak picker)"
```

---

### Task 5: Live verification (manual — user)

Not an automated task. Confirm on real hardware (needs a Whisper model downloaded + a native speaker):

- [ ] Enable **Cross-lingual dictation**, pick **Telugu** (or your language), ensure a Whisper model is downloaded and a polish backend is set.
- [ ] With the engine set to Apple/Parakeet/Cloud, start dictation → the one-time "uses the Whisper engine" nudge appears; the overlay shows listening → POLISHING → English.
- [ ] Speak a Tenglish/Hinglish sentence → clean English is pasted. Repeat across ~20 real utterances; ≥80% usable without edits (F4 exit bar). Latency ≤ dictation + one polish pass.
- [ ] Set the polish backend to **Disabled** → dictation still pastes English (Whisper `.translate` fallback), no crash.
- [ ] Turn cross-lingual **off** → normal English dictation is unchanged (regression check).

---

## Self-Review

**1. Spec coverage:**
- Persistent "I speak…" profile → Task 3 (`crossLingualEnabled`) + Task 4 (UI reusing `whisperLanguage`). ✓
- Follow active polish backend → Task 3 `polishedText` uses `activePolishBackend()`. ✓
- Whisper multilingual ASR + single combined pass → Task 1 (`style`) + Task 3 (`polishedText`). ✓
- Compose with active style; Translate superseded → Task 1 (`style` + `translateStyleID`), tested. ✓
- No-backend `.translate` fallback → Task 1 (`whisperTranslatesInEngine`) + Task 2 (engine) + Task 3 (wiring). ✓
- Engine override + one-time nudge → Task 3 Steps 3-4. ✓
- Scope normal + Smart Dictation (both route through `polishedText`); brain-dump deferred (uses `brainDumpStructured`, untouched) → no task, correctly out of scope. ✓
- Overlay reuses POLISHING sub-phase → no code needed (POLISHING already fires when `polishedText` runs); no task. ✓
- Settings in Transcription tab → Task 4. ✓
- Off by default → Task 3 Step 1 (`?? false`). ✓
- Tests: prompt builder, engine-override, fallback decision → Task 1. ✓
- **Deliberate refinement vs. spec:** the spec said "Whisper model not downloaded → fall back to normal dictation." Falling back to a non-multilingual engine (Apple) would *mistranscribe* the non-English speech into garbage, which is worse than a clear prompt. So the plan keeps the existing behavior: `WhisperEngine.transcribe` throws `modelNotDownloaded` → the overlay shows "Download the Whisper model in Settings." No extra task; more honest.

**2. Placeholder scan:** No TBD/TODO. Every code step shows complete code and exact commands.

**3. Type consistency:** `CrossLingual.engineKind` / `.whisperTranslatesInEngine` / `.style` / `.translateStyleID` are used identically in Tasks 1 and 3. `setTranslateToEnglish` / `languageName(forCode:)` defined in Task 2, consumed in Task 3. `crossLingualEnabled` defined in Task 3, consumed in Task 4. `whisperLanguageOptions` / `whisperLanguage` are pre-existing (verified). ✓
