//
//  MeetingRecorder.swift
//  OmWhisper
//
//  Dual-track (system audio + mic) recording via ScreenCaptureKit -- NOT a
//  second AVAudioEngine tap. VoIP apps (Zoom, Teams, WhatsApp, etc.) hold the
//  input device exclusively during a call, so a plain AVAudioEngine mic tap
//  silently records nothing while the calling app is active. SCK's
//  captureMicrophone is a separate capture path that coexists with the
//  calling app rather than fighting it for exclusive access -- this is why
//  the feature needs SCK at all, not an optimization. Ported from smriti's
//  MeetingRecorder.swift (github.com/rockykusuma/smriti, same author, MIT).
//
//  Two independent .caf files, not one interleaved file -- them.caf (system
//  audio) and me.caf (mic) -- matching smriti's proven approach, which keeps
//  later per-track transcription simple.
//
//  Concurrency note (found via a real crash during live verification): the
//  project defaults new declarations to @MainActor (SWIFT_DEFAULT_ACTOR_ISOLATION
//  = MainActor), but SCStream invokes SCStreamOutput/SCStreamDelegate callbacks
//  on `sampleQueue` below, not MainActor. Without `nonisolated`, Swift infers
//  this whole class as MainActor-isolated, and the runtime's isolation checker
//  traps (dispatch_assert_queue_fail / EXC_BREAKPOINT) the instant a real sample
//  buffer arrives on the wrong executor -- confirmed via an actual crash report
//  (OmWhisper-2026-07-07-232744.ips) whose faulting thread was
//  "com.omwhisper.mac.meeting-recorder" inside `stream(_:didOutputSampleBuffer:of:)`.
//  Exactly AudioCapture's rationale for its tap callback: nonisolated + a lock
//  around the mutable state a background callback touches. `SCStream` itself
//  isn't Sendable (an Apple type we don't control), so — matching how
//  AudioCapture keeps its own non-Sendable `AVAudioEngine` as a separate
//  `nonisolated(unsafe)` property rather than inside its locked State — `stream`
//  lives outside the lock too. It's safe unguarded because only start()/stop()
//  ever touch it, and the MeetingWatcher state machine calling this type never
//  invokes them concurrently with each other. The two audio files and the peak
//  meter, which the sample-queue callback genuinely does touch concurrently
//  with start()/stop(), are the pieces that need the lock.
//

@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import Foundation
import os

nonisolated private let meetingLog = Logger(subsystem: "com.omwhisper.mac", category: "MeetingRecorder")

final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct State {
        var systemFile: AVAudioFile?
        var micFile: AVAudioFile?
        var meetingDirectory: URL?
        /// Loudest mic sample seen this recording, in linear amplitude (0...1) --
        /// logged as a warning on stop() if it never exceeds roughly -100dBFS,
        /// the "calling app blocked mic capture" self-check ported from smriti.
        var micPeak: Float = 0
    }

    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) private var stream: SCStream?
    nonisolated private let sampleQueue = DispatchQueue(label: "com.omwhisper.mac.meeting-recorder")

    nonisolated var meetingDirectory: URL? {
        state.withLock { $0.meetingDirectory }
    }

    nonisolated func start(appName: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No capturable display"])
        }

        let dir = try Self.makeMeetingDirectory(appName: appName)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.sampleRate = 48000
        config.channelCount = 2

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        try await newStream.startCapture()

        stream = newStream
        state.withLock { $0.meetingDirectory = dir }
    }

    nonisolated func stop() async {
        try? await stream?.stopCapture()
        stream = nil

        let peak = state.withLock { s -> Float in
            s.systemFile = nil
            s.micFile = nil
            return s.micPeak
        }
        if peak < 0.00001 {  // roughly -100dBFS
            meetingLog.warning("stop() — mic track peak was near-silent (\(peak)); the calling app may have blocked mic capture")
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        switch type {
        case .audio:
            writeSystem(pcmBuffer)
        case .microphone:
            writeMic(pcmBuffer)
        default:
            break
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        meetingLog.error("stream stopped with error: \(error)")
    }

    nonisolated private func writeSystem(_ buffer: AVAudioPCMBuffer) {
        state.withLock { s in
            guard let url = s.meetingDirectory?.appendingPathComponent("them.caf") else { return }
            if s.systemFile == nil {
                s.systemFile = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
            }
            try? s.systemFile?.write(from: buffer)
        }
    }

    nonisolated private func writeMic(_ buffer: AVAudioPCMBuffer) {
        let peak = Self.peak(of: buffer)
        state.withLock { s in
            s.micPeak = max(s.micPeak, peak)
            guard let url = s.meetingDirectory?.appendingPathComponent("me.caf") else { return }
            if s.micFile == nil {
                s.micFile = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
            }
            try? s.micFile?.write(from: buffer)
        }
    }

    nonisolated private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var result: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<frameCount {
                result = max(result, abs(channelData[channel][frame]))
            }
        }
        return result
    }

    nonisolated private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcmBuffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return pcmBuffer
    }

    nonisolated private static func makeMeetingDirectory(appName: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let stamp = formatter.string(from: Date())
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("com.omwhisper.mac", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("\(stamp)_\(appName)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
