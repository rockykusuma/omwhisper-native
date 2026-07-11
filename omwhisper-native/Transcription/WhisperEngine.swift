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

    // uncheckedState (not initialState): State holds the non-Sendable WhisperKit
    // pipeline; the lock is the real guarantee (paired with withLockUnchecked).
    nonisolated private let state = OSAllocatedUnfairLock(uncheckedState: State())

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
    func ensureModelLoaded(progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws {
        let requested = state.withLockUnchecked { $0.requestedModel }
        if state.withLockUnchecked({ $0.pipe != nil && $0.loadedModel == requested }) { return }
        let variant = WhisperModel.whisperKitModelID(for: requested)
        let folder = try await WhisperKit.download(variant: variant, progressCallback: progressHandler)
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
