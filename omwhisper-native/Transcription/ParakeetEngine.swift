//
//  ParakeetEngine.swift
//  OmWhisper
//
//  Optional TranscriptionEngine backend: fully local Parakeet CoreML ASR via
//  FluidAudio's SlidingWindowAsrManager.
//
//  IMPORTANT — SlidingWindowAsrManager is SINGLE-USE. Its audio input AsyncStream
//  is created once in the manager's init() and permanently closed by finish()
//  (`inputBuilder.finish()`); no API recreates it, and reset() only clears
//  decoder/window state, not the stream. So a manager must be discarded after one
//  dictation, NOT reused across sessions — an earlier persistent-manager design
//  worked for the FIRST dictation only, then fed every later one a dead input
//  stream (recognition loop exits immediately → empty transcript → "NOTHING
//  HEARD"). Instead we cache the *expensive* part — the loaded CoreML models
//  (`AsrModels`, a Sendable value) — once, and create a fresh, cheap manager per
//  transcribe() from those cached models (FluidAudio's documented reuse pattern:
//  pre-load AsrModels, then `SlidingWindowAsrManager.loadModels(_:)`).
//
//  Vocabulary boosting needs a separate CtcModels download, only triggered when
//  the caller actually has custom vocabulary, so most Parakeet users never pay it.
//
//  Concurrency: mutable cached-model state is guarded the same way AudioCapture
//  guards its non-Sendable AVAudioEngine — a lock, not actor isolation, since
//  transcribe() must stay `nonisolated` per the TranscriptionEngine protocol.
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
        var models: AsrModels?        // loaded once, reused across fresh managers
        var ctcModels: CtcModels?     // vocabulary-boosting model, loaded lazily
    }

    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())

    /// True once the main ASR models are loaded. Safe to read from any thread —
    /// used by Settings to show "Ready" vs. "Download" state.
    nonisolated var isReady: Bool {
        state.withLock { $0.models != nil }
    }

    /// Downloads + loads the main ASR models once (expensive — multi-second CoreML
    /// load). Called explicitly from Settings when the user selects Parakeet, and
    /// lazily from transcribe() if not already loaded. Idempotent; a rare
    /// concurrent double-trigger just loads twice and discards one, not a
    /// correctness issue.
    func ensureModelsLoaded(progressHandler: ProgressHandler? = nil) async throws {
        if state.withLock({ $0.models }) != nil { return }
        let models = try await AsrModels.downloadAndLoad(progressHandler: progressHandler)
        state.withLock { $0.models = models }
    }

    /// Downloads + loads the smaller CTC keyword-spotting model needed for
    /// vocabulary boosting. Separate from ensureModelsLoaded() and only triggered
    /// when the caller actually has custom vocabulary.
    private func ensureCtcModelsLoaded() async throws -> CtcModels {
        if let existing = state.withLock({ $0.ctcModels }) { return existing }
        let models = try await CtcModels.downloadAndLoad()
        state.withLock { $0.ctcModels = models }
        return models
    }

    /// Pure: FluidAudio's isConfirmed flag maps directly onto this app's
    /// .final/.partial contract. Takes primitives, not the FluidAudio
    /// SlidingWindowTranscriptionUpdate struct, so this stays testable without
    /// linking FluidAudio into the test target (it's app-target-only).
    static func mapUpdate(isConfirmed: Bool, text: String) -> TranscriptEvent {
        isConfirmed ? .final(text) : .partial(text)
    }

    // nonisolated: this does real ASR work and must not run pinned to MainActor,
    // matching AppleEngine's own isolation.
    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()

        let task = Task {
            do {
                try await ensureModelsLoaded()
                guard let models = state.withLock({ $0.models }) else {
                    throw EngineError.modelsNotLoaded
                }

                // Fresh, single-use manager per dictation (see the file header on
                // why the manager must NOT be reused). Cheap: the models are
                // already loaded, so this doesn't re-download or recompile.
                let manager = SlidingWindowAsrManager()
                try await manager.loadModels(models)

                if !vocabulary.isEmpty {
                    let ctcModels = try await ensureCtcModelsLoaded()
                    let terms = vocabulary.map { CustomVocabularyTerm(text: $0) }
                    try await manager.configureVocabularyBoosting(
                        vocabulary: CustomVocabularyContext(terms: terms),
                        ctcModels: ctcModels
                    )
                }

                try await manager.startStreaming()

                // Read transcriptionUpdates AFTER startStreaming (FluidAudio's own
                // canonical order); no audio has been fed yet, so no update is missed.
                let updates = await manager.transcriptionUpdates
                let updatesTask = Task {
                    for await update in updates {
                        continuation.yield(Self.mapUpdate(isConfirmed: update.isConfirmed, text: update.text))
                    }
                }

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
