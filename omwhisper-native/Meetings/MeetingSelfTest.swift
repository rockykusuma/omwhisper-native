//
//  MeetingSelfTest.swift
//  OmWhisper
//
//  Debug-only diagnostic: runs the real MeetingRecorder for a few seconds and
//  verifies both tracks actually captured signal, without needing a live
//  two-person call to reproduce the historical "mic track silently empty" bug
//  (a VoIP app holding the input device exclusively). Ported from smriti's
//  MeetingSelfTest.swift (github.com/rockykusuma/smriti, same author, MIT),
//  adapted from a CLI command to a #if DEBUG menu action.
//

#if DEBUG
import AVFoundation
import Foundation
import ScreenCaptureKit

// @MainActor (the project default): MeetingRecorder is itself MainActor-isolated
// (matching how it's called from AppState), and this is an occasional manual
// debug action, not a hot path — no reason to fight that.
enum MeetingSelfTest {
    static func run() async -> String {
        let recorder = MeetingRecorder()
        do {
            try await recorder.start(appName: "SelfTest")
        } catch let error as SCStreamError where error.code == .userDeclined {
            return """
                FAILED to start: Screen Recording permission not granted (or just granted for \
                the first time). Grant Screen Recording for OmWhisper in System Settings > \
                Privacy & Security > Screen Recording, then relaunch OmWhisper and try again — \
                a fresh grant commonly doesn't take effect until the app restarts.
                """
        } catch {
            return "FAILED to start: \(error)"
        }

        try? await Task.sleep(for: .seconds(5))
        await recorder.stop()

        guard let dir = recorder.meetingDirectory else { return "FAILED: no meeting directory" }
        let them = verdict(for: dir.appendingPathComponent("them.caf"), label: "System audio (them.caf)")
        let me = verdict(for: dir.appendingPathComponent("me.caf"), label: "Mic (me.caf)")
        return "\(them)\n\(me)"
    }

    private static func verdict(for url: URL, label: String) -> String {
        guard let file = try? AVAudioFile(forReading: url) else { return "\(label): SILENT ✗ (file not created)" }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return "\(label): SILENT ✗ (empty)"
        }
        try? file.read(into: buffer)

        var peak: Float = 0
        if let channelData = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channelData[channel][frame]))
                }
            }
        }
        let peakDB = peak > 0 ? 20 * log10(peak) : -.infinity
        let symbol = peakDB > -60 ? "OK ✓" : (peakDB > -100 ? "very quiet ⚠︎" : "SILENT ✗")
        return "\(label): duration=\(file.length / Int64(file.processingFormat.sampleRate))s peak=\(String(format: "%.1f", peakDB))dBFS \(symbol)"
    }
}
#endif
