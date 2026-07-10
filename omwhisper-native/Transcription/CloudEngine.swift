//
//  CloudEngine.swift
//  OmWhisper
//
//  Third TranscriptionEngine backend: AssemblyAI Universal Streaming over a
//  WebSocket. Stateless like AppleEngine -- a streaming connection has no
//  warm-up cost worth persisting across dictation sessions, unlike
//  ParakeetEngine's CoreML model load. API details verified live against
//  AssemblyAI's docs -- see docs/superpowers/plans/2026-07-10-m4-2-cloud-engine.md.
//

// @preconcurrency: AVAudioPCMBuffer/AVAudioConverter aren't Sendable; see the
// note in AppleEngine.swift/BufferConverter.swift.
@preconcurrency import AVFoundation
import Foundation

nonisolated struct CloudEngine: TranscriptionEngine {
    let kind: EngineKind = .cloud

    enum EngineError: Error, LocalizedError {
        case missingAPIKey
        case tokenRequestFailed
        case connectionFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "Add your AssemblyAI API key in Settings → Transcription to use Cloud."
            case .tokenRequestFailed: "Couldn't authenticate with AssemblyAI."
            case .connectionFailed: "Couldn't connect to AssemblyAI."
            }
        }
    }

    private static let sampleRate = 16000

    // MARK: Pure helpers (unit-tested directly, no network involved)

    /// AssemblyAI's own documented limits: 100 keyterms max, 50 chars each.
    /// Over-length terms are silently ignored server-side -- truncating here
    /// keeps them usable rather than dropping the whole term.
    nonisolated static func cappedKeyterms(_ vocabulary: [String]) -> [String] {
        vocabulary.prefix(100).map { String($0.prefix(50)) }
    }

    nonisolated static func connectionURL(keyterms: [String]) -> URL {
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
        ]
        if !keyterms.isEmpty,
           let data = try? JSONEncoder().encode(keyterms),
           let json = String(data: data, encoding: .utf8) {
            components.queryItems?.append(URLQueryItem(name: "keyterms_prompt", value: json))
        }
        return components.url!
    }

    private struct TurnMessage: Decodable {
        let type: String
        let endOfTurn: Bool?
        let transcript: String?

        enum CodingKeys: String, CodingKey {
            case type
            case endOfTurn = "end_of_turn"
            case transcript
        }
    }

    /// nil for every server message type this engine doesn't act on
    /// (Begin/SpeechStarted/Termination/SpeakerRevision/etc) or malformed JSON.
    nonisolated static func parseServerMessage(_ data: Data) -> TranscriptEvent? {
        guard let turn = try? JSONDecoder().decode(TurnMessage.self, from: data),
              turn.type == "Turn", let transcript = turn.transcript else { return nil }
        return (turn.endOfTurn ?? false) ? .final(transcript) : .partial(transcript)
    }

    // MARK: TranscriptionEngine

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        continuation.finish(throwing: EngineError.missingAPIKey)
        return stream
    }
}
