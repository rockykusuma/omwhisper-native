//
//  TranscriptionEngine.swift
//  OmWhisper
//
//  The core contract of the app. All backends — Apple SpeechTranscriber (default),
//  Parakeet CoreML, cloud streaming — conform to this. See NATIVE_MIGRATION_PLAN.md §2.
//

// AVAudioPCMBuffer isn't Sendable (it's a mutable buffer wrapper) — imported
// @preconcurrency so conforming engines can carry it across a Task boundary
// without fighting the compiler. Each buffer has exactly one producer
// (AudioCapture's tap) and is handed to exactly one consumer (the engine).
@preconcurrency import AVFoundation

/// Streaming transcription event.
/// `.partial` — volatile hypothesis, render dimmed, may be replaced.
/// `.final`   — committed text, append and never rewrite.
enum TranscriptEvent: Equatable, Sendable {
    case partial(String)
    case final(String)
}

enum EngineKind: String, CaseIterable, Codable, Sendable {
    case apple      // SpeechTranscriber — on-device, zero-config (default)
    case parakeet   // FluidAudio CoreML — optional download (M4)
    case cloud      // WebSocket streaming provider (M4)
}

protocol TranscriptionEngine: Sendable {
    var kind: EngineKind { get }

    /// Consume mic buffers, emit streaming events. The returned stream finishes
    /// after the input stream finishes and the last `.final` has been emitted.
    /// Implementations should mark this `nonisolated` — transcription is
    /// CPU/async-heavy and must not run pinned to MainActor (the project's
    /// default actor isolation).
    ///
    /// `audio` is `sending`: the engine takes exclusive ownership so it can feed
    /// the stream to a background Task. Callers must not use the stream after the
    /// call (Swift 6 region isolation enforces this).
    ///
    /// `vocabulary` biases recognition toward custom words/phrases (product names,
    /// jargon) — read fresh at the start of each call, not cached, since engines
    /// are rebuilt per dictation session anyway.
    func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error>
}
