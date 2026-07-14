//
//  MeetingDiarizer.swift
//  OmWhisper
//
//  Thin effectful wrapper over FluidAudio's DiarizerManager: 16 kHz mono Float
//  samples → speaker time-segments. Models auto-download once (downloadIfNeeded)
//  like Parakeet's. Kept out of the test target (FluidAudio is app-only); the
//  logic that consumes its output is the tested MeetingDiarization.
//

import FluidAudio
import Foundation

nonisolated enum MeetingDiarizer {
    /// Diarize a mono 16 kHz sample array → (speakerId, start, end) segments.
    static func diarize(samples: [Float], sampleRate: Int = 16000) async throws
        -> [(id: String, start: Double, end: Double)] {
        let manager = DiarizerManager()
        let models = try await DiarizerModels.downloadIfNeeded()
        manager.initialize(models: models)
        let result = try manager.performCompleteDiarization(samples, sampleRate: sampleRate)
        return result.segments.map {
            (id: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }
}
