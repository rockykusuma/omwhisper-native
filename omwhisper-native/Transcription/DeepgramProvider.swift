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

import Foundation

nonisolated struct DeepgramProvider {
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

    /// The WebSocket upgrade request. CloudEngine runs the socket loop + CloseStream.
    nonisolated static func request(apiKey: String, language: String) -> URLRequest {
        var request = URLRequest(url: connectionURL(language: language))
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
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
