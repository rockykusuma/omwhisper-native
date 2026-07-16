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

/// One-shot flag for the AVAudioConverter input block. Mutated only inside a
/// single synchronous `convertBuffer` call, never across threads — hence
/// @unchecked Sendable rather than a lock.
// nonisolated: the project defaults every unannotated type to @MainActor, which
// would make `bufferProcessed` actor-isolated and unmutable from the nonisolated
// convert block. This tiny holder is touched only there, single-threaded.
private nonisolated final class ConversionState: @unchecked Sendable {
    var bufferProcessed = false
}

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

        // Rebuild when EITHER end changes. Checking only the output format was a
        // latent bug: the input rate can change under us (a Bluetooth mic
        // renegotiating HFP flips 48kHz -> 24kHz mid-session), and a converter
        // built for the old input rate would then be fed buffers it can't convert.
        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != inputFormat {
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

        // The convert input block is @Sendable, so it can't mutate a captured
        // local var. Box the one-shot "already handed over the buffer" flag: this
        // whole method runs synchronously on one thread (see type comment), so
        // @unchecked Sendable is honest here.
        let state = ConversionState()
        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            defer { state.bufferProcessed = true }
            inputStatusPointer.pointee = state.bufferProcessed ? .noDataNow : .haveData
            return state.bufferProcessed ? nil : buffer
        }

        guard status != .error else {
            throw ConverterError.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}
