//
//  DeepgramProvider.swift
//  OmWhisper
//
//  Streaming cloud transcription via Deepgram's live WebSocket — same shape as the
//  AssemblyAI path (live .partial/.final), different wire format. API verified
//  against Deepgram's docs/examples 2026-07-12: wss://api.deepgram.com/v1/listen,
//  header `Authorization: Token <key>`, raw linear16 PCM frames, result JSON
//  channel.alternatives[0].transcript + is_final, close with {"type":"CloseStream"}.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated struct DeepgramProvider {

    enum ProviderError: Error { case audioFormat }

    private static let sampleRate = 16000

    // MARK: Pure helpers

    nonisolated static func connectionURL(language: String) -> URL {
        var c = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        c.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]
        if language != "auto" { c.queryItems?.append(URLQueryItem(name: "language", value: language)) }
        return c.url!
    }

    private struct Result: Decodable {
        struct Channel: Decodable { let alternatives: [Alt] }
        struct Alt: Decodable { let transcript: String }
        let channel: Channel?
        let isFinal: Bool?
        enum CodingKeys: String, CodingKey { case channel; case isFinal = "is_final" }
    }

    /// nil for empty transcripts / non-result messages / malformed JSON.
    nonisolated static func parseResult(_ data: Data) -> TranscriptEvent? {
        guard let r = try? JSONDecoder().decode(Result.self, from: data),
              let transcript = r.channel?.alternatives.first?.transcript,
              !transcript.isEmpty else { return nil }
        return (r.isFinal ?? false) ? .final(transcript) : .partial(transcript)
    }

    // MARK: Effectful — yields into the CloudEngine's shared continuation.

    static func run(
        audio: sending AsyncStream<AVAudioPCMBuffer>,
        apiKey: String, language: String,
        into continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true
        ) else { throw ProviderError.audioFormat }

        var request = URLRequest(url: connectionURL(language: language))
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession(configuration: .default).webSocketTask(with: request)
        socket.resume()

        let receiveTask = Task {
            while true {
                guard let message = try? await socket.receive() else { return }
                let data: Data? = switch message {
                case .data(let d): d
                case .string(let s): s.data(using: .utf8)
                @unknown default: nil
                }
                if let data, let event = parseResult(data) { continuation.yield(event) }
            }
        }

        let converter = BufferConverter()
        for await buffer in audio {
            guard let converted = try? converter.convertBuffer(buffer, to: pcmFormat),
                  let ch = converted.int16ChannelData else { continue }
            let bytes = Data(bytes: ch[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
            try? await socket.send(.data(bytes))
        }

        // Flush: CloseStream tells Deepgram to finish pending audio + return the
        // final results before closing.
        try? await socket.send(.string(#"{"type":"CloseStream"}"#))
        // ponytail: fixed 1s drain (matches the AssemblyAI path) rather than awaiting
        // a specific close message — revisit if live testing clips the last words.
        try? await Task.sleep(for: .seconds(1))
        receiveTask.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    /// Validates the key against Deepgram's projects endpoint (needs a valid key).
    nonisolated static func testConnection(apiKey: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return "Couldn't reach Deepgram. Check your connection."
        }
        switch http.statusCode {
        case 200: return nil
        case 401, 403: return "Invalid API key."
        default: return "Deepgram returned status \(http.statusCode)."
        }
    }
}
