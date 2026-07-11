# Whisper Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in fourth transcription engine — Whisper via WhisperKit — with a user-selectable model (base/small/large-v3-turbo) and language, transcribing on key-release.

**Architecture:** One new `TranscriptionEngine` conformer (`WhisperEngine`, a `nonisolated final class` caching one loaded `WhisperKit` pipeline per model behind an `OSAllocatedUnfairLock`, mirroring `ParakeetEngine`). It accumulates the mic `AsyncStream` into 16 kHz-mono-Float32 samples and, on stream-end, runs one `WhisperKit.transcribe(audioArray:)` pass emitting a single `.final`. New `EngineKind` case, settings, and Settings section, exactly like M4.1 (Parakeet) / M4.2 (Cloud).

**Tech Stack:** Swift 6, WhisperKit (argmaxinc) via SPM, CoreML on-device, existing `BufferConverter` for resampling.

## Global Constraints

- **WhisperKit version: pin to `0.18.0`** (the 0.x line — the classic `WhisperKit(config)` / `transcribe(audioArray:)` API). **Do NOT use v1.0.0**: it restructured into an `argmax-oss-swift` monorepo on `@_exported import ArgmaxCore`, a newer/undocumented surface. Repo URL: `https://github.com/argmaxinc/WhisperKit`. Product: `WhisperKit`. **App target only** (never the test target), matching FluidAudio/Sparkle.
- **WhisperKit must never be imported by the test target.** All unit-tested helpers are pure (plain Swift types only) and live in `WhisperModel.swift`, which does NOT import WhisperKit. `WhisperEngineTests` tests only those. This mirrors `ParakeetEngineTests` keeping FluidAudio app-only.
- **Model variant strings (exact, verified against WhisperKit 0.18.0 + the `argmaxinc/whisperkit-coreml` repo):**
  - `.base` → `"openai_whisper-base"`
  - `.small` → `"openai_whisper-small"`
  - `.largeV3Turbo` → `"openai_whisper-large-v3-v20240930_turbo"`
- **Apple stays the default engine.** `engineKind` default is `.apple`; existing Apple/Parakeet/Cloud behavior is untouched. The full suite (currently 279 tests) must stay green after every task.
- **Every new AppState setting** uses the `access(keyPath:)` / `withMutation(keyPath:)` pattern (so bound `.radioGroup`/`Picker` controls re-render), matching `engineKind` / `parakeetModel`.
- **`nonisolated`** on the engine class and its `transcribe`/`isReady`/helpers (the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` otherwise pins them to MainActor and breaks the protocol conformance — the exact gotcha `ParakeetEngine`/`CloudEngine` hit).
- **Do not touch** the three pre-existing uncommitted files (`docs/OVERLAY_SPEC.md`, `docs/COMPETITOR_FLUIDVOICE.md`) — and `project.pbxproj` is handled only by Task 1's coordinated dependency add.
- Build command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`.

---

## Verified WhisperKit 0.18.0 API (reference for all tasks)

```swift
// Download a model variant with progress; returns the on-disk folder URL.
public static func download(
    variant: String, downloadBase: URL? = nil, useBackgroundSession: Bool = false,
    from repo: String = "argmaxinc/whisperkit-coreml", token: String? = nil,
    endpoint: String = Constants.defaultRemoteEndpoint,
    progressCallback: ((Progress) -> Void)? = nil
) async throws -> URL

// Load a downloaded model from its folder (modelFolder set → loads, no re-download).
public init(_ config: WhisperKitConfig = WhisperKitConfig()) async throws
// WhisperKitConfig(model: String? = nil, modelFolder: String? = nil, download: Bool = true, load: Bool? = nil, ...)

// Transcribe raw 16 kHz mono float samples.
open func transcribe(audioArray: [Float], decodeOptions: DecodingOptions? = nil,
                     callback: TranscriptionCallback = nil) async throws -> [TranscriptionResult]
// TranscriptionResult.text : String

// Decoding options (all defaulted).
public struct DecodingOptions {
    public init(task: DecodingTask = .transcribe, language: String? = nil, /* ... */
                usePrefillPrompt: Bool = true, promptTokens: [Int]? = nil, prefixTokens: [Int]? = nil, /* ... */)
}
public enum DecodingTask { case transcribe, translate }

// Tokenizer for prompt biasing. WhisperKit filters special tokens from promptTokens itself.
public var tokenizer: WhisperTokenizer?   // WhisperTokenizer.encode(text: String) -> [Int]

// Language list for the picker: [displayName : code], includes "hindi":"hi", "telugu":"te", etc.
Constants.languages : [String: String]
```

---

### Task 1: Add the WhisperKit SPM dependency (coordinated)

Adding an SPM package edits `project.pbxproj`, which currently holds the user's uncommitted cosmetic changes. This task is a **coordination gate**, not an automated edit — resolve it with the user before proceeding.

**Preferred path (user adds via Xcode — most reliable, additive to their changes):**
Give the user these exact steps:
1. Xcode → File → Add Package Dependencies…
2. URL: `https://github.com/argmaxinc/WhisperKit`
3. Dependency Rule: **Exact Version → `0.18.0`** (NOT "Up to Next Major", which could resolve v1.0.0).
4. Add to target **`omwhisper-native`** only (NOT `omwhisper-nativeTests`).
5. Product: **`WhisperKit`**.
6. Let Xcode resolve, then confirm.

**Fallback (hand-edit `project.pbxproj`)** — only if the user asks you to, and only after confirming their cosmetic changes are committed/stashed or that adding alongside them is acceptable. Mirror the existing FluidAudio entries (5 insertion points), using fresh unique 24-char uppercase-hex IDs that don't collide with any existing ID:

- `PBXBuildFile` section: `<ID_A> /* WhisperKit in Frameworks */ = {isa = PBXBuildFile; productRef = <ID_B> /* WhisperKit */; };`
- App target's `Frameworks` build phase files list (the one containing `FluidAudio in Frameworks`): add `<ID_A> /* WhisperKit in Frameworks */,`
- App target's `packageProductDependencies`: add `<ID_B> /* WhisperKit */,`
- Project's `packageReferences`: add `<ID_C> /* XCRemoteSwiftPackageReference "WhisperKit" */,`
- `XCRemoteSwiftPackageReference` section:
  ```
  <ID_C> /* XCRemoteSwiftPackageReference "WhisperKit" */ = {
      isa = XCRemoteSwiftPackageReference;
      repositoryURL = "https://github.com/argmaxinc/WhisperKit";
      requirement = { kind = exactVersion; version = 0.18.0; };
  };
  ```
- `XCSwiftPackageProductDependency` section:
  ```
  <ID_B> /* WhisperKit */ = {
      isa = XCSwiftPackageProductDependency;
      package = <ID_C> /* XCRemoteSwiftPackageReference "WhisperKit" */;
      productName = WhisperKit;
  };
  ```

- [ ] **Step 1:** Resolve the pbxproj-change prerequisite with the user (commit/stash cosmetic changes, or confirm additive add), then add the dependency (preferred: user via Xcode UI).
- [ ] **Step 2:** Verify resolution + no regression. Add a temporary file `omwhisper-native/Transcription/_WhisperProbe.swift` containing exactly:
  ```swift
  import WhisperKit
  nonisolated let _whisperProbe = "openai_whisper-base"
  ```
- [ ] **Step 3:** Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
  Expected: `** TEST SUCCEEDED **`, 279 tests. (Confirms WhisperKit links and the test target still builds without it.)
- [ ] **Step 4:** Delete `_WhisperProbe.swift`.
- [ ] **Step 5:** Commit (whatever pbxproj/package-resolved files changed):
  ```bash
  git add -A
  git commit -m "build: add WhisperKit 0.18.0 SPM dependency (app target)"
  ```

---

### Task 2: `WhisperModel` enum + pure helpers (TDD)

**Files:**
- Create: `omwhisper-native/Transcription/WhisperModel.swift`
- Test: `omwhisper-nativeTests/WhisperEngineTests.swift`

**Interfaces:**
- Produces (used by Tasks 3–5): `WhisperModel` (`.base`/`.small`/`.largeV3Turbo`, `String`-raw, `CaseIterable`, `Identifiable`); statics `WhisperModel.whisperKitModelID(for:) -> String`, `WhisperModel.decodeLanguage(_:) -> String?`, `WhisperModel.vocabularyPrompt(_:) -> String`. No WhisperKit import.

- [ ] **Step 1: Write the failing tests** — `omwhisper-nativeTests/WhisperEngineTests.swift`:
```swift
import Testing
@testable import OmWhisper

@Suite("WhisperEngine")
struct WhisperEngineTests {
    @Test("WhisperModel rawValues round-trip and cover all variants")
    func modelRawValues() {
        #expect(WhisperModel(rawValue: "base") == .base)
        #expect(WhisperModel(rawValue: "small") == .small)
        #expect(WhisperModel(rawValue: "largeV3Turbo") == .largeV3Turbo)
        #expect(WhisperModel.allCases == [.base, .small, .largeV3Turbo])
        #expect(WhisperModel(rawValue: "bogus") == nil)
    }

    @Test("model maps to the exact WhisperKit variant string")
    func modelID() {
        #expect(WhisperModel.whisperKitModelID(for: .base) == "openai_whisper-base")
        #expect(WhisperModel.whisperKitModelID(for: .small) == "openai_whisper-small")
        #expect(WhisperModel.whisperKitModelID(for: .largeV3Turbo) == "openai_whisper-large-v3-v20240930_turbo")
    }

    @Test("decodeLanguage maps auto to nil, else the code")
    func language() {
        #expect(WhisperModel.decodeLanguage("auto") == nil)
        #expect(WhisperModel.decodeLanguage("te") == "te")
        #expect(WhisperModel.decodeLanguage("en") == "en")
    }

    @Test("vocabularyPrompt joins terms; empty list yields empty string")
    func prompt() {
        #expect(WhisperModel.vocabularyPrompt([]) == "")
        #expect(WhisperModel.vocabularyPrompt(["SwiftUI", "Parakeet"]) == "SwiftUI, Parakeet")
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -iE "cannot find|error:|TEST"`. Expected: fails ("Cannot find 'WhisperModel' in scope").

- [ ] **Step 3: Implement** — `omwhisper-native/Transcription/WhisperModel.swift`:
```swift
//
//  WhisperModel.swift
//  OmWhisper
//
//  User-selectable Whisper variant + pure mapping helpers. No WhisperKit types,
//  so it backs a UserDefaults setting and is unit-testable without linking
//  WhisperKit into the test target (WhisperKit is app-target-only, like FluidAudio).
//

import Foundation

nonisolated enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case base, small, largeV3Turbo   // largeV3Turbo is the default

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base: "Base"
        case .small: "Small"
        case .largeV3Turbo: "Large v3 Turbo"
        }
    }

    var subtitle: String {
        switch self {
        case .base: "~150 MB · fastest, lower accuracy"
        case .small: "~500 MB · balanced"
        case .largeV3Turbo: "~1.5 GB · best accuracy, fast on Apple Silicon"
        }
    }

    /// Exact `argmaxinc/whisperkit-coreml` variant folder name.
    static func whisperKitModelID(for model: WhisperModel) -> String {
        switch model {
        case .base: "openai_whisper-base"
        case .small: "openai_whisper-small"
        case .largeV3Turbo: "openai_whisper-large-v3-v20240930_turbo"
        }
    }

    /// "auto" → nil (WhisperKit auto-detects); otherwise the language code.
    static func decodeLanguage(_ code: String) -> String? {
        code == "auto" ? nil : code
    }

    /// Custom vocabulary → a Whisper decoding prompt (its context-biasing input).
    /// Empty terms → empty string (caller passes no promptTokens).
    static func vocabularyPrompt(_ terms: [String]) -> String {
        terms.joined(separator: ", ")
    }
}
```

- [ ] **Step 4: Run to verify pass** — same command. Expected: `** TEST SUCCEEDED **`, 283 tests (279 + 4 new).

- [ ] **Step 5: Commit**
```bash
git add omwhisper-native/Transcription/WhisperModel.swift omwhisper-nativeTests/WhisperEngineTests.swift
git commit -m "feat(whisper): WhisperModel enum + pure mapping helpers"
```

---

### Task 3: `WhisperEngine` (load + transcribe-on-release)

**Files:**
- Create: `omwhisper-native/Transcription/WhisperEngine.swift`

**Interfaces:**
- Consumes: `WhisperModel` + its statics (Task 2); `TranscriptionEngine`/`TranscriptEvent`/`EngineKind` (existing); `BufferConverter` (existing); WhisperKit (Task 1).
- Produces (used by Tasks 4–5): `WhisperEngine()` conforming to `TranscriptionEngine`; `isReady: Bool`; `setModel(_:)`; `setLanguage(_:)`; `ensureModelLoaded(progressHandler:)`.

**Note on concurrency:** `WhisperKit` is an `open class` and not `Sendable`. Guard it with `OSAllocatedUnfairLock` exactly like `ParakeetEngine`, but use **`withLockUnchecked`** for accesses (the lock is the real guarantee; this mirrors the codebase's existing "assert the invariant ourselves" stance for non-Sendable AV types in `AudioCapture`). `EngineKind` is added to it in Task 4 — this task references `.whisper`, so **do Task 4's `EngineKind` one-line change first if compiling this task standalone** (or the implementer adds `case whisper` when needed). The `kind` property below uses it.

- [ ] **Step 1: Implement** — `omwhisper-native/Transcription/WhisperEngine.swift`:
```swift
//
//  WhisperEngine.swift
//  OmWhisper
//
//  Optional TranscriptionEngine backend: on-device Whisper via WhisperKit.
//  Whisper is chunk-based, not a streaming/online model — so this engine
//  ACCUMULATES the whole mic stream and transcribes once on stream-end,
//  emitting a single .final (no partials). That is the simplest fit for the
//  streaming protocol and gives Whisper full-utterance context (best accuracy).
//
//  Caching: loading a Whisper CoreML pipeline is multi-second, so one WhisperKit
//  instance is cached per selected model (like ParakeetEngine caches AsrModels).
//  WhisperKit is a non-Sendable class → guarded by OSAllocatedUnfairLock with
//  withLockUnchecked (the lock is the guarantee), matching AudioCapture's stance.
//
//  transcribe() does NOT auto-download (a turbo model is ~1.5 GB and must never
//  block a live session): if the model isn't loaded it throws modelNotDownloaded,
//  surfaced in the overlay. Download is a Settings-only action (ensureModelLoaded).
//

@preconcurrency import AVFoundation
import WhisperKit
import os

nonisolated final class WhisperEngine: TranscriptionEngine {
    let kind: EngineKind = .whisper

    enum EngineError: Error, LocalizedError {
        case modelNotDownloaded
        var errorDescription: String? { "Download the Whisper model in Settings." }
    }

    private struct State {
        var pipe: WhisperKit?
        var loadedModel: WhisperModel?
        var requestedModel: WhisperModel = .largeV3Turbo
        var requestedLanguage: String = "auto"
    }

    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())

    /// The requested variant's pipeline is loaded. Keys off the model so Settings
    /// shows the right download state after a model switch.
    nonisolated var isReady: Bool {
        state.withLockUnchecked { $0.pipe != nil && $0.loadedModel == $0.requestedModel }
    }

    func setModel(_ model: WhisperModel) {
        state.withLockUnchecked { $0.requestedModel = model }
    }

    /// Language code, or "auto". Changing it needs no reload (it's a decode option).
    func setLanguage(_ code: String) {
        state.withLockUnchecked { $0.requestedLanguage = code }
    }

    /// Downloads (with progress) + loads the requested model's pipeline if not
    /// already loaded for that model. Called from Settings' Download button — NOT
    /// lazily from transcribe(). Idempotent.
    func ensureModelLoaded(progressHandler: ((Progress) -> Void)? = nil) async throws {
        let requested = state.withLockUnchecked { $0.requestedModel }
        if state.withLockUnchecked({ $0.pipe != nil && $0.loadedModel == requested }) { return }
        let variant = WhisperModel.whisperKitModelID(for: requested)
        let folder = try await WhisperKit.download(variant: variant, progressCallback: { p in
            progressHandler?(p)
        })
        let pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path))
        state.withLockUnchecked { $0.pipe = pipe; $0.loadedModel = requested }
    }

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()

        let task = Task {
            do {
                // Grab the loaded pipe + language snapshot. nil => not downloaded.
                let snapshot = state.withLockUnchecked { st -> (WhisperKit, String)? in
                    guard let p = st.pipe, st.loadedModel == st.requestedModel else { return nil }
                    return (p, st.requestedLanguage)
                }
                guard let (pipe, language) = snapshot else {
                    throw EngineError.modelNotDownloaded
                }

                // Accumulate 16 kHz mono Float32 samples via the existing converter.
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
                ) else { throw EngineError.modelNotDownloaded }
                let converter = BufferConverter()
                var samples: [Float] = []
                for await buffer in audio {
                    guard let converted = try? converter.convertBuffer(buffer, to: format),
                          let ch = converted.floatChannelData else { continue }
                    samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))
                }

                guard !samples.isEmpty else { continuation.finish(); return }

                let prompt = WhisperModel.vocabularyPrompt(vocabulary)
                // Leading space is the Whisper BPE prompt convention; WhisperKit
                // strips special tokens from promptTokens itself.
                let promptTokens = prompt.isEmpty ? nil : pipe.tokenizer?.encode(text: " " + prompt)
                let options = DecodingOptions(
                    task: .transcribe,
                    language: WhisperModel.decodeLanguage(language),
                    promptTokens: promptTokens
                )
                let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
                let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { continuation.yield(.final(text)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
```

- [ ] **Step 2: Build** — `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -iE "error:|TEST SUCCEEDED|Test run with"`. Expected: `** TEST SUCCEEDED **`, 283 tests (no new tests — the engine's live path is verified on-device, not unit-tested; the pure helpers were Task 2). If `withLockUnchecked` or `sending`/`nonisolated` errors appear, they are real — resolve per the notes above (do NOT downgrade to `withLock`, which fails on the non-Sendable `WhisperKit`). Ignore SourceKit "No such module 'WhisperKit'" (false alarm; the real build links it).

- [ ] **Step 3: Commit**
```bash
git add omwhisper-native/Transcription/WhisperEngine.swift
git commit -m "feat(whisper): WhisperEngine — load + transcribe-on-release"
```

---

### Task 4: AppState + EngineKind wiring

**Files:**
- Modify: `omwhisper-native/Transcription/TranscriptionEngine.swift` (add `EngineKind` case)
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `WhisperEngine`, `WhisperModel` (Tasks 2–3).
- Produces (used by Task 5): `appState.whisperEngine`, `$state.whisperModel`, `$state.whisperLanguage`.

- [ ] **Step 1: Add the EngineKind case** — `omwhisper-native/Transcription/TranscriptionEngine.swift`, in `enum EngineKind`:
```swift
    case whisper    // WhisperKit CoreML — optional download, broad language coverage
```
(place after `case cloud`).

- [ ] **Step 2: Add the collaborator + activeEngine branch** — `omwhisper-native/AppState.swift`. Below `let parakeetEngine = ParakeetEngine()` add:
```swift
    let whisperEngine = WhisperEngine()
```
In `activeEngine`'s switch, add:
```swift
        case .whisper: whisperEngine
```

- [ ] **Step 3: Add the two settings** — in `AppState.swift`, next to `parakeetModel` (same access/withMutation shape):
```swift
    /// Which Whisper variant to load (only relevant when engineKind == .whisper).
    /// access/withMutation so the radio picker re-highlights; setter syncs the engine.
    var whisperModel: WhisperModel {
        get {
            access(keyPath: \.whisperModel)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.whisperModel),
                  let model = WhisperModel(rawValue: raw) else { return .largeV3Turbo }
            return model
        }
        set {
            withMutation(keyPath: \.whisperModel) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.whisperModel)
            }
            whisperEngine.setModel(newValue)
        }
    }

    /// Whisper spoken-language code ("auto" = detect). Changing it needs no reload.
    var whisperLanguage: String {
        get {
            access(keyPath: \.whisperLanguage)
            return UserDefaults.standard.string(forKey: SettingsKeys.whisperLanguage) ?? "auto"
        }
        set {
            withMutation(keyPath: \.whisperLanguage) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.whisperLanguage)
            }
            whisperEngine.setLanguage(newValue)
        }
    }
```

- [ ] **Step 4: Sync the engine at init** — in `AppState.init()`, inside the `if !isRunningUnderTests {` block, next to the `parakeetEngine.setModel(parakeetModel)` line:
```swift
            whisperEngine.setModel(whisperModel)
            whisperEngine.setLanguage(whisperLanguage)
```

- [ ] **Step 5: Add the SettingsKeys** — in the `SettingsKeys` enum, next to `parakeetModel`:
```swift
    static let whisperModel = "whisperModel"
    static let whisperLanguage = "whisperLanguage"
```

- [ ] **Step 6: Build + test** — `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -iE "error:|TEST SUCCEEDED|Test run with"`. Expected: `** TEST SUCCEEDED **`, 283 tests.

- [ ] **Step 7: Commit**
```bash
git add omwhisper-native/Transcription/TranscriptionEngine.swift omwhisper-native/AppState.swift
git commit -m "feat(whisper): wire WhisperEngine into AppState + EngineKind"
```

---

### Task 5: Settings — Whisper section (model + language + download)

**Files:**
- Modify: `omwhisper-native/UI/TranscriptionSettingsView.swift`

**Interfaces:**
- Consumes: `$state.engineKind`, `$state.whisperModel`, `$state.whisperLanguage`, `appState.whisperEngine` (Tasks 3–4); `WhisperKit.Constants.languages` (Task 1).

This mirrors the existing Parakeet section exactly. Add a WhisperKit import, a Whisper radio row to the engine picker, local download `@State`, and a `state.engineKind == .whisper` section.

- [ ] **Step 1: Import WhisperKit** — at the top of `TranscriptionSettingsView.swift`, below `import FluidAudio`:
```swift
import WhisperKit
```

- [ ] **Step 2: Add local download state** — next to the existing Parakeet `@State` (`downloadProgress`/`downloadError`/`isReady`), add Whisper equivalents:
```swift
    @State private var whisperDownloadProgress: Double?
    @State private var whisperDownloadError: String?
    @State private var whisperReady = false
```

- [ ] **Step 3: Add the Whisper radio row** — in the engine `Picker`, after the Cloud row:
```swift
                    Text("Whisper (local CoreML)").tag(EngineKind.whisper)
```

- [ ] **Step 4: Add the Whisper section** — after the `if state.engineKind == .parakeet { … }` block:
```swift
            if state.engineKind == .whisper {
                PorcelainSection(eyebrow: "Whisper Model") {
                    Picker("Model", selection: $state.whisperModel) {
                        ForEach(WhisperModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)

                    Text(state.whisperModel.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)

                    Picker("Language", selection: $state.whisperLanguage) {
                        Text("Auto-detect").tag("auto")
                        ForEach(whisperLanguageOptions, id: \.code) { opt in
                            Text(opt.name).tag(opt.code)
                        }
                    }
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)

                    if whisperReady {
                        Text("Ready.")
                            .foregroundStyle(Color.Porcelain.dim)
                    } else if let whisperDownloadProgress {
                        ProgressView(value: whisperDownloadProgress).tint(Color.Porcelain.emerald)
                        Text("Downloading… \(Int(whisperDownloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                    } else {
                        Button("Download \(state.whisperModel.displayName) Model", action: downloadWhisperModel)
                        if let whisperDownloadError {
                            Text(whisperDownloadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
```

- [ ] **Step 5: Add the language options + download function + onChange** — before the closing brace of the struct, add:
```swift
    /// WhisperKit's language list ([name: code]) sorted by display name.
    private var whisperLanguageOptions: [(name: String, code: String)] {
        Constants.languages
            .map { (name: $0.key.capitalized, code: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func downloadWhisperModel() {
        whisperDownloadError = nil
        whisperDownloadProgress = 0
        Task {
            do {
                try await appState.whisperEngine.ensureModelLoaded { progress in
                    Task { @MainActor in whisperDownloadProgress = progress.fractionCompleted }
                }
                await MainActor.run {
                    whisperDownloadProgress = nil
                    whisperReady = true
                }
            } catch {
                await MainActor.run {
                    whisperDownloadProgress = nil
                    whisperDownloadError = error.localizedDescription
                }
            }
        }
    }
```
In the existing `.task { … }` block, add:
```swift
            whisperReady = appState.whisperEngine.isReady
```
Add a new modifier next to the existing Parakeet `.onChange(of: appState.parakeetModel)`:
```swift
        .onChange(of: appState.whisperModel) {
            whisperReady = appState.whisperEngine.isReady
            whisperDownloadProgress = nil
            whisperDownloadError = nil
        }
```

- [ ] **Step 6: Build + test** — `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -iE "error:|TEST SUCCEEDED|Test run with"`. Expected: `** TEST SUCCEEDED **`, 283 tests.

- [ ] **Step 7: Commit**
```bash
git add omwhisper-native/UI/TranscriptionSettingsView.swift
git commit -m "feat(whisper): Settings section — model + language + download"
```

---

## Live Verification Owed (post-merge, on device)

Unit tests cover only the pure helpers (WhisperKit is app-only). The following need a real run — matching the "pure pieces tested, live round-trip separate" status of M4.1/M4.2/M3-2a/2b:

1. Select Whisper → pick Large v3 Turbo → **Download** shows real advancing progress → "Ready."
2. A dictation cycle (speak, release) pastes an accurate transcript; overlay shows the orb/LISTENING then the text on release (no partials).
3. **First-load tokenizer fetch** — the one WhisperKit-internal behavior not traceable from source: on a *fresh* download, `WhisperKit(WhisperKitConfig(modelFolder:))` must resolve the tokenizer. If load fails on a clean machine, fall back to the one-call `WhisperKit(WhisperKitConfig(model: variant, download: true))` form (loses the progress bar) or set `tokenizerFolder`.
4. Pin **Language = Telugu** (or Hindi) and dictate in that language → transcribed in-script (the coverage motivation).
5. Custom vocabulary word biases the result.
6. Switch model (turbo → small) → section shows Download again for the new one; downloading works; dictation uses it.
7. Switch back to Apple → unaffected (regression check).

## Self-Review Notes

- **Spec coverage:** engine (Task 3), model picker (Tasks 2/5), language picker + Auto (Tasks 2/4/5), transcribe-on-release single `.final` (Task 3), vocabulary→prompt (Tasks 2/3), per-model download UI (Task 5), EngineKind/AppState/default-Apple (Task 4), pure-only tests / WhisperKit app-only (Tasks 1/2), pbxproj prerequisite (Task 1). All covered.
- **Type consistency:** `WhisperModel`, `whisperKitModelID(for:)`, `decodeLanguage(_:)`, `vocabularyPrompt(_:)`, `ensureModelLoaded(progressHandler:)`, `setModel`/`setLanguage`, `isReady` used identically across tasks.
- **No auto-download in `transcribe`** (throws `modelNotDownloaded`) — consistent between Task 3's engine and the spec's error-handling.
