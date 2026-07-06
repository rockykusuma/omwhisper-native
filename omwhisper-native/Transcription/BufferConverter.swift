//
//  BufferConverter.swift
//  OmWhisper
//
//  Converts AVAudioPCMBuffer between formats. AVAudioEngine hands us whatever
//  format the input device is running (e.g. 48kHz), but SpeechAnalyzer wants
//  its own best-available format — this bridges the two, reusing a single
//  AVAudioConverter across calls the way Apple's sample code does.
//

// @preconcurrency: AVAudioConverter/AVAudioPCMBuffer aren't Sendable. This type
// is only ever used within a single engine's transcribe() call, sequentially
// (one buffer converted at a time, never concurrently) — see AppleEngine.
@preconcurrency import AVFoundation

final class BufferConverter {
    enum ConverterError: Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    nonisolated(unsafe) private var converter: AVAudioConverter?

    nonisolated func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else {
            return buffer
        }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }

        guard let converter else {
            throw ConverterError.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))
        guard let conversionBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else {
            throw ConverterError.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        var bufferProcessed = false

        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            defer { bufferProcessed = true }
            inputStatusPointer.pointee = bufferProcessed ? .noDataNow : .haveData
            return bufferProcessed ? nil : buffer
        }

        guard status != .error else {
            throw ConverterError.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}
