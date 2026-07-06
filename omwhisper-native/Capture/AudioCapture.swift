//
//  AudioCapture.swift
//  OmWhisper
//
//  AVAudioEngine mic capture → AsyncStream of PCM buffers.
//  Replaces the Tauri app's cpal + resampler + VAD worker (engines do their own
//  format conversion / endpointing).
//

import AVFoundation

final class AudioCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Mic input level (0–1) for the waveform UI, updated on the audio thread's cadence.
    private(set) var level: Float = 0

    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.updateLevel(buffer)
            self?.continuation?.yield(buffer)
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        level = 0
    }

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        level = min(1, sqrt(sum / Float(n)) * 10)
    }
}
