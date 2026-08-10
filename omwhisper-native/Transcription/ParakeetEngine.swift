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
//  Vocabulary boosting is NOT used (removed 2026-08-10 on measurement — see the
//  long note in transcribe()). Custom vocabulary reaches Parakeet users through
//  AppState's post-processing instead, which is the path that measurably works.
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

    // Vocabulary boosting is deliberately NOT configured here — see the note in
    // transcribe(). The CtcModels loader that used to live at this spot was
    // removed with it, so no user pays that second download any more.

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

                // VOCABULARY BOOSTING IS NOT CONFIGURED, DELIBERATELY.
                //
                // `vocabulary` is accepted (the TranscriptionEngine contract
                // passes it to every engine) and ignored here. Removed
                // 2026-08-10 after measuring it, and the measurement is the
                // whole argument -- do not re-enable without repeating it.
                //
                // It bought NOTHING: across two corpora every sample was
                // byte-identical with and without boosting, on both v3 and v2
                // (v2 pooled 8.3% either way). And intermittently it destroyed
                // the transcript: 11.8s and 13.1s clips came back EMPTY, and a
                // 22.4s clip lost 28 of 70 words, where the same audio
                // unbiased scored 4.9%, 2.2% and 1.4%.
                //
                // Cause is in FluidAudio, not in this call: enabling boosting
                // switches SlidingWindowAsrManager.finish() onto a different
                // reconstruction path that rebuilds the text from
                // confirmedTranscript/volatileTranscript instead of decoding
                // accumulatedTokens -- and updateTranscriptionState OVERWRITES
                // volatileTranscript rather than appending. A window whose
                // rescored result is empty, before anything has been
                // confirmed, therefore discards the whole dictation. That is a
                // window-boundary condition, which is why it is intermittent
                // rather than a clean length threshold.
                //
                // Custom vocabulary still reaches the user on this engine, via
                // joinSplitTerms + fuzzyCorrect in AppState -- the path the
                // 2026-08-07 corpus run measured at 8.3% -> 2.4% on Parakeet
                // v2. Engine biasing was never what made it work.
                _ = vocabulary

                try await manager.startStreaming()

                // Read transcriptionUpdates AFTER startStreaming (FluidAudio's own
                // canonical order); no audio has been fed yet, so no update is missed.
                //
                // Every streaming update is yielded as a VOLATILE .partial (live
                // display only). SlidingWindowAsrManager emits PER-WINDOW text over
                // OVERLAPPING windows and de-overlaps them internally; the single
                // authoritative, de-overlapped transcript is finish()'s return value.
                // Mapping confirmed updates to .final (which AppState APPENDS) AND
                // then appending finish()'s full text pasted the transcript twice
                // (and would mis-join at window boundaries on longer dictations).
                let updates = await manager.transcriptionUpdates
                let updatesTask = Task {
                    for await update in updates {
                        continuation.yield(.partial(update.text))
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
