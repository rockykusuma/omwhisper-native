//
//  CloudEngine.swift
//  OmWhisper
//
//  Cloud TranscriptionEngine backend — a dispatcher over CloudProviderKind.
//  Stateless like AppleEngine (a connection has no warm-up cost worth persisting).
//  Streaming providers (AssemblyAI/Deepgram) run a WebSocket and emit live
//  .partial/.final; batch providers (ElevenLabs/OpenAI/Groq) accumulate the mic
//  stream and POST it on release, emitting one .final. Each provider's own file
//  holds its wire format + pure helpers; this type only selects + wires them.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated struct CloudEngine: TranscriptionEngine {
    let kind: EngineKind = .cloud
    let provider: CloudProviderKind

    init(provider: CloudProviderKind = .assemblyAI) { self.provider = provider }

    enum EngineError: Error, LocalizedError {
        case missingAPIKey(CloudProviderKind)
        case connectionFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let p): "Add your \(p.displayName) API key in Settings → Transcription to use Cloud."
            case .connectionFailed: "Couldn't connect to the cloud transcription service."
            }
        }
    }

    private static let sampleRate = 16000

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let provider = self.provider

        // `audio` is consumed INLINE here (for-await), never forwarded to another
        // function — a sending value captured by this task closure can't be passed
        // on as `sending` without a data-race diagnostic. Providers therefore own
        // only their wire format (request/parse/close/config); this loop owns the
        // audio plumbing, matching AppleEngine/Whisper/Parakeet.
        let task = Task {
            do {
                guard let apiKey = Keychain.loadSTTKey(provider), !apiKey.isEmpty else {
                    throw EngineError.missingAPIKey(provider)
                }
                guard let pcmFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: true
                ) else { throw EngineError.connectionFailed }
                let converter = BufferConverter()

                if provider.isStreaming {
                    let request: URLRequest
                    let closeMessage: String
                    let parse: @Sendable (Data) -> TranscriptEvent?
                    switch provider {
                    case .deepgram:
                        request = DeepgramProvider.request(apiKey: apiKey, language: "auto")
                        closeMessage = #"{"type":"CloseStream"}"#
                        parse = DeepgramProvider.parseResult
                    default:   // .assemblyAI
                        request = AssemblyAIProvider.request(apiKey: apiKey, vocabulary: vocabulary)
                        closeMessage = #"{"type":"Terminate"}"#
                        parse = AssemblyAIProvider.parseServerMessage
                    }
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
                            if let data, let event = parse(data) { continuation.yield(event) }
                        }
                    }
                    for await buffer in audio {
                        guard let converted = try? converter.convertBuffer(buffer, to: pcmFormat),
                              let ch = converted.int16ChannelData else { continue }
                        let bytes = Data(bytes: ch[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
                        try? await socket.send(.data(bytes))
                    }
                    try? await socket.send(.string(closeMessage))
                    // ponytail: fixed 1s drain for the final result rather than
                    // awaiting a specific close message — revisit if endings clip.
                    try? await Task.sleep(for: .seconds(1))
                    receiveTask.cancel()
                    socket.cancel(with: .normalClosure, reason: nil)
                } else {
                    guard let config = BatchCloudTranscriber.config(for: provider) else {
                        throw EngineError.connectionFailed
                    }
                    var samples: [Int16] = []
                    for await buffer in audio {
                        guard let converted = try? converter.convertBuffer(buffer, to: pcmFormat),
                              let ch = converted.int16ChannelData else { continue }
                        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))
                    }
                    let text = try await BatchCloudTranscriber.post(samples: samples, config: config, apiKey: apiKey, language: "auto")
                    if !text.isEmpty { continuation.yield(.final(text)) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Settings' Test Connection — dispatches to the selected provider's validator.
    nonisolated static func testConnection(provider: CloudProviderKind, apiKey: String) async -> String? {
        switch provider {
        case .assemblyAI: return await AssemblyAIProvider.testConnection(apiKey: apiKey)
        case .deepgram: return await DeepgramProvider.testConnection(apiKey: apiKey)
        case .elevenLabs, .openAI, .groq:
            guard let config = BatchCloudTranscriber.config(for: provider) else { return "Unsupported provider." }
            return await BatchCloudTranscriber.testConnection(config: config, apiKey: apiKey)
        }
    }
}
