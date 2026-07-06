//
//  TranscriptionEngine.swift
//  OmWhisper
//
//  The core contract of the app. All backends — Apple SpeechTranscriber (default),
//  Parakeet CoreML, cloud streaming — conform to this. See NATIVE_MIGRATION_PLAN.md §2.
//

import AVFoundation

/// Streaming transcription event.
/// `.partial` — volatile hypothesis, render dimmed, may be replaced.
/// `.final`   — committed text, append and never rewrite.
enum TranscriptEvent: Equatable {
    case partial(String)
    case final(String)
}

enum EngineKind: String, CaseIterable, Codable {
    case apple      // SpeechTranscriber — on-device, zero-config (default)
    case parakeet   // FluidAudio CoreML — optional download (M4)
    case cloud      // WebSocket streaming provider (M4)
}

protocol TranscriptionEngine: Sendable {
    var kind: EngineKind { get }

    /// Consume mic buffers, emit streaming events. The returned stream finishes
    /// after the input stream finishes and the last `.final` has been emitted.
    func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptEvent, Error>
}
