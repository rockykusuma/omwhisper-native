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

    // MARK: Token exchange

    private struct TokenResponse: Decodable {
        let token: String
    }

    nonisolated private static func requestEphemeralToken(apiKey: String) async throws -> String {
        var components = URLComponents(string: "https://streaming.assemblyai.com/v3/token")!
        components.queryItems = [URLQueryItem(name: "expires_in_seconds", value: "60")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw EngineError.tokenRequestFailed
        }
        return decoded.token
    }

    // MARK: TranscriptionEngine

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()

        let task = Task {
            do {
                guard let apiKey = Keychain.loadAssemblyAIKey(), !apiKey.isEmpty else {
                    throw EngineError.missingAPIKey
                }
                let token = try await Self.requestEphemeralToken(apiKey: apiKey)
                let keyterms = Self.cappedKeyterms(vocabulary)
                let url = Self.connectionURL(keyterms: keyterms)

                guard let pcmFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(Self.sampleRate),
                    channels: 1,
                    interleaved: true
                ) else {
                    throw EngineError.connectionFailed
                }

                var request = URLRequest(url: url)
                request.setValue(token, forHTTPHeaderField: "Authorization")
                let urlSession = URLSession(configuration: .default)
                let socket = urlSession.webSocketTask(with: request)
                socket.resume()

                // Drains Turn messages concurrently with feeding audio in below --
                // mirrors AppleEngine's resultsTask/audio-feed split.
                let receiveTask = Task {
                    while true {
                        guard let message = try? await socket.receive() else { return }
                        switch message {
                        case .data(let data):
                            if let event = Self.parseServerMessage(data) {
                                continuation.yield(event)
                            }
                        case .string(let text):
                            if let data = text.data(using: .utf8), let event = Self.parseServerMessage(data) {
                                continuation.yield(event)
                            }
                        @unknown default:
                            break
                        }
                    }
                }

                let converter = BufferConverter()
                for await buffer in audio {
                    guard let converted = try? converter.convertBuffer(buffer, to: pcmFormat),
                          let channelData = converted.int16ChannelData else { continue }
                    let frameCount = Int(converted.frameLength)
                    let bytes = Data(bytes: channelData[0], count: frameCount * MemoryLayout<Int16>.size)
                    try? await socket.send(.data(bytes))
                }

                // Mic stream ended (recording stopped) -- tell AssemblyAI to close out
                // the session so the last Turn settles into a final one, mirroring
                // AppleEngine's finalizeAndFinishThroughEndOfInput() flush.
                if let terminateJSON = String(data: try JSONEncoder().encode(["type": "Terminate"]), encoding: .utf8) {
                    try? await socket.send(.string(terminateJSON))
                }
                // ponytail: fixed 1s wait for the final Turn + Termination to arrive
                // rather than awaiting the Termination message specifically -- revisit
                // if live testing shows the last words getting cut off.
                try? await Task.sleep(for: .seconds(1))
                receiveTask.cancel()
                socket.cancel(with: .normalClosure, reason: nil)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
