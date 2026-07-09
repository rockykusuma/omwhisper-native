# M4.1 — ParakeetEngine + Backend Selector UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second `TranscriptionEngine` backed by FluidAudio's local CoreML
Parakeet model (`SlidingWindowAsrManager`), selectable from a new Settings
tab alongside the existing (default, unchanged) Apple engine. Matches the
exact same streaming-partials + vocabulary-biasing contract `AppleEngine`
already satisfies.

**Architecture:** `ParakeetEngine` is a `final class` (not a stateless
struct like `AppleEngine`) holding one persistent, lazily-created
`FluidAudio.SlidingWindowAsrManager` — an `actor` — across the app's
lifetime, since loading its CoreML models is expensive and must not repeat
per dictation session. Vocabulary biasing needs a second, smaller model
(`FluidAudio.CtcModels`, the keyword-spotting model) loaded lazily and only
when the caller actually has custom vocabulary, so most users never pay
that extra download. `AppState` gains an `engineKind` setting and switches
between `appleEngine`/`parakeetEngine` via a computed `activeEngine`. A new
Settings tab exposes the picker plus a "Download Parakeet Model" flow with
real progress (FluidAudio's own downloader reports it).

**Tech Stack:** Swift 6, FluidAudio (new SPM dependency, app-target only),
SwiftUI.

## Global Constraints

- Apple stays the default engine (`engineKind` defaults to `.apple`) — this
  ships an opt-in alternative, not a default-experience change.
- `ParakeetEngine` holds exactly one persistent `SlidingWindowAsrManager`
  for its lifetime — models are loaded once, never reloaded per session.
  `reset()` (not model reload) is the per-session boundary.
- FluidAudio is an app-target-only dependency (mirrors Sparkle's existing
  app-target-only pattern) — not linked into `omwhisper-nativeTests`.
- `manager.transcriptionUpdates` is a **computed property** on
  `SlidingWindowAsrManager` that creates a new `AsyncStream` and overwrites
  the manager's stored continuation on every access — read it into a local
  `let` exactly once per `transcribe()` call, never access it a second time
  within the same session.
- Call order into `SlidingWindowAsrManager` matters and is not
  interchangeable: `loadModels()` → (optionally) `configureVocabularyBoosting()`
  → `reset()` → read `transcriptionUpdates` once → `startStreaming()` →
  `streamAudio()` per buffer → `finish()`. `startStreaming()` must run
  before any `streamAudio()` calls — it starts the manager's internal
  recognition task that actually consumes fed buffers.
- CTC vocabulary-boosting models (`FluidAudio.CtcModels`) are a **separate**
  download from the main ASR model — only triggered when `vocabulary` is
  non-empty, never bundled into the main "Download Parakeet Model" flow.
- No custom model downloader/SHA-pinning — FluidAudio's own
  `loadModels(progressHandler:)`/`CtcModels.downloadAndLoad()` handle
  download + caching entirely.
- `EngineKind.cloud` (existing enum case) stays defined but not selectable
  in the picker yet — labeled as a future addition, not removed/repurposed.
- No formal WER (word-error-rate) benchmark in this sub-project — explicitly
  deferred per brainstorming decision.

---

### Task 1: Add FluidAudio SPM dependency

**Files:**
- Modify: `omwhisper-native.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `import FluidAudio` becomes available to the app target (consumed by Task 2).

No tests — this is a build-configuration change, verified by a successful build.

This project has no `Package.swift` (plain Xcode project) — SPM package
references live directly in `project.pbxproj`, hand-edited exactly the way
GRDB and Sparkle were previously added (confirmed by reading those exact
entries). FluidAudio follows the same app-target-only pattern Sparkle uses
(GRDB is linked to both targets; Sparkle and now FluidAudio are app-only).

- [ ] **Step 1: Add the PBXBuildFile entry**

In `omwhisper-native.xcodeproj/project.pbxproj`, find the `PBXBuildFile`
section (starts with `/* Begin PBXBuildFile section */`, around line 9),
currently:

```
		96BBDF972FFD0F5200EE67CF /* GRDB in Frameworks */ = {isa = PBXBuildFile; productRef = 96BBDF962FFD0F5200EE67CF /* GRDB */; };
		96BBDF982FFD0F5200EE67CF /* GRDB in Frameworks */ = {isa = PBXBuildFile; productRef = 96BBDF962FFD0F5200EE67CF /* GRDB */; };
		96BBE06D2FFD24AC00EE67CF /* Sparkle in Frameworks */ = {isa = PBXBuildFile; productRef = 96BBE06C2FFD24AC00EE67CF /* Sparkle */; };
/* End PBXBuildFile section */
```

Add a line before `/* End PBXBuildFile section */`:

```
		96BBDF972FFD0F5200EE67CF /* GRDB in Frameworks */ = {isa = PBXBuildFile; productRef = 96BBDF962FFD0F5200EE67CF /* GRDB */; };
		96BBDF982FFD0F5200EE67CF /* GRDB in Frameworks */ = {isa = PBXBuildFile; productRef = 96BBDF962FFD0F5200EE67CF /* GRDB */; };
		96BBE06D2FFD24AC00EE67CF /* Sparkle in Frameworks */ = {isa = PBXBuildFile; productRef = 96BBE06C2FFD24AC00EE67CF /* Sparkle */; };
		9E89153962F1918FFB3B1B9D /* FluidAudio in Frameworks */ = {isa = PBXBuildFile; productRef = 4D2FD12C3C08929E1CE9D102 /* FluidAudio */; };
/* End PBXBuildFile section */
```

- [ ] **Step 2: Add it to the app target's Frameworks build phase**

Find (around line 44):

```
		9604F7882FFBE64C00E63B3E /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				96BBDF972FFD0F5200EE67CF /* GRDB in Frameworks */,
				96BBE06D2FFD24AC00EE67CF /* Sparkle in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

Replace with:

```
		9604F7882FFBE64C00E63B3E /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				96BBDF972FFD0F5200EE67CF /* GRDB in Frameworks */,
				96BBE06D2FFD24AC00EE67CF /* Sparkle in Frameworks */,
				9E89153962F1918FFB3B1B9D /* FluidAudio in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

(This is the `9604F7882FFBE64C00E63B3E` phase belonging to the
`omwhisper-native` app target — do NOT touch the other `Frameworks` phase,
`9604F7952FFBE64F00E63B3E`, which belongs to `omwhisper-nativeTests` and
must stay FluidAudio-free.)

- [ ] **Step 3: Add it to the app target's packageProductDependencies**

Find (around line 102, inside the `9604F78A2FFBE64C00E63B3E /* omwhisper-native */` PBXNativeTarget):

```
			packageProductDependencies = (
				96BBDF962FFD0F5200EE67CF /* GRDB */,
				96BBE06C2FFD24AC00EE67CF /* Sparkle */,
			);
```

Replace with:

```
			packageProductDependencies = (
				96BBDF962FFD0F5200EE67CF /* GRDB */,
				96BBE06C2FFD24AC00EE67CF /* Sparkle */,
				4D2FD12C3C08929E1CE9D102 /* FluidAudio */,
			);
```

(Do NOT touch the test target's `packageProductDependencies` at line ~127,
which lists only GRDB — FluidAudio stays app-only.)

- [ ] **Step 4: Add the package reference to the project object**

Find (around line 162, inside the `PBXProject` object):

```
			packageReferences = (
				96BBDF952FFD0F5200EE67CF /* XCRemoteSwiftPackageReference "GRDB.swift" */,
				96BBE06B2FFD24AC00EE67CF /* XCRemoteSwiftPackageReference "Sparkle" */,
			);
```

Replace with:

```
			packageReferences = (
				96BBDF952FFD0F5200EE67CF /* XCRemoteSwiftPackageReference "GRDB.swift" */,
				96BBE06B2FFD24AC00EE67CF /* XCRemoteSwiftPackageReference "Sparkle" */,
				5D67DD796084099608A7073B /* XCRemoteSwiftPackageReference "FluidAudio" */,
			);
```

- [ ] **Step 5: Add the XCRemoteSwiftPackageReference definition**

Find the `XCRemoteSwiftPackageReference` section (around line 520):

```
/* Begin XCRemoteSwiftPackageReference section */
		96BBDF952FFD0F5200EE67CF /* XCRemoteSwiftPackageReference "GRDB.swift" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/groue/GRDB.swift.git";
			requirement = {
				kind = upToNextMinorVersion;
				minimumVersion = 7.11.1;
			};
		};
		96BBE06B2FFD24AC00EE67CF /* XCRemoteSwiftPackageReference "Sparkle" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/sparkle-project/Sparkle";
			requirement = {
				kind = upToNextMinorVersion;
				minimumVersion = 2.9.4;
			};
		};
/* End XCRemoteSwiftPackageReference section */
```

Add a new entry before `/* End XCRemoteSwiftPackageReference section */`:

```
		5D67DD796084099608A7073B /* XCRemoteSwiftPackageReference "FluidAudio" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/FluidInference/FluidAudio.git";
			requirement = {
				kind = upToNextMinorVersion;
				minimumVersion = 0.4.0;
			};
		};
/* End XCRemoteSwiftPackageReference section */
```

- [ ] **Step 6: Add the XCSwiftPackageProductDependency definition**

Find the `XCSwiftPackageProductDependency` section (around line 539):

```
/* Begin XCSwiftPackageProductDependency section */
		96BBDF962FFD0F5200EE67CF /* GRDB */ = {
			isa = XCSwiftPackageProductDependency;
			package = 96BBDF952FFD0F5200EE67CF /* XCRemoteSwiftPackageReference "GRDB.swift" */;
			productName = GRDB;
		};
		96BBE06C2FFD24AC00EE67CF /* Sparkle */ = {
			isa = XCSwiftPackageProductDependency;
			package = 96BBE06B2FFD24AC00EE67CF /* XCRemoteSwiftPackageReference "Sparkle" */;
			productName = Sparkle;
		};
/* End XCSwiftPackageProductDependency section */
```

Add a new entry before `/* End XCSwiftPackageProductDependency section */`:

```
		4D2FD12C3C08929E1CE9D102 /* FluidAudio */ = {
			isa = XCSwiftPackageProductDependency;
			package = 5D67DD796084099608A7073B /* XCRemoteSwiftPackageReference "FluidAudio" */;
			productName = FluidAudio;
		};
/* End XCSwiftPackageProductDependency section */
```

- [ ] **Step 7: Resolve and build**

```bash
xcodebuild -resolvePackageDependencies -scheme omwhisper-native -project omwhisper-native.xcodeproj
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build
```

Expected: package resolution succeeds (downloads FluidAudio and its own
transitive dependencies), BUILD SUCCEEDED. **If either command fails** in a
way that isn't a straightforward fix (corrupt pbxproj, unresolvable
version, etc.) — stop and ask the user to add the package via Xcode's
"File → Add Package Dependencies…" GUI instead of continuing to hand-edit;
do not attempt increasingly speculative pbxproj surgery.

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native.xcodeproj/project.pbxproj
git commit -m "✨ feat(parakeet): add FluidAudio SPM dependency (app target only)"
```

---

### Task 2: ParakeetEngine

**Files:**
- Create: `omwhisper-native/Transcription/ParakeetEngine.swift`
- Test: `omwhisper-nativeTests/ParakeetEngineTests.swift`

**Interfaces:**
- Consumes: `TranscriptionEngine` protocol, `TranscriptEvent`, `EngineKind` (`Transcription/TranscriptionEngine.swift`, existing); `FluidAudio.SlidingWindowAsrManager`/`CustomVocabularyContext`/`CustomVocabularyTerm`/`CtcModels`/`ProgressHandler` (Task 1).
- Produces: `final class ParakeetEngine: TranscriptionEngine` with `nonisolated var isReady: Bool`, `func ensureModelsLoaded(progressHandler:) async throws`, `nonisolated func transcribe(_:vocabulary:) -> AsyncThrowingStream<TranscriptEvent, Error>` (consumed by Task 3's `AppState` wiring and Task 4's Settings UI).

- [ ] **Step 1: Write the failing test for the pure update-mapping function**

Create `omwhisper-nativeTests/ParakeetEngineTests.swift`:

```swift
import Testing
@testable import OmWhisper

@Suite("ParakeetEngine")
struct ParakeetEngineTests {
    @Test("a confirmed update maps to .final")
    func confirmedMapsToFinal() {
        #expect(ParakeetEngine.mapUpdate(isConfirmed: true, text: "hello world") == .final("hello world"))
    }

    @Test("a volatile (unconfirmed) update maps to .partial")
    func unconfirmedMapsToPartial() {
        #expect(ParakeetEngine.mapUpdate(isConfirmed: false, text: "hello wor") == .partial("hello wor"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test -only-testing:omwhisper-nativeTests/ParakeetEngineTests`
Expected: FAIL — `ParakeetEngine` doesn't exist yet.

- [ ] **Step 3: Implement ParakeetEngine.swift**

Create `omwhisper-native/Transcription/ParakeetEngine.swift`:

```swift
//
//  ParakeetEngine.swift
//  OmWhisper
//
//  Optional TranscriptionEngine backend: fully local Parakeet CoreML ASR via
//  FluidAudio's SlidingWindowAsrManager. Unlike AppleEngine (a stateless
//  struct recreated per session), this holds one persistent manager for the
//  engine's lifetime -- loading Parakeet's CoreML models is expensive
//  (multi-second) and must not happen on every dictation start. reset(),
//  not model reload, is the per-session boundary.
//
//  API shape confirmed directly against FluidAudio's source (not assumed):
//  SlidingWindowAsrManager is an `actor` (calls into it are inherently
//  serialized); manager.transcriptionUpdates is a *computed* property that
//  overwrites the manager's stored continuation on every access, so it's
//  read into a local exactly once per transcribe() call; startStreaming()
//  must run before any streamAudio() calls, since it's what starts the
//  manager's internal recognition task; vocabulary boosting needs a
//  separate CtcModels download, only triggered when vocabulary is
//  non-empty so most Parakeet users never pay that extra download.
//
//  Concurrency: this engine's own `manager`/`ctcModels` state is guarded
//  the same way AudioCapture guards its non-Sendable AVAudioEngine -- a
//  lock around mutable state, not actor isolation, since `transcribe` must
//  stay `nonisolated` per the TranscriptionEngine protocol.
//

@preconcurrency import AVFoundation
import FluidAudio
import os

final class ParakeetEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet

    enum EngineError: Error, LocalizedError {
        case modelsNotLoaded

        var errorDescription: String? {
            "Couldn't load the Parakeet model."
        }
    }

    private struct State {
        var manager: SlidingWindowAsrManager?
        var ctcModels: CtcModels?
    }

    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())

    /// True once the main ASR model is loaded. Safe to read from any
    /// thread -- used by Settings to show "Ready" vs. "Download" state.
    nonisolated var isReady: Bool {
        state.withLock { $0.manager != nil }
    }

    /// Downloads + loads the main ASR model. Called explicitly from
    /// Settings when the user selects Parakeet, and lazily from
    /// transcribe() if not already loaded. Safe to call concurrently --
    /// FluidAudio's own loadModels() is idempotent, so a race just means
    /// (rarely) two managers load in parallel and one is discarded, not a
    /// correctness issue.
    /// ponytail: no de-dup guard against a concurrent double-trigger; add
    /// one only if real users hit the wasted-download race in practice.
    func ensureModelsLoaded(progressHandler: FluidAudio.ProgressHandler? = nil) async throws {
        if state.withLock({ $0.manager }) != nil { return }
        let manager = SlidingWindowAsrManager()
        try await manager.loadModels(progressHandler: progressHandler)
        state.withLock { $0.manager = manager }
    }

    /// Downloads + loads the smaller CTC keyword-spotting model needed for
    /// vocabulary boosting. Separate from ensureModelsLoaded() and only
    /// triggered when the caller actually has custom vocabulary.
    /// ponytail: no progress UI for this smaller download; add if it
    /// proves slow enough in practice to need one.
    private func ensureCtcModelsLoaded() async throws -> CtcModels {
        if let existing = state.withLock({ $0.ctcModels }) { return existing }
        let models = try await CtcModels.downloadAndLoad()
        state.withLock { $0.ctcModels = models }
        return models
    }

    /// Pure: FluidAudio's isConfirmed flag maps directly onto this app's
    /// .final/.partial contract. Takes primitives, not the FluidAudio
    /// SlidingWindowTranscriptionUpdate struct directly, so this stays
    /// testable without linking FluidAudio into the test target (it's
    /// app-target-only -- see Global Constraints).
    static func mapUpdate(isConfirmed: Bool, text: String) -> TranscriptEvent {
        isConfirmed ? .final(text) : .partial(text)
    }

    // nonisolated: this does real ASR work and must not run pinned to
    // MainActor, matching AppleEngine's own isolation.
    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()

        let task = Task {
            do {
                try await ensureModelsLoaded()
                guard let manager = state.withLock({ $0.manager }) else {
                    throw EngineError.modelsNotLoaded
                }

                if !vocabulary.isEmpty {
                    let ctcModels = try await ensureCtcModelsLoaded()
                    let terms = vocabulary.map { CustomVocabularyTerm(text: $0) }
                    try await manager.configureVocabularyBoosting(
                        vocabulary: CustomVocabularyContext(terms: terms),
                        ctcModels: ctcModels
                    )
                }
                try await manager.reset()

                let updates = await manager.transcriptionUpdates
                let updatesTask = Task {
                    for await update in updates {
                        continuation.yield(Self.mapUpdate(isConfirmed: update.isConfirmed, text: update.text))
                    }
                }

                try await manager.startStreaming()

                for await buffer in audio {
                    await manager.streamAudio(buffer)
                }

                let finalText = try await manager.finish()
                updatesTask.cancel()
                if !finalText.isEmpty {
                    continuation.yield(.final(finalText))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }

        return stream
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test -only-testing:omwhisper-nativeTests/ParakeetEngineTests`
Expected: PASS — both `ParakeetEngineTests` tests green.

- [ ] **Step 5: Run the full suite to verify no regressions**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: BUILD SUCCEEDED, all existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Transcription/ParakeetEngine.swift omwhisper-nativeTests/ParakeetEngineTests.swift
git commit -m "✨ feat(parakeet): add ParakeetEngine (FluidAudio CoreML backend)"
```

---

### Task 3: AppState wiring

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `ParakeetEngine` (Task 2); existing `AppleEngine`, `EngineKind`.
- Produces: `AppState.engineKind: EngineKind` (default `.apple`); `AppState.parakeetEngine: ParakeetEngine` (not private — Task 4's Settings UI reads `isReady`/calls `ensureModelsLoaded`); `AppState.activeEngine` used at the one existing `engine.transcribe(...)` call site.

No unit tests — `AppState` wiring tasks in this project never get dedicated
tests (matches every prior `AppState` wiring task this session — S1 Task 5,
S4 Task 6, S5.1 Task 4). Verified via the full suite staying green plus
live verification in Task 5.

- [ ] **Step 1: Rename the existing engine property and add parakeetEngine**

In `omwhisper-native/AppState.swift`, the existing line (around line 349):

```swift
    private let engine: TranscriptionEngine = AppleEngine()
```

Replace with:

```swift
    private let appleEngine: TranscriptionEngine = AppleEngine()
    let parakeetEngine = ParakeetEngine()
    private var activeEngine: TranscriptionEngine {
        switch engineKind {
        case .apple: appleEngine
        case .parakeet: parakeetEngine
        case .cloud: appleEngine  // M4.2 not shipped yet; falls back silently
        }
    }
```

- [ ] **Step 2: Update the call site**

In `omwhisper-native/AppState.swift`, the existing line (around line 651):

```swift
            let events = engine.transcribe(audioStream, vocabulary: engineVocabulary)
```

Replace with:

```swift
            let events = activeEngine.transcribe(audioStream, vocabulary: engineVocabulary)
```

- [ ] **Step 3: Add the engineKind setting**

In `omwhisper-native/AppState.swift`, add this computed property right
after `mcpAccessEnabled` (added in S5.2 — search for `var mcpAccessEnabled: Bool`
and add the new property immediately after its closing brace):

```swift

    var engineKind: EngineKind {
        get {
            access(keyPath: \.engineKind)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.engineKind),
                  let kind = EngineKind(rawValue: raw) else { return .apple }
            return kind
        }
        set {
            withMutation(keyPath: \.engineKind) {
                UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKeys.engineKind)
            }
        }
    }
```

- [ ] **Step 4: Add the SettingsKeys entry**

In `omwhisper-native/AppState.swift`, the `SettingsKeys` enum currently ends with:

```swift
    static let mcpAccessEnabled = "mcpAccessEnabled"
}
```

Add a line before the closing brace:

```swift
    static let mcpAccessEnabled = "mcpAccessEnabled"
    static let engineKind = "engineKind"
}
```

- [ ] **Step 5: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: BUILD SUCCEEDED, all tests pass (no regressions — this task adds
no new tests of its own).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(parakeet): wire engineKind + activeEngine into AppState"
```

---

### Task 4: TranscriptionSettingsView + tab wiring

**Files:**
- Create: `omwhisper-native/UI/TranscriptionSettingsView.swift`
- Modify: `omwhisper-native/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `AppState.engineKind`, `AppState.parakeetEngine` (Task 3); `FluidAudio.ProgressHandler`/`DownloadProgress` (Task 1).
- Produces: `struct TranscriptionSettingsView: View`, a new Settings tab (consumed by Task 5's live verification; no further tasks depend on these).

No unit tests — SwiftUI view, same reasoning as every other Settings tab in
this project. Verified live in Task 5.

- [ ] **Step 1: Create TranscriptionSettingsView.swift**

Create `omwhisper-native/UI/TranscriptionSettingsView.swift`:

```swift
//
//  TranscriptionSettingsView.swift
//  OmWhisper
//
//  Engine picker (Apple / Parakeet -- Cloud arrives in M4.2) + Parakeet's
//  model download flow. Apple stays the default; downloadProgress/
//  downloadError are local @State (not AppState-observed) because
//  ParakeetEngine is a plain class, same pattern HistoryView/MemoryView
//  already use for their own non-Observable stores.
//

import SwiftUI
import FluidAudio

struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var downloadProgress: Double?
    @State private var downloadError: String?
    @State private var isReady = false

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Engine") {
                Picker("Transcription engine", selection: $state.engineKind) {
                    Text("Apple (on-device, default)").tag(EngineKind.apple)
                    Text("Parakeet (local CoreML)").tag(EngineKind.parakeet)
                }
                .pickerStyle(.radioGroup)
                Text("Cloud streaming — coming in a future update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.engineKind == .parakeet {
                Section("Parakeet Model") {
                    if isReady {
                        Text("Ready.")
                            .foregroundStyle(.secondary)
                    } else if let downloadProgress {
                        ProgressView(value: downloadProgress)
                        Text("Downloading… \(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Download Parakeet Model", action: downloadModel)
                        if let downloadError {
                            Text(downloadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { isReady = appState.parakeetEngine.isReady }
    }

    private func downloadModel() {
        downloadError = nil
        downloadProgress = 0
        Task {
            do {
                try await appState.parakeetEngine.ensureModelsLoaded { progress in
                    Task { @MainActor in
                        downloadProgress = progress.fractionCompleted
                    }
                }
                await MainActor.run {
                    downloadProgress = nil
                    isReady = true
                }
            } catch {
                await MainActor.run {
                    downloadProgress = nil
                    downloadError = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    TranscriptionSettingsView().environment(AppState())
}
```

- [ ] **Step 2: Add the Transcription tab to SettingsView**

In `omwhisper-native/UI/SettingsView.swift`, the `TabView` currently reads:

```swift
            Tab("AI", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("Meetings", systemImage: "person.2.wave.2") {
                MeetingsSettingsView()
            }
```

Replace with:

```swift
            Tab("AI", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("Transcription", systemImage: "waveform.badge.mic") {
                TranscriptionSettingsView()
            }
            Tab("Meetings", systemImage: "person.2.wave.2") {
                MeetingsSettingsView()
            }
```

- [ ] **Step 3: Widen the Settings window for the 10th tab**

In `omwhisper-native/UI/SettingsView.swift`, the existing line:

```swift
        .frame(width: 660, height: 440)
```

Replace with:

```swift
        // 10 tabs now (added Transcription) -- S5.2 already had to widen
        // this once for a 9th tab overflowing into a ">>" menu; bump ahead
        // of that recurring per-tab pattern instead of waiting to hit it again.
        .frame(width: 720, height: 440)
```

- [ ] **Step 4: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: BUILD SUCCEEDED, all tests pass (no regressions).

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/TranscriptionSettingsView.swift omwhisper-native/UI/SettingsView.swift
git commit -m "✨ feat(parakeet): add Transcription Settings tab (engine picker + model download)"
```

---

### Task 5: Live verification + docs

**Files:**
- Modify: `CLAUDE.md`

No new code in this task — build the app, run it, and confirm the feature
works end-to-end on real hardware, then record what was found.

- [ ] **Step 1: Build and launch the app**

```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build
```

Find the freshest built `.app`:

```bash
find ~/Library/Developer/Xcode/DerivedData -iname "OmWhisper.app" -exec stat -f "%m %N" {} \; | sort -rn | head -1
```

Launch it.

- [ ] **Step 2: Verify Apple stays the default and is unaffected**

Without touching Settings, run a normal dictation cycle. Confirm it behaves
exactly as before this sub-project (still uses Apple's engine, no
regression) — this is the most important regression check, since
`activeEngine`'s default must resolve to `.apple` for every existing user.

- [ ] **Step 3: Verify the Parakeet download flow**

Open Settings → Transcription, select "Parakeet (local CoreML)". Confirm
the "Download Parakeet Model" button appears, click it, confirm a real
progress bar advances (not stuck at 0% or jumping straight to 100%),
confirm it settles on "Ready." when done.

- [ ] **Step 4: Verify a real Parakeet dictation session**

With Parakeet selected and ready, run a real dictation session (PTT or
toggle). Confirm live partials appear in the overlay (not just a single
final blob after the fact — this is the core thing this whole design
verified is possible with `SlidingWindowAsrManager`), and the final pasted
text is correct.

- [ ] **Step 5: Verify vocabulary biasing**

Add a custom vocabulary word unlikely to be recognized correctly by
default (an uncommon name or invented product name) via the Vocabulary
Settings tab. With Parakeet active, dictate a sentence containing that
word. Confirm the first use triggers the one-time CTC model download
(expect a brief pause), and the word is transcribed correctly.

- [ ] **Step 6: Verify switching back to Apple**

Switch `engineKind` back to Apple in Settings. Run another dictation
session. Confirm it works cleanly with no leftover state from the Parakeet
session (no crash, no wrong-engine text, no stuck overlay state).

- [ ] **Step 7: Update CLAUDE.md**

Add a new Progress Tracker row (or extend the M4 milestone description if
one doesn't exist yet) documenting: M4.1 shipped, the FluidAudio research
findings (`SlidingWindowAsrManager` chosen over the `StreamingAsrManager`-
conforming EOU/Nemotron managers specifically because only it has both
live partials AND vocabulary boosting), the persistent-actor-instance
architecture and why, the separate CTC-model-for-vocabulary lazy-download
design, and the results of Steps 2-6's live verification. Follow the same
level of detail as the S5.1/S5.2 rows already in that table. Update the M4
milestone status line to reflect "M4.1 shipped, M4.2 (CloudEngine) not
started."

- [ ] **Step 8: Commit the docs update**

```bash
git add CLAUDE.md
git commit -m "📝 docs: mark M4.1 (ParakeetEngine + backend selector) shipped"
```
