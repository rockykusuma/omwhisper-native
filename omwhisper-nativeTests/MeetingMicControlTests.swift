import AVFoundation
import Foundation
import Testing
@testable import OmWhisper

@Suite("Meeting mic control")
struct MeetingMicControlTests {
    /// 1024 frames of quiet-but-nonzero mono float audio. Nonzero so a write
    /// that silently produced an empty file cannot pass.
    private func buffer(sampleRate: Double = 48_000) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buf.frameLength = 1024
        let channel = try #require(buf.floatChannelData)
        for i in 0 ..< Int(buf.frameLength) { channel[0][i] = 0.25 }
        return buf
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("muting stops mic frames from being written")
    func muteStopsFrames() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder()
        recorder.beginWriting(to: dir)

        let buf = try buffer()
        recorder.handle(mic: buf, system: buf)
        let beforeMute = recorder.micFramesWritten
        #expect(beforeMute > 0, "the gate must not block a normal, unmuted write")

        recorder.muteMic()
        recorder.handle(mic: buf, system: buf)
        recorder.handle(mic: buf, system: buf)

        // The assertion that a reversible-mute change would break. Asserting
        // only "isMicMuted == true" would pass with the gate disconnected.
        #expect(recorder.micFramesWritten == beforeMute,
                "frames kept being written after mute — the gate is not connected to the write path")
    }

    @Test("the system track keeps recording after the mic is muted")
    func muteLeavesSystemTrackAlone() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder()
        recorder.beginWriting(to: dir)

        let buf = try buffer()
        recorder.muteMic()
        recorder.handle(mic: buf, system: buf)
        recorder.finishFilesForTesting()

        // Muting the mic must never stop the meeting being recorded -- that is
        // the whole point of the feature.
        let them = try #require(try? AVAudioFile(forReading: dir.appendingPathComponent("them.caf")))
        #expect(them.length > 0)
    }

    @Test("discard deletes the mic file AND leaves the mic muted")
    func discardDeletesAndMutes() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder()
        recorder.beginWriting(to: dir)

        let buf = try buffer()
        recorder.handle(mic: buf, system: buf)
        recorder.finishFilesForTesting()
        let micURL = dir.appendingPathComponent("me.caf")
        #expect(FileManager.default.fileExists(atPath: micURL.path), "nothing was captured to discard")

        recorder.discardMicTrack()
        #expect(!FileManager.default.fileExists(atPath: micURL.path))

        // Both halves asserted together: a discard that deleted the file but left
        // capture running would immediately re-accumulate what was just deleted,
        // and a test checking only the delete would pass.
        #expect(recorder.isMicMuted)
        recorder.handle(mic: buf, system: buf)
        #expect(!FileManager.default.fileExists(atPath: micURL.path),
                "audio was re-accumulated after a discard")
    }

    @Test("micCaptured is false when nothing was ever written, true once something was")
    func micCapturedReflectsTheFile() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder()
        recorder.beginWriting(to: dir)
        #expect(recorder.micCaptured == false, "no file yet, so nothing was captured")

        let buf = try buffer()
        recorder.handle(mic: buf, system: buf)
        recorder.finishFilesForTesting()
        #expect(recorder.micCaptured == true)
    }

    @Test("muting late still reports the mic as captured")
    func lateMuteStillCounts() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder()
        recorder.beginWriting(to: dir)

        let buf = try buffer()
        recorder.handle(mic: buf, system: buf)
        recorder.muteMic()
        recorder.finishFilesForTesting()

        // Minute 55 of 60. Reporting false here would put "Your microphone
        // wasn't recorded" above 55 minutes of recorded microphone.
        #expect(recorder.micCaptured == true)
    }
}
