# Design: M4.1 — ParakeetEngine + Backend Selector UI

> Written 2026-07-09. Brainstormed via `superpowers:brainstorming`. First of
> two sub-projects implementing M4 ("Backend flexibility — the USP") from
> `docs/NATIVE_MIGRATION_PLAN.md`, next in the project's priority order after
> S5 shipped. M4 was split during brainstorming into M4.1 (this — the local
> CoreML alternative engine, no new privacy surface) and M4.2 (CloudEngine —
> provider choice, redaction on egress, Keychain key storage), matching this
> project's established pattern for multi-subsystem milestones (M3, S3, S5
> were all split the same way). M4.1 also directly addresses the migration
> plan's flagged risk #1: SpeechTranscriber accuracy is "the big unknown,"
> with ParakeetEngine as the documented promotion candidate if it isn't good
> enough. A formal WER (word-error-rate) comparison between the two engines
> was considered and explicitly deferred — ship the engine and picker now,
> do a rigorous accuracy comparison later if it becomes a real question.

## Goal

A second `TranscriptionEngine` implementation backed by FluidAudio's
CoreML Parakeet model, fully local (no network), selectable from a new
Settings tab alongside the existing (default, unchanged) Apple engine.
Must satisfy the exact same contract `AppleEngine` does today: streaming
`.partial`/`.final` events and vocabulary biasing from custom vocabulary —
confirmed both are real, supported FluidAudio capabilities, not assumed.

## Reference: FluidAudio (verified directly against its source, not assumed)

Investigated by cloning `github.com/FluidInference/FluidAudio` and reading
source directly (not from training-data memory) before committing to this
design, because the two most important facts here are not obvious from the
package's public docs alone:

- **`Sources/FluidAudio/ASR/Parakeet/Streaming/StreamingAsrManager.swift`** —
  a `StreamingAsrManager` protocol exists (`EOU`/`Nemotron` model variants
  conform to it) with genuine incremental streaming via
  `setPartialTranscriptCallback(_:)` — but grepping that whole `Streaming/`
  directory for vocabulary/keyword/bias support returns nothing. This is
  the "true streaming" engine family, and it has **no vocabulary biasing**.
- **`Sources/FluidAudio/ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift`** —
  documented in its own header as *not* conforming to `StreamingAsrManager`
  ("uses an offline encoder with overlapping windows, not a cache-aware
  streaming architecture"), which reads at first glance like a batch-only
  engine unsuitable for live partials. Reading its actual public API proves
  otherwise: `streamAudio(_ buffer: AVAudioPCMBuffer)` accepts audio
  incrementally, and `var transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate>`
  emits results as they become available — genuinely usable for live
  partials despite the "not streaming" framing in its doc comment. It also
  has `configureVocabularyBoosting(vocabulary: CustomVocabularyContext, ctcModels:, config:)`.
  **This is the manager this design uses** — it's the only one with both
  capabilities this app needs.
- **`SlidingWindowTranscriptionUpdate`** (same file, struct): `text: String`,
  `isConfirmed: Bool` ("whether this text is confirmed (high confidence) or
  volatile (may change)"), `confidence: Float`, `tokenTimings: [TokenTiming]`.
  `isConfirmed` maps directly onto this app's `TranscriptEvent.final`/`.partial`.
- **`AudioSource` enum** (`Sources/FluidAudio/Shared/AudioSource.swift`):
  only `.microphone`/`.system` — a labeling/metadata parameter to
  `startStreaming(source:)`, not FluidAudio owning capture itself.
  `streamAudio(_:)` is how audio actually gets in, confirming this app's
  own `AudioCapture` stays in charge of the mic exactly as it is today —
  ParakeetEngine is a pure consumer of buffers, same shape as `AppleEngine`.
- **`loadModels(to:progressHandler:)`**: downloads from Hugging Face and
  loads into memory, "idempotent after first successful load," with a real
  `progressHandler: ProgressHandler?` parameter (backed by
  `Sources/FluidAudio/Shared/Download/`, `ProgressEmitter.swift`) — no
  custom SHA-pinned downloader needed, unlike the old Tauri app's
  hand-rolled Parakeet downloader (`src-tauri/src/parakeet/models.rs`),
  which is reference-only here per this project's convention (that app's
  Parakeet was ONNX Runtime CPU inference, architecturally unrelated to
  FluidAudio's CoreML implementation).
- **`CustomVocabularyContext(terms: [CustomVocabularyTerm], ...)`** /
  **`CustomVocabularyTerm(text: String, weight: Float? = nil, ...)`** — a
  direct `vocabulary.map { CustomVocabularyTerm(text: $0) }` covers this
  app's `[String]` vocabulary parameter; the additional weight/alias/
  similarity-override parameters are optional and not needed for parity
  with what `AppleEngine`'s `contextualStrings` already does.

## Architecture

### FluidAudio dependency

New `XCRemoteSwiftPackageReference` in `project.pbxproj` (same mechanism
already used for GRDB/Sparkle): `https://github.com/FluidInference/FluidAudio.git`,
`from: "0.4.0"`, linked to the app target only (not the test target — model
loading/CoreML inference is not something unit tests exercise directly, same
reasoning `Sparkle` is app-target-only).

### ParakeetEngine — persistent instance, not a stateless struct

`AppleEngine` is a `struct` recreated fresh on every use because
SpeechAnalyzer/SpeechTranscriber have low per-session setup cost.
`ParakeetEngine` is different: loading its CoreML models is expensive
(multi-second, ANE-optimized encoder/decoder) and must **not** happen on
every dictation start — that would blow past "PTT starts instantly" in
practice even though sign-off criterion #5 is worded around the Apple
engine specifically. So `ParakeetEngine` is a `final class: TranscriptionEngine`
that lazily creates and holds **one** `FluidAudio.SlidingWindowAsrManager`
instance for the engine's lifetime:

```swift
final class ParakeetEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet

    private var manager: SlidingWindowAsrManager?

    /// Called from Settings when the user selects Parakeet, and lazily on
    /// first transcribe() if not already loaded -- either path is safe
    /// since FluidAudio's loadModels() is itself idempotent.
    func ensureModelsLoaded(progressHandler: FluidAudio.ProgressHandler? = nil) async throws {
        let m = manager ?? SlidingWindowAsrManager()
        try await m.loadModels(progressHandler: progressHandler)
        manager = m
    }

    nonisolated func transcribe(_ audio: sending AsyncStream<AVAudioPCMBuffer>, vocabulary: [String]) -> AsyncThrowingStream<TranscriptEvent, Error> {
        // 1. ensureModelsLoaded() if not already (covers "Apple->Parakeet
        //    switch, never opened Settings first" -- still correct, just
        //    slower on that one first call)
        // 2. configureVocabularyBoosting(vocabulary: CustomVocabularyContext(
        //      terms: vocabulary.map { CustomVocabularyTerm(text: $0) }))
        // 3. manager.reset() -- clears prior session's decode state, keeps
        //    models loaded (this is the whole reason for the persistent
        //    instance: reset is fast, loadModels is not)
        // 4. Task: for await buffer in audio { await manager.streamAudio(buffer) }
        //    (streamAudio itself is non-async, non-throwing -- it just
        //    enqueues into FluidAudio's internal buffer -- but SlidingWindowAsrManager
        //    is confirmed an `actor`, so the `await` is required at the call
        //    site to cross the actor boundary even though the method has no
        //    internal suspension point)
        // 5. Concurrently: for await update in manager.transcriptionUpdates
        //    { yield .final(update.text) if update.isConfirmed else .partial(update.text) }
        // 6. On audio stream end: try await manager.finish(), yield final,
        //    continuation.finish()
    }
}
```

(Full implementation detail — exact `AsyncThrowingStream` construction
mirroring `AppleEngine`'s `sending`-transfer pattern and concurrent
consumption of two async sequences — is a plan-writing concern, not a
design-spec concern; the shape above is the contract. Concurrent
`loadModels()`/`streamAudio()` calls *into* `SlidingWindowAsrManager` need no
manual locking: it's confirmed (`public actor SlidingWindowAsrManager`, read
directly from source) to be an actor, so Swift's actor isolation serializes
access automatically. Separately, `ParakeetEngine`'s own `manager` stored
property needs to be safely mutable from a `nonisolated func transcribe`
(required by the `TranscriptionEngine` protocol) while `ParakeetEngine`
itself conforms to `Sendable` — whether that means making `ParakeetEngine`
itself an actor, using a lock (`OSAllocatedUnfairLock`, this project's
established pattern for exactly this kind of nonisolated-mutable-state case
— see `AudioCapture`), or another approach is a real Swift 6 isolation
question left for plan-writing time, not resolved here — matching how
`AppleEngine`'s own isolation tricks (documented in this project's
Concurrency section) were worked out during implementation, not upfront.)

### AppState wiring

```swift
private let appleEngine = AppleEngine()          // renamed from `engine`
private let parakeetEngine = ParakeetEngine()     // new, persistent
private var activeEngine: TranscriptionEngine {
    switch engineKind {
    case .apple: appleEngine
    case .parakeet: parakeetEngine
    case .cloud: appleEngine  // M4.2 not shipped yet; falls back silently
    }
}
```

`AppState.engineKind: EngineKind` — new setting, same
`access(keyPath:)`/`withMutation(keyPath:)` pattern as `polishBackend`,
default `.apple` (no default change to the shipped experience). Every call
site that currently reads `engine` (`AppState.swift`, the two
`engine.transcribe(...)` call sites) switches to `activeEngine`.

### Model download UI

New `UI/TranscriptionSettingsView.swift` Settings tab (between AI and
Meetings, matching this app's existing tab-ordering-by-shipped-date
convention): a picker (Apple / Parakeet selectable; Cloud row present but
disabled, labeled "Coming in M4.2" — same "documented, not yet wired"
pattern `PolishBackendKind`'s comment already uses). Selecting Parakeet
when its models aren't loaded shows a "Download Parakeet Model" button +
progress bar wired to `ParakeetEngine.ensureModelsLoaded(progressHandler:)`;
once loaded, the row just shows "Ready." This satisfies the parity
checklist's explicitly-kept exception: "model manager UI (except an
optional Parakeet download)."

## Global Constraints

- Apple stays the default engine (`engineKind` defaults to `.apple`) — this
  ships an opt-in alternative, not a default-experience change. Promoting
  Parakeet to default is a future decision gated on real accuracy data, not
  part of this sub-project.
- `ParakeetEngine` must hold exactly one persistent `SlidingWindowAsrManager`
  for its lifetime — never recreate/reload models per dictation session.
  `reset()` (not model reload) is the per-session boundary.
- FluidAudio is an app-target-only dependency — not linked into
  `omwhisper-nativeTests`.
- No custom model downloader/verification — FluidAudio's own
  `loadModels(progressHandler:)` handles Hugging Face download + caching;
  do not reimplement the old Tauri app's SHA-pinning scheme, it solved a
  problem (ONNX Runtime had no built-in downloader) that doesn't exist here.
- `EngineKind.cloud` is already defined (existing enum, tagged "(M4)" in a
  comment) — this sub-project must not remove or repurpose it; the picker
  simply doesn't offer it as selectable yet.
- No formal WER comparison in this sub-project (explicitly deferred per
  brainstorming decision) — do not add benchmark tooling/test audio corpus
  as part of this scope.

## Error Handling & Permissions

- Model download/load failure (network error, disk space, corrupt cache):
  surfaced in the Settings download UI as an inline error, matching
  `errorMessage`'s existing "toast, not crash" convention elsewhere in this
  app; the picker stays on Apple until a load succeeds — a user is never
  left with "Parakeet selected but broken."
- If `engineKind == .parakeet` but models were never loaded (user picked
  Parakeet, closed Settings before downloading finished, then starts
  dictation) — `transcribe()` calls `ensureModelsLoaded()` itself as a
  fallback, so dictation still works, just slower on that one call. No
  silent fallback to Apple mid-session (would require re-capturing audio
  from scratch — out of scope, matches this app's existing "engine error →
  toast, not crash" rather than "auto-retry on a different engine").
- CoreML/ANE unavailable (e.g., running under conditions FluidAudio itself
  rejects) — propagates as a thrown error from `loadModels`, surfaced the
  same way as a download failure.

## Testing

Pure-logic pieces (Swift Testing): `SlidingWindowTranscriptionUpdate` →
`TranscriptEvent` mapping (`isConfirmed` → `.final`/`.partial`) as an
extracted, directly-testable pure function — same "extract the pure
decision from the effectful wrapper" pattern used throughout this project
(`MemoryStore.upsertDecision`, `Chronicler.chunk`). `activeEngine`'s
switch-on-`engineKind` logic is trivial enough to not need its own test
(matches this project's YAGNI-for-tests stance on one-line dispatch). Real
CoreML model loading, actual transcription accuracy, and download-progress
UI are **not unit-testable** in this project (no network/model-download
mocking infrastructure, and this project has never built one for engine
tests — `AppleEngine` itself has no dedicated test file either, same
reasoning) — verified live instead: download completes with visible
progress, a real dictation session with Parakeet selected produces
correct text with live partials, switching back to Apple mid-session (i.e.
between sessions) works cleanly, and vocabulary biasing measurably affects
output for a known custom-vocabulary term.

**Exit criteria**: Parakeet appears as a selectable engine in Settings;
first selection triggers a visible model download with progress; a real
dictation session with Parakeet active produces live partials and a final
transcript pasted the same way Apple's engine does today; a custom
vocabulary term is respected by Parakeet's output; switching back to Apple
works with no leftover state issues.
