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
import os

nonisolated enum MeetingTranscriber {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OmWhisper", category: "MeetingTranscriber")

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

    /// Diarized interleaved transcript when a Whisper model is available and
    /// diarization finds speakers; otherwise the legacy on-device You/Others
    /// transcript. Never throws for the "no Whisper / no speakers" case — it
    /// falls back so a meeting always transcribes.
    static func transcribeMeeting(directory: URL, engine: TranscriptionEngine, whisper: WhisperEngine) async throws -> String {
        if whisper.isReady {
            // Never silently swallow this: a bare `try?` here hid a real failure
            // (FluidAudio's speaker models download lazily on the first-ever
            // transcribe; when that hadn't happened the meeting quietly came back
            // in the old You/Others shape with no hint diarization was even tried).
            do {
                let diarized = try await diarizedTranscript(directory: directory, whisper: whisper)
                if !diarized.isEmpty { return diarized }
                log.error("diarizedTranscript produced no text — falling back to You/Others")
            } catch {
                log.error("diarizedTranscript failed (\(String(describing: error), privacy: .public)) — falling back to You/Others")
            }
        } else {
            log.error("whisper model not downloaded — meeting falls back to You/Others (no diarization)")
        }
        let you = try await transcribeFile(directory.appendingPathComponent("me.caf"), engine: engine)
        let others = try await transcribeFile(directory.appendingPathComponent("them.caf"), engine: engine)
        return labeledTranscript(you: you, others: others)
    }

    /// Read the whole file in buffer chunks, feed the engine, join every .final.
    /// Missing/empty file → "".
    /// `vocabulary` defaults to empty so meeting transcription is unchanged;
    /// the WER benchmark passes a real list to measure whether engine biasing
    /// actually helps.
    static func transcribeFile(_ url: URL, engine: TranscriptionEngine,
                               vocabulary: [String] = []) async throws -> String {
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
            for try await event in engine.transcribe(stream, vocabulary: vocabulary) {
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

    enum MeetingTranscriberError: Error { case noSpeakers }

    /// Read a .caf into a 16 kHz mono Float array (what WhisperKit/FluidAudio want).
    static func read16kMono(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        else { return [] }
        let converter = BufferConverter()
        var samples: [Float] = []
        let chunk: AVAudioFrameCount = 8192
        var remaining = file.length
        while remaining > 0 {
            let n = AVAudioFrameCount(min(Int64(chunk), remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n),
                  (try? file.read(into: buf, frameCount: n)) != nil, buf.frameLength > 0,
                  let converted = try? converter.convertBuffer(buf, to: target),
                  let ch = converted.floatChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))
            remaining -= Int64(buf.frameLength)
        }
        return samples
    }

    /// Diarized interleaved transcript. Throws to let the caller fall back.
    static func diarizedTranscript(directory: URL, whisper: WhisperEngine) async throws -> String {
        let youSamples = read16kMono(directory.appendingPathComponent("me.caf"))
        let themSamples = read16kMono(directory.appendingPathComponent("them.caf"))

        let youTexts = youSamples.isEmpty ? [] : try await whisper.transcribeSegments(samples: youSamples)
        let youSegs = youTexts.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, speaker: "You") }

        var themSegs: [TranscriptSegment] = []
        if !themSamples.isEmpty {
            let themTexts = try await whisper.transcribeSegments(samples: themSamples)
            let speakers = try await MeetingDiarizer.diarize(samples: themSamples)
            guard !speakers.isEmpty else { throw MeetingTranscriberError.noSpeakers }
            themSegs = MeetingDiarization.alignSpeakers(texts: themTexts, speakers: speakers)
        }

        // Drop what the mic only heard because it was coming out of the speakers,
        // so a sentence the other side said isn't also attributed to "You".
        let youOwn = MeetingDiarization.dropEchoed(you: youSegs, others: themSegs)
        let merged = MeetingDiarization.mergeByTime(youOwn + themSegs)
        let relabeled = MeetingDiarization.relabelOthers(merged)
        let turns = MeetingDiarization.collapseTurns(relabeled)
        return MeetingDiarization.renderInterleaved(turns)
    }
}
