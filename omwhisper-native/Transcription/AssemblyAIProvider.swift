//
//  AssemblyAIProvider.swift
//  OmWhisper
//
//  Streaming cloud transcription via AssemblyAI Universal Streaming (extracted
//  from the original single-provider CloudEngine, M4.2, behavior-preserving).
//
//  Auth: a native app holds the user's OWN key (Keychain), so it's the
//  "server-side" case — the raw API key goes directly in the WebSocket upgrade's
//  Authorization header (NO "Bearer" prefix, no ephemeral-token round-trip).
//

import Foundation

nonisolated struct AssemblyAIProvider {
    private static let sampleRate = 16000

    // MARK: Pure helpers (unit-tested directly, no network)

    /// AssemblyAI's documented realtime limits: 100 keyterms max, 50 chars each.
    nonisolated static func cappedKeyterms(_ vocabulary: [String]) -> [String] {
        vocabulary.prefix(100).map { String($0.prefix(50)) }
    }

    nonisolated static func connectionURL(keyterms: [String]) -> URL {
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "speech_model", value: "universal-3-5-pro"),
            URLQueryItem(name: "mode", value: "balanced"),
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

    /// nil for every server message type this engine doesn't act on or malformed JSON.
    nonisolated static func parseServerMessage(_ data: Data) -> TranscriptEvent? {
        guard let turn = try? JSONDecoder().decode(TurnMessage.self, from: data),
              turn.type == "Turn", let transcript = turn.transcript else { return nil }
        return (turn.endOfTurn ?? false) ? .final(transcript) : .partial(transcript)
    }

    /// Validates a key against AssemblyAI's token endpoint (raw-key auth, 200 = OK).
    nonisolated static func testConnection(apiKey: String) async -> String? {
        var components = URLComponents(string: "https://streaming.assemblyai.com/v3/token")!
        components.queryItems = [URLQueryItem(name: "expires_in_seconds", value: "60")]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")   // raw key, no Bearer
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return "Couldn't reach AssemblyAI. Check your connection."
        }
        switch http.statusCode {
        case 200: return nil
        case 401: return "Invalid API key."
        default: return "AssemblyAI returned status \(http.statusCode)."
        }
    }

    /// The WebSocket upgrade request — raw key in the Authorization header (no
    /// Bearer prefix; native app = server-side auth). CloudEngine runs the socket.
    nonisolated static func request(apiKey: String, vocabulary: [String]) -> URLRequest {
        var request = URLRequest(url: connectionURL(keyterms: cappedKeyterms(vocabulary)))
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return request
    }
}
