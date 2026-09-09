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
import os

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

    /// A cloud transcription that returns nothing must be able to say why.
    /// Every receive error used to be swallowed by `try?`, so a rate-limited
    /// key, an expired key and a dropped network read identically to silence —
    /// the same misleading-diagnosis shape as reporting "is Ollama running?"
    /// for a timeout, and it left a real empty-transcript bug undiagnosable.
    private static let log = Logger(subsystem: "com.omwhisper.mac", category: "CloudEngine")

    /// Ceiling on how long we wait for a streaming provider to finish after we
    /// stop sending audio. NOT the expected wait: the drain ends the moment the
    /// server says it is done, which in the normal case is faster than the fixed
    /// 1s sleep this replaced. The ceiling only bounds a server that goes quiet.
    ///
    /// 2s, not longer, because the dictated text is not pasted until this stream
    /// finishes — sign-off criterion #2 is stop-to-paste under 700ms, so a
    /// generous ceiling is paid by the user on exactly the runs that already went
    /// wrong. It is deliberately not tuned for the WER harness, which feeds a file
    /// in milliseconds and would prefer a long one; the harness is not the user.
    private static let drainCeiling: Duration = .seconds(2)

    /// Waits for `finished` to end, or the ceiling, whichever comes first.
    /// Deliberately awaits the STREAM rather than the receive task's value: a
    /// cancelled child stops iterating a finished AsyncStream immediately, where
    /// `await task.value` would keep the task group open until the socket closed
    /// on its own — turning the timeout into the hang it exists to prevent.
    private static func drain(until finished: AsyncStream<Void>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in finished {} }
            group.addTask { try? await Task.sleep(for: drainCeiling) }
            await group.next()
            group.cancelAll()
        }
    }

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
                    // How each provider says "that was the last of it". AssemblyAI
                    // sends a Termination message; Deepgram simply closes the socket
                    // after CloseStream, which ends the receive loop on its own — so
                    // it needs no message check rather than a guessed one.
                    let isTerminal: @Sendable (Data) -> Bool
                    switch provider {
                    case .deepgram:
                        request = DeepgramProvider.request(apiKey: apiKey, language: "auto")
                        closeMessage = #"{"type":"CloseStream"}"#
                        parse = DeepgramProvider.parseResult
                        isTerminal = { _ in false }
                    default:   // .assemblyAI
                        request = AssemblyAIProvider.request(apiKey: apiKey, vocabulary: vocabulary)
                        closeMessage = #"{"type":"Terminate"}"#
                        parse = AssemblyAIProvider.parseServerMessage
                        isTerminal = AssemblyAIProvider.isTermination
                    }
                    // Held so it can be INVALIDATED below. A URLSession you create
                    // keeps itself alive until invalidated, so building one per
                    // dictation and dropping it leaked a session every time — and the
                    // provider counts a session it still holds open against your
                    // concurrency limit, so the leak is not merely memory. Measured:
                    // the first five clips transcribed and every one after them came
                    // back empty, sharply, in order. The batch path already uses the
                    // shared session and never had this.
                    let session = URLSession(configuration: .default)
                    let socket = session.webSocketTask(with: request)
                    socket.resume()
                    let (finished, finishedSignal) = AsyncStream<Void>.makeStream()
                    let receiveTask = Task {
                        // finish() on EVERY exit, not just the terminal one: a socket
                        // that dies mid-session must release the drain too, or the
                        // ceiling becomes the normal wait instead of the safety net.
                        defer { finishedSignal.finish() }
                        while true {
                            let message: URLSessionWebSocketTask.Message
                            do {
                                message = try await socket.receive()
                            } catch {
                                let why = socket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
                                let detail = "\(provider.displayName) socket ended: \(error.localizedDescription) closeCode=\(socket.closeCode.rawValue) reason=\(why)"
                                Self.log.error("\(detail, privacy: .public)")
                                return
                            }
                            let data: Data? = switch message {
                            case .data(let d): d
                            case .string(let s): s.data(using: .utf8)
                            @unknown default: nil
                            }
                            guard let data else { continue }
                            if let event = parse(data) { continuation.yield(event) }
                            if isTerminal(data) { return }
                        }
                    }
                    for await buffer in audio {
                        guard let converted = try? converter.convertBuffer(buffer, to: pcmFormat),
                              let ch = converted.int16ChannelData else { continue }
                        let bytes = Data(bytes: ch[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
                        try? await socket.send(.data(bytes))
                    }
                    try? await socket.send(.string(closeMessage))
                    // Wait for the server to finish rather than sleeping a fixed 1s
                    // and hoping. That guess dropped whole transcripts whenever audio
                    // was fed faster than real time: the WER harness pushes a file in
                    // milliseconds, so the server still had seconds of audio queued
                    // when the socket closed — AssemblyAI returned <empty> for 7 of 10
                    // samples, three of them perfect, a race and not a length limit.
                    // Live dictation feeds in real time and rarely hit it, which is
                    // exactly why a fixed sleep survived being wrong.
                    await Self.drain(until: finished)
                    receiveTask.cancel()
                    socket.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
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
