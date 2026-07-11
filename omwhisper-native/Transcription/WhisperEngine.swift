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

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OmWhisper", category: "WhisperEngine")

    private struct State {
        var pipe: WhisperKit?
        var loadedModel: WhisperModel?
        var requestedModel: WhisperModel = .largeV3Turbo
        var requestedLanguage: String = "auto"
    }

    // uncheckedState (not initialState): State holds the non-Sendable WhisperKit
    // pipeline; the lock is the real guarantee (paired with withLockUnchecked).
    nonisolated private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// The on-disk folder WhisperKit downloads this variant into. swift-transformers'
    /// HubApi default downloadBase is ~/Documents/huggingface; a model lands at
    /// <base>/models/<repo>/<variant>. Verified against swift-transformers HubApi.swift.
    nonisolated static func modelFolderURL(_ model: WhisperModel) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(WhisperModel.whisperKitModelID(for: model), isDirectory: true)
    }

    /// Whether the variant is FULLY downloaded on disk — the truthful "downloaded?"
    /// check. Requires the core compiled models + config, NOT just a non-empty
    /// folder: a large in-flight download (turbo is multi-GB) creates the folder and
    /// streams files in, so "non-empty" would read as Ready mid-download and let a
    /// dictation load an incomplete model. Keying off disk (not the single in-memory
    /// pipe) makes "Ready" survive switching variants, navigating away, and
    /// relaunches; transcribe() loads a downloaded model from disk on first use.
    nonisolated static func isDownloaded(_ model: WhisperModel) -> Bool {
        let folder = modelFolderURL(model)
        let fm = FileManager.default
        let required = ["config.json", "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
        return required.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// True once the *requested* variant is downloaded on disk. Used by Settings to
    /// show "Ready" vs. "Download".
    nonisolated var isReady: Bool {
        Self.isDownloaded(state.withLockUnchecked { $0.requestedModel })
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
    func ensureModelLoaded(progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws {
        let requested = state.withLockUnchecked { $0.requestedModel }
        if state.withLockUnchecked({ $0.pipe != nil && $0.loadedModel == requested }) { return }
        // Already on disk → load directly (no network); else download with progress.
        let folder: URL
        if Self.isDownloaded(requested) {
            folder = Self.modelFolderURL(requested)
        } else {
            let variant = WhisperModel.whisperKitModelID(for: requested)
            folder = try await WhisperKit.download(variant: variant, progressCallback: progressHandler)
        }
        Self.log.info("loading whisper \(requested.rawValue, privacy: .public) from \(folder.path, privacy: .public)")
        let pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path))
        Self.log.info("loaded whisper \(requested.rawValue, privacy: .public) — detected variant \(String(describing: pipe.modelVariant), privacy: .public)")
        state.withLockUnchecked { $0.pipe = pipe; $0.loadedModel = requested }
    }

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()

        let task = Task {
            do {
                // Load the requested model from disk if it isn't in memory yet (e.g.
                // first dictation after a relaunch or a variant switch). This loads
                // from the cache only — it never triggers a big download; a model
                // that isn't on disk throws (download is a Settings action).
                let requested = state.withLockUnchecked { $0.requestedModel }
                let alreadyLoaded = state.withLockUnchecked { $0.pipe != nil && $0.loadedModel == requested }
                if !alreadyLoaded {
                    guard Self.isDownloaded(requested) else { throw EngineError.modelNotDownloaded }
                    try await ensureModelLoaded()
                }
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

                guard !samples.isEmpty else {
                    Self.log.info("whisper: 0 samples, nothing to transcribe")
                    continuation.finish(); return
                }
                Self.log.info("whisper transcribe: \(samples.count, privacy: .public) samples, model=\(requested.rawValue, privacy: .public), lang=\(language, privacy: .public)")

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
                Self.log.info("whisper result: \(results.count, privacy: .public) segments, text=\"\(text, privacy: .public)\"")
                if !text.isEmpty { continuation.yield(.final(text)) }
                continuation.finish()
            } catch {
                Self.log.error("whisper transcribe failed: \(String(describing: error), privacy: .public)")
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
