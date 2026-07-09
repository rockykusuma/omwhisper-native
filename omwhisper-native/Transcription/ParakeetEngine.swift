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

nonisolated final class ParakeetEngine: TranscriptionEngine {
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
    func ensureModelsLoaded(progressHandler: ProgressHandler? = nil) async throws {
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
