//
//  AudioCapture.swift
//  OmWhisper
//
//  AVAudioEngine mic capture → AsyncStream of PCM buffers.
//  Replaces the Tauri app's cpal + resampler + VAD worker (engines do their own
//  format conversion / endpointing).
//
//  Concurrency note: the project defaults new declarations to @MainActor
//  isolation (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), but AVAudioEngine's
//  tap callback genuinely runs on its own real-time render thread, not
//  MainActor. This type opts its members out of that default with `nonisolated`
//  and guards the state the tap touches with a lock instead of actor isolation
//  — the correct pattern for real-time audio, which can't tolerate an actor hop
//  or lock contention from something slow. AVAudioPCMBuffer itself isn't
//  Sendable (it's a mutable buffer wrapper), so AVFoundation is imported
//  `@preconcurrency` to avoid fighting the compiler over a framework type we
//  don't control; we uphold the actual safety invariant ourselves (each buffer
//  has exactly one producer — the tap — and is hopped to exactly one consumer).
//

@preconcurrency import AVFoundation
import os

final class AudioCapture {
    private struct State {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        var level: Float = 0
    }

    nonisolated(unsafe) private let engine = AVAudioEngine()
    nonisolated(unsafe) private let state = OSAllocatedUnfairLock(initialState: State())

    /// Mic input level (0–1) for the waveform UI. Safe to read from any thread.
    nonisolated var level: Float {
        state.withLock { $0.level }
    }

    nonisolated func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        state.withLock { $0.continuation = continuation }

        // This closure runs on AVAudioEngine's real-time render thread. It must
        // never touch MainActor state directly — only the lock-protected `state`.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [state] buffer, _ in
            let level = Self.rms(of: buffer)
            state.withLock { s in
                s.level = level
                s.continuation?.yield(buffer)
            }
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    nonisolated func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state.withLock { s in
            s.continuation?.finish()
            s.continuation = nil
            s.level = 0
        }
    }

    nonisolated private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 10)
    }
}
