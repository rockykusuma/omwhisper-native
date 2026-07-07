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
//  nonisolated: SCStream callbacks arrive on the sample-handler queue, not
//  MainActor, matching AudioCapture's rationale.
//

@preconcurrency import AVFoundation
import Foundation
import ScreenCaptureKit
import os

private let meetingLog = Logger(subsystem: "com.omwhisper.mac", category: "MeetingRecorder")

final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private let sampleQueue = DispatchQueue(label: "com.omwhisper.mac.meeting-recorder")
    private(set) var meetingDirectory: URL?
    /// Loudest mic sample seen this recording, in linear amplitude (0...1) --
    /// logged as a warning on stop() if it never exceeds roughly -100dBFS, the
    /// "calling app blocked mic capture" self-check ported from smriti.
    private var micPeak: Float = 0

    func start(appName: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No capturable display"])
        }

        let dir = try Self.makeMeetingDirectory(appName: appName)
        meetingDirectory = dir

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
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        systemFile = nil
        micFile = nil
        if micPeak < 0.00001 {  // roughly -100dBFS
            meetingLog.warning("stop() — mic track peak was near-silent (\(self.micPeak)); the calling app may have blocked mic capture")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        switch type {
        case .audio:
            write(pcmBuffer, to: &systemFile, url: meetingDirectory?.appendingPathComponent("them.caf"))
        case .microphone:
            trackPeak(pcmBuffer)
            write(pcmBuffer, to: &micFile, url: meetingDirectory?.appendingPathComponent("me.caf"))
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        meetingLog.error("stream stopped with error: \(error)")
    }

    private func write(_ buffer: AVAudioPCMBuffer, to file: inout AVAudioFile?, url: URL?) {
        guard let url else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
        }
        try? file?.write(from: buffer)
    }

    private func trackPeak(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<frameCount {
                micPeak = max(micPeak, abs(channelData[channel][frame]))
            }
        }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
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

    private static func makeMeetingDirectory(appName: String) throws -> URL {
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
