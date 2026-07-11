//
//  MeetingTranscriber.swift
//  OmWhisper
//
//  Transcribes a recorded meeting's two tracks (me.caf = mic = "You",
//  them.caf = system audio = "Others") by reading each file into buffers and
//  feeding them through a TranscriptionEngine -- the same AsyncStream<AVAudioPCMBuffer>
//  contract AudioCapture uses for live dictation. On-device only (AppState passes
//  a fresh AppleEngine). Labeling is pure/tested; the file->engine drive is
//  verified live.
//
//  @preconcurrency: AVAudioPCMBuffer/AVAudioFile aren't Sendable and cross the
//  AsyncStream/Task boundary, matching AudioCapture/AppleEngine.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated enum MeetingTranscriber {
    /// Pure: markdown transcript with speaker labels; a track that's empty/whitespace
    /// is omitted; both empty → "".
    static func labeledTranscript(you: String, others: String) -> String {
        let y = you.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = others.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !y.isEmpty { parts.append("**You:**\n\(y)") }
        if !o.isEmpty { parts.append("**Others:**\n\(o)") }
        return parts.joined(separator: "\n\n")
    }

    /// Transcribe me.caf (you) + them.caf (others) sequentially → labeled transcript.
    static func transcribeMeeting(directory: URL, engine: TranscriptionEngine) async throws -> String {
        let you = try await transcribeFile(directory.appendingPathComponent("me.caf"), engine: engine)
        let others = try await transcribeFile(directory.appendingPathComponent("them.caf"), engine: engine)
        return labeledTranscript(you: you, others: others)
    }

    /// Read the whole file in buffer chunks, feed the engine, join every .final.
    /// Missing/empty file → "".
    static func transcribeFile(_ url: URL, engine: TranscriptionEngine) async throws -> String {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return "" }
        let format = file.processingFormat
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let producer = Task {
            var remaining = file.length
            let chunkFrames: AVAudioFrameCount = 8192
            while remaining > 0 {
                let n = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n),
                      (try? file.read(into: buffer, frameCount: n)) != nil,
                      buffer.frameLength > 0 else { break }
                continuation.yield(buffer)
                remaining -= Int64(buffer.frameLength)
            }
            continuation.finish()
        }

        var finals: [String] = []
        do {
            for try await event in engine.transcribe(stream, vocabulary: []) {
                if case .final(let text) = event {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { finals.append(trimmed) }
                }
            }
        } catch {
            producer.cancel()
            throw error
        }
        producer.cancel()
        return finals.joined(separator: " ")
    }

    /// Meeting length in seconds, read from the mic track. 0 if unreadable.
    static func audioDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
