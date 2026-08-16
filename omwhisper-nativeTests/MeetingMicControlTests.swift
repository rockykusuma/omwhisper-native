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

    @Test("a recording started with the mic disabled writes no mic frames")
    func startedMutedWritesNothing() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder()
        recorder.beginWriting(to: dir)
        recorder.setMicEnabled(false)

        let buf = try buffer()
        recorder.handle(mic: buf, system: buf)
        recorder.finishFilesForTesting()

        #expect(recorder.micFramesWritten == 0)
        #expect(recorder.micCaptured == false)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("me.caf").path),
                "me.caf was created even though the mic was disabled")
    }

    @Test("beginWriting resets a previous recording's muted state")
    func muteDoesNotLeakBetweenRecordings() throws {
        let first = try tempDirectory(), second = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let recorder = MeetingRecorder()

        recorder.beginWriting(to: first)
        recorder.muteMic()
        // A one-way mute is one-way for THAT recording only. Leaking it would
        // silently stop recording the user's voice in every later meeting —
        // exactly the silent data loss this whole design rejects.
        recorder.beginWriting(to: second)
        #expect(!recorder.isMicMuted)

        recorder.handle(mic: try buffer(), system: try buffer())
        #expect(recorder.micFramesWritten > 0)
    }

    @Test("the mic-excluded path still records the meeting")
    func systemOnlyPathRecords() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder()
        recorder.beginWriting(to: dir)

        recorder.handleSystemOnly(try buffer())
        recorder.finishFilesForTesting()

        // The failure this guards: a mic-less aggregate that silently records
        // nothing, which looks identical to "the meeting had no audio".
        let them = try #require(try? AVAudioFile(forReading: dir.appendingPathComponent("them.caf")))
        #expect(them.length > 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("me.caf").path))
    }

    @Test("a recording with no mic track still reports its real duration")
    func durationComesFromWhicheverTrackExists() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingRecorder()
        recorder.beginWriting(to: dir)
        recorder.setMicEnabled(false)

        // 48 buffers of 1024 frames at 48kHz ≈ 1.02s — just over the 1.0s floor
        // that decides "captured no audio".
        for _ in 0 ..< 48 { recorder.handleSystemOnly(try buffer()) }
        recorder.finishFilesForTesting()

        // Read from me.caf alone this is 0, which filed every mic-off recording
        // as a failed meeting, wrote a false System-Audio-permission note in as
        // its transcript, and skipped transcription of the system track holding
        // the entire call.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("me.caf").path))
        #expect(MeetingTranscriber.recordingDuration(directory: dir) > 1.0)
    }

    @Test("beginWriting closes the previous recording's files")
    func beginWritingClosesOldFiles() throws {
        let first = try tempDirectory(), second = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let recorder = MeetingRecorder()

        recorder.beginWriting(to: first)
        recorder.handle(mic: try buffer(), system: try buffer())
        // No stop() — reachable when a pre-roll is live and acceptPreRoll
        // declines, sending toggleMeetingRecording down the beginRecording path.
        recorder.beginWriting(to: second)
        recorder.handle(mic: try buffer(), system: try buffer())
        recorder.finishFilesForTesting()

        // Without the close, handle() reuses the still-open handles and the new
        // meeting's audio lands in the OLD directory — which is about to be
        // deleted — while the new meeting's folder stays empty.
        let them = try #require(try? AVAudioFile(forReading: second.appendingPathComponent("them.caf")))
        #expect(them.length > 0, "the second recording wrote nothing — its audio went to the first directory")
        let firstThem = try #require(try? AVAudioFile(forReading: first.appendingPathComponent("them.caf")))
        #expect(firstThem.length == 1024, "the first recording kept growing after a new one started")
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
