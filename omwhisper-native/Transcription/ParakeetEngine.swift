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
//  (`AsrModels`, a Sendable value) — once per selected variant, and create a
//  fresh, cheap manager per transcribe() from those cached models (FluidAudio's
//  documented reuse pattern: pre-load AsrModels, then
//  `SlidingWindowAsrManager.loadModels(_:)`). Switching variant (setModel) drops
//  the cache on next load so the new one is fetched.
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

/// User-selectable Parakeet variant. Pure (no FluidAudio types) so it can back a
/// UserDefaults setting and be unit-tested without linking FluidAudio into the
/// test target. Mapped to FluidAudio's AsrModelVersion inside ParakeetEngine.
nonisolated enum ParakeetModel: String, CaseIterable, Identifiable, Sendable {
    case v3   // multilingual 0.6B (default)
    case v2   // English-only 0.6B

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v3: "Multilingual (v3)"
        case .v2: "English (v2)"
        }
    }

    var subtitle: String {
        switch self {
        case .v3: "0.6B · many languages · default"
        case .v2: "0.6B · English only"
        }
    }
}

nonisolated final class ParakeetEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet

    enum EngineError: Error, LocalizedError {
        case modelsNotLoaded

        var errorDescription: String? {
            "Couldn't load the Parakeet model."
        }
    }

    private struct State {
        var models: AsrModels?           // loaded once per variant, reused across fresh managers
        var loadedModel: ParakeetModel?  // which variant `models` holds (nil = none loaded)
        var ctcModels: CtcModels?        // vocabulary-boosting model, loaded lazily
        var requestedModel: ParakeetModel = .v3  // the user's selected variant
    }

    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())

    private static func fluidVersion(for model: ParakeetModel) -> AsrModelVersion {
        switch model {
        case .v3: .v3
        case .v2: .v2
        }
    }

    /// Set the desired variant (from Settings). If it differs from what's loaded,
    /// the next ensureModelsLoaded()/transcribe() reloads.
    func setModel(_ model: ParakeetModel) {
        state.withLock { $0.requestedModel = model }
    }

    /// Whether the variant's model files exist ON DISK — the truthful "downloaded?"
    /// check used by Settings. Keying off disk (not the single in-memory cache) is
    /// what makes "Ready" survive switching variants and app relaunches: transcribe()
    /// lazily (re)loads a downloaded model from FluidAudio's cache on first use.
    nonisolated static func isDownloaded(_ model: ParakeetModel) -> Bool {
        let version = fluidVersion(for: model)
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version))
    }

    /// True once the *requested* variant is downloaded on disk. Used by Settings to
    /// show "Ready" vs. "Download".
    nonisolated var isReady: Bool {
        Self.isDownloaded(state.withLock { $0.requestedModel })
    }

    /// Downloads + loads the main ASR models once (expensive — multi-second CoreML
    /// load). Called explicitly from Settings when the user selects Parakeet, and
    /// lazily from transcribe() if not already loaded. Idempotent; a rare
    /// concurrent double-trigger just loads twice and discards one, not a
    /// correctness issue.
    func ensureModelsLoaded(progressHandler: ProgressHandler? = nil) async throws {
        let requested = state.withLock { $0.requestedModel }
        if state.withLock({ $0.models != nil && $0.loadedModel == requested }) { return }
        let models = try await AsrModels.downloadAndLoad(
            version: Self.fluidVersion(for: requested),
            progressHandler: progressHandler
        )
        state.withLock { $0.models = models; $0.loadedModel = requested }
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
