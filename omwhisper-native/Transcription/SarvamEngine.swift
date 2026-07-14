//
//  SarvamEngine.swift
//  OmWhisper
//
//  Cross-lingual cloud engine: sends dictation audio to Sarvam's Saaras
//  speech-to-text in mode=translate → English text in one call (code-switch
//  aware). Auto-selected by AppState when crossLingual is on and a Sarvam key
//  is saved. Reuses the batch machinery (BatchCloudTranscriber). Stateless like
//  AppleEngine/CloudEngine. Sends the user's dictation AUDIO to Sarvam — see the
//  privacy note in the design spec; meetings are unaffected.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated struct SarvamEngine: TranscriptionEngine {
    let kind: EngineKind = .cloud   // it is a cloud engine; never user-picked, only auto-selected

    enum EngineError: Error, LocalizedError {
        case missingKey
        var errorDescription: String? { "Add your Sarvam API key in Settings → Transcription." }
    }

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let task = Task {
            do {
                guard let apiKey = Keychain.loadSarvamKey(), !apiKey.isEmpty else {
                    throw EngineError.missingKey
                }
                guard let pcmFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
                ) else { throw EngineError.missingKey }
                let converter = BufferConverter()
                var samples: [Int16] = []
                for await buffer in audio {
                    guard let converted = try? converter.convertBuffer(buffer, to: pcmFormat),
                          let ch = converted.int16ChannelData else { continue }
                    samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))
                }
                // Saaras auto-detects the language (built for mixed Indic+English),
                // so no language field is sent.
                let english = try await BatchCloudTranscriber.post(
                    samples: samples, config: BatchCloudTranscriber.sarvam(), apiKey: apiKey, language: nil)
                if !english.isEmpty { continuation.yield(.final(english)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
