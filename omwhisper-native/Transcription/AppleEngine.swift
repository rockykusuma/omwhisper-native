//
//  AppleEngine.swift
//  OmWhisper
//
//  Default TranscriptionEngine backend: on-device streaming ASR via the macOS 26
//  Speech framework (SpeechAnalyzer + SpeechTranscriber). This is what replaces
//  the Tauri app's whisper-rs/Parakeet/Moonshine engines, Silero VAD, and
//  two-pass decode — punctuation, endpointing, and streaming partials are all
//  built into the system model. See NATIVE_MIGRATION_PLAN.md §1.
//
//  API shape confirmed against Apple's WWDC25 "Bring advanced speech-to-text to
//  your app with SpeechAnalyzer" sample code.
//

// @preconcurrency: AVAudioPCMBuffer/AVAudioFormat aren't Sendable; see the note
// in TranscriptionEngine.swift. Speech's own types (SpeechTranscriber,
// AnalyzerInput, etc.) are a Swift-native, concurrency-first API and need no
// such treatment.
@preconcurrency import AVFoundation
import Speech

struct AppleEngine: TranscriptionEngine {
    let kind: EngineKind = .apple

    enum EngineError: Error, LocalizedError {
        case localeUnsupported
        case assetUnavailable
        case audioFormatUnavailable

        var errorDescription: String? {
            switch self {
            case .localeUnsupported:
                return "This language isn't supported by on-device speech recognition."
            case .assetUnavailable:
                return "The speech recognition model isn't available for this language."
            case .audioFormatUnavailable:
                return "Couldn't determine an audio format for the speech recognizer."
            }
        }
    }

    // nonisolated: this does real speech-processing work (buffer conversion,
    // async model calls) and must not run pinned to MainActor, which is this
    // project's default actor isolation for unannotated declarations.
    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        // makeStream (rather than the AsyncThrowingStream { continuation } builder)
        // so the producing Task is created directly in this function's region and
        // `audio` is transferred into it exactly once. The builder form kept `audio`
        // captured by both the builder closure and the nested Task, which Swift 6
        // region isolation rejects as a potential data race.
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()

        let task = Task {
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
                    throw EngineError.localeUnsupported
                }

                let transcriber = SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: []
                )

                try await Self.ensureAssetsInstalled(for: transcriber)

                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    throw EngineError.audioFormatUnavailable
                }

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

                // Drain transcriber.results concurrently with feeding audio in below —
                // volatile (dimmed, may be replaced) vs final (append, never rewritten).
                let resultsTask = Task {
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            continuation.yield(result.isFinal ? .final(text) : .partial(text))
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }

                try await analyzer.start(inputSequence: inputSequence)

                let converter = BufferConverter()
                for await buffer in audio {
                    guard let converted = try? converter.convertBuffer(buffer, to: analyzerFormat) else {
                        continue // drop malformed buffer, keep the session alive
                    }
                    inputBuilder.yield(AnalyzerInput(buffer: converted))
                }

                // Mic stream ended (recording stopped) — flush remaining audio through
                // the analyzer and let the last volatile result settle into a final one.
                inputBuilder.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                resultsTask.cancel()
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

    /// Downloads the on-device model for `transcriber`'s locale if it isn't already
    /// installed. Many users will already have it (Notes/Voice Memos/Journal share
    /// the same system models), so this usually returns immediately.
    nonisolated private static func ensureAssetsInstalled(for transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .supported:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        case .downloading:
            return // another caller kicked off the download; proceed and let it queue
        case .unsupported:
            throw EngineError.assetUnavailable
        @unknown default:
            throw EngineError.assetUnavailable
        }
    }
}
