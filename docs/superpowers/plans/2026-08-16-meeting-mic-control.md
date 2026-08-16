# Meeting Microphone Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user stop their microphone being recorded into a meeting — by a setting before the fact, or by two one-way buttons during the recording — so a conference-room side conversation and a ringing phone never land in a meeting transcript under "You".

**Architecture:** A `micMuted` flag inside `MeetingRecorder`'s existing lock-guarded `State` gates the one place mic buffers are written. The global setting starts a recording already muted, which makes the whole feature work with no CoreAudio change. A final, separately-rejectable task then strengthens the global-off case by leaving the mic sub-device out of the aggregate device entirely, so the mic never enters the process at all.

**Tech Stack:** Swift 6 (MainActor-by-default), CoreAudio process taps + aggregate devices, `OSAllocatedUnfairLock`, AVFoundation (`AVAudioFile`), GRDB, SwiftUI, Swift Testing.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-16-meeting-mic-control-design.md`. Read it before starting.
- **Mute and discard are ONE-WAY for the remainder of a recording. Never add an unmute path.** Reversible mute forces either timeline corruption (dropped frames shift every later "You" timestamp) or silence padding — and the meeting path has no VAD anywhere, where Whisper is already recorded inventing `"Thank you."` out of silence.
- Global setting `recordMeetingMic` **defaults to `true`** (today's behaviour). Flipping the default would silently stop capturing every existing user's own voice.
- `micCaptured` means **did any mic audio survive into the stored recording**, derived from the file, never from the settings that led there. Muting at minute 55 of 60 leaves it `true`.
- `MeetingRecorder` audio callbacks run on a real-time CoreAudio thread. Everything touching them stays `nonisolated`, and mutable state stays behind the existing `OSAllocatedUnfairLock`. Never do file I/O while holding that lock.
- New `AppState` settings backed by `UserDefaults` MUST use `access(keyPath:)` / `withMutation(keyPath:)` — `@Observable` only auto-instruments *stored* properties.
- Any test touching a real `meetings.db` runs against a **copy**, never production.
- Do not run `xcodebuild ... | tail` or pipe it — a pipeline returns the last command's status and hides failures. Redirect to a file, or grep without masking the exit code.
- Build/test command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`

---

## File Structure

| File | Responsibility |
|---|---|
| `omwhisper-native/Meetings/MeetingRecorder.swift` | The mute gate, discard, `micCaptured`, and (Task 6) the mic-less aggregate |
| `omwhisper-native/Meetings/MeetingStore.swift` | `micCaptured` column + migration |
| `omwhisper-native/AppState.swift` | `recordMeetingMic` setting, mute/discard commands, writing `micCaptured` at insert |
| `omwhisper-native/UI/MiniPanelView.swift` | Live mic controls in the menu bar (the surface that matters mid-call) |
| `omwhisper-native/UI/HubMeetingsSectionView.swift` | Live mic controls in the hub bar; settings toggle; provenance line |
| `omwhisper-nativeTests/MeetingMicControlTests.swift` | Recorder gate + discard + micCaptured behaviour |
| `omwhisper-nativeTests/MeetingStoreTests.swift` | `micCaptured` round-trip + migration leaves old rows NULL |
| `omwhisper-nativeTests/MeetingTranscriberTests.swift` | Regression pin: a mic-less recording still transcribes |

---

### Task 1: The mute gate and discard in MeetingRecorder

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingRecorder.swift`
- Test: `omwhisper-nativeTests/MeetingMicControlTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces, all `nonisolated` on `MeetingRecorder`:
  - `func beginWriting(to directory: URL)` — sets the recording directory and resets per-recording mic state. Called by `start()`; also the test seam.
  - `func handle(mic: AVAudioPCMBuffer, system: AVAudioPCMBuffer)` — widened from `private` to internal so the write path is testable.
  - `func muteMic()` — one-way; stops mic capture for the rest of this recording.
  - `func discardMicTrack()` — deletes `me.caf` and mutes.
  - `var micFramesWritten: AVAudioFramePosition` — frames actually written to `me.caf`; the observable the gate test asserts on.
  - `var isMicMuted: Bool`

**Why the gate lives in `handle`:** it is the single place mic buffers reach a file. Gating anywhere upstream would leave a second path open.

- [ ] **Step 1: Add the new state fields**

In `MeetingRecorder.swift`, the `private struct State` currently reads:

```swift
    private struct State {
        var systemFile: AVAudioFile?
        var micFile: AVAudioFile?
        var meetingDirectory: URL?
        /// Loudest mic sample seen this recording, in linear amplitude (0...1) --
        /// logged as a warning on stop() if it never exceeds roughly -100dBFS,
        /// the "calling app blocked mic capture" self-check ported from smriti.
        var micPeak: Float = 0
    }
```

Add two fields, keeping the existing ones and comment untouched:

```swift
        /// ONE-WAY for the remainder of a recording -- there is deliberately no
        /// unmute. A reversible mute would have to either drop frames (shifting
        /// every later "You" timestamp earlier and corrupting the interleaved
        /// transcript) or write silence (worse: the meeting path has no VAD, and
        /// Whisper is on record inventing "Thank you." out of silence). Keeping
        /// the retained audio a clean PREFIX avoids both.
        var micMuted = false
        /// Frames actually written to me.caf. The observable the mute gate is
        /// tested on -- "the file exists" would pass with the gate broken.
        var micFramesWritten: AVAudioFramePosition = 0
```

- [ ] **Step 2: Write the failing tests**

Create `omwhisper-nativeTests/MeetingMicControlTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 > /tmp/mic-t1.log; grep -E "error:|Test run with" /tmp/mic-t1.log`

Expected: compile errors — `beginWriting`, `handle`, `muteMic`, `discardMicTrack`, `micFramesWritten`, `isMicMuted`, `micCaptured`, `finishFilesForTesting` do not exist.

- [ ] **Step 4: Extract `beginWriting(to:)` and point `start()` at it**

In `start()`, replace:

```swift
        state.withLock { s in
            s.meetingDirectory = dir
        }
```

with:

```swift
        beginWriting(to: dir)
```

and add the method (place it directly above `handleRaw`):

```swift
    /// Open a recording at `directory` and reset every per-recording mic value.
    /// Not test-only: `start()` is the production caller, and resetting here is
    /// what stops a previous recording's muted state leaking into the next one.
    nonisolated func beginWriting(to directory: URL) {
        state.withLock { s in
            s.meetingDirectory = directory
            s.micMuted = false
            s.micFramesWritten = 0
            s.micPeak = 0
        }
    }
```

- [ ] **Step 5: Gate the write path**

Widen `handle` to internal and gate the mic branch. Replace the whole existing method:

```swift
    nonisolated func handle(mic micBuffer: AVAudioPCMBuffer, system systemBuffer: AVAudioPCMBuffer) {
        let peak = Self.peak(of: micBuffer)
        state.withLock { s in
            // The single place mic buffers reach a file, and therefore the only
            // place the gate has to be. Muting upstream would leave this open.
            if !s.micMuted {
                s.micPeak = max(s.micPeak, peak)
                if let url = s.meetingDirectory?.appendingPathComponent("me.caf") {
                    if s.micFile == nil {
                        s.micFile = try? AVAudioFile(forWriting: url, settings: micBuffer.format.settings)
                    }
                    if let file = s.micFile, (try? file.write(from: micBuffer)) != nil {
                        s.micFramesWritten += AVAudioFramePosition(micBuffer.frameLength)
                    }
                }
            }
            if let url = s.meetingDirectory?.appendingPathComponent("them.caf") {
                if s.systemFile == nil {
                    s.systemFile = try? AVAudioFile(forWriting: url, settings: systemBuffer.format.settings)
                }
                try? s.systemFile?.write(from: systemBuffer)
            }
        }
    }
```

- [ ] **Step 6: Add mute, discard, and the read-only observables**

Add below `beginWriting(to:)`:

```swift
    nonisolated var isMicMuted: Bool { state.withLock { $0.micMuted } }

    nonisolated var micFramesWritten: AVAudioFramePosition {
        state.withLock { $0.micFramesWritten }
    }

    /// Stop capturing the mic for the rest of this recording. One-way by design
    /// -- see the comment on State.micMuted. Closing micFile here is safe
    /// precisely because the gate above will never reopen it.
    nonisolated func muteMic() {
        state.withLock { s in
            s.micMuted = true
            s.micFile = nil
        }
        meetingLog.notice("mic muted for the remainder of this recording")
    }

    /// Delete the mic track outright and mute. Discarding WITHOUT muting would
    /// immediately re-accumulate what was just deleted.
    nonisolated func discardMicTrack() {
        // The URL is read under the lock; the file is removed outside it. This
        // lock is taken by the real-time audio callback and must never hold I/O.
        let url: URL? = state.withLock { s in
            s.micMuted = true
            s.micFile = nil
            s.micFramesWritten = 0
            return s.meetingDirectory?.appendingPathComponent("me.caf")
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        meetingLog.notice("mic track discarded at the user's request")
    }

    /// Did any mic audio survive into this recording.
    ///
    /// Read from the FILE, never from the settings that led here, so the stored
    /// flag cannot drift from what is actually on disk. Length rather than byte
    /// size: an AVAudioFile that was created and never written still has a CAF
    /// header, so `size > 0` would answer true for an empty track.
    nonisolated var micCaptured: Bool {
        guard let dir = state.withLock({ $0.meetingDirectory }) else { return false }
        let url = dir.appendingPathComponent("me.caf")
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    /// Close both files so a test can read back what was written. Production
    /// closes them in stop(); this is the same two assignments without the
    /// hardware teardown, which no test has started.
    nonisolated func finishFilesForTesting() {
        state.withLock { s in
            s.systemFile = nil
            s.micFile = nil
        }
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 > /tmp/mic-t1.log; grep -E "Meeting mic control|Test run with|TEST" /tmp/mic-t1.log`

Expected: `Suite "Meeting mic control" passed`, and the full run passes.

- [ ] **Step 8: Prove the gate test can fail**

Temporarily change `if !s.micMuted {` to `if true {` in `handle`, re-run, and confirm `muteStopsFrames` FAILS. Then restore it and confirm green again. A gate test that passes with the gate removed is decorative.

- [ ] **Step 9: Commit**

```bash
git add omwhisper-native/Meetings/MeetingRecorder.swift omwhisper-nativeTests/MeetingMicControlTests.swift
git commit -m "✨ feat(meetings): one-way mic mute and discard in the recorder"
```

---

### Task 2: Persist whether the mic was captured

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingStore.swift`
- Modify: `omwhisper-native/AppState.swift` (the `store.insert(Meeting(...))` call in `recordFinishedMeeting()`)
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: `MeetingRecorder.micCaptured` (Task 1).
- Produces: `Meeting.micCaptured: Bool?`, populated on insert.

**Why nullable:** pre-existing rows must read back NULL and render as "unknown". A non-null default would make every meeting ever recorded claim a state nobody measured.

- [ ] **Step 1: Write the failing tests**

Add to `omwhisper-nativeTests/MeetingStoreTests.swift`, inside the existing suite:

```swift
    @Test("micCaptured round-trips, and defaults to nil for rows that never set it")
    func micCapturedRoundTrips() throws {
        let store = try MeetingStore(DatabaseQueue())

        let withMic = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-16T10:00:00Z", appName: "Teams",
            directory: "/tmp/a", durationSeconds: 60, transcript: nil, summary: nil,
            createdAt: "2026-08-16T10:01:00Z", micCaptured: true))
        let withoutMic = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-16T11:00:00Z", appName: "Teams",
            directory: "/tmp/b", durationSeconds: 60, transcript: nil, summary: nil,
            createdAt: "2026-08-16T11:01:00Z", micCaptured: false))
        let unknown = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-16T12:00:00Z", appName: "Teams",
            directory: "/tmp/c", durationSeconds: 60, transcript: nil, summary: nil,
            createdAt: "2026-08-16T12:01:00Z"))

        #expect(try store.get(id: withMic)?.micCaptured == true)
        #expect(try store.get(id: withoutMic)?.micCaptured == false)
        // Three states, not two: unknown must stay distinguishable from false.
        #expect(try store.get(id: unknown)?.micCaptured == nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 > /tmp/mic-t2.log; grep -E "error:" /tmp/mic-t2.log`

Expected: compile error — `Meeting` has no `micCaptured` parameter.

- [ ] **Step 3: Add the column and the migration**

In `MeetingStore.swift`, add to the `Meeting` struct next to `summaryBackend`:

```swift
    /// Did any mic audio survive into this recording. Nullable on purpose:
    /// rows recorded before this existed read back NULL and must render as
    /// "unknown", never as a claim either way.
    var micCaptured: Bool? = nil
```

And register a migration after `summaryProvenance`:

```swift
        migrator.registerMigration("micProvenance") { db in
            try db.alter(table: Meeting.databaseTableName) { t in
                t.add(column: "micCaptured", .boolean)
            }
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 > /tmp/mic-t2.log; grep -E "Test run with|TEST" /tmp/mic-t2.log`

Expected: PASS.

- [ ] **Step 5: Populate it at insert**

In `AppState.recordFinishedMeeting()`, the insert currently ends:

```swift
                title: title,
                attendees: attendees
            ))
```

Change to:

```swift
                title: title,
                attendees: attendees,
                micCaptured: meetingRecorder.micCaptured
            ))
```

`micCaptured` reads the file, and `recordFinishedMeeting()` runs after `meetingRecorder.stop()` has closed it, so the value is final.

- [ ] **Step 6: Verify the migration against real data**

Unit tests only ever see a fresh in-memory database, which is the one case a migration cannot get wrong. Copy the dev database and migrate the copy:

```bash
pkill -x OmWhisper-Dev            # SQLite writes fail with "database is locked" while it runs
DEV=~/Library/Application\ Support/com.omwhisper.mac.dev/meetings.db
cp "$DEV" /tmp/meetings-migrationtest.db
sqlite3 /tmp/meetings-migrationtest.db "SELECT COUNT(*) FROM meetings;"     # note this number
```

Then launch the app pointed at nothing new (it migrates its own db on open), and afterwards:

```bash
sqlite3 "$DEV" "SELECT COUNT(*), COUNT(micCaptured) FROM meetings;"
```

Expected: the first number matches the count recorded before, and the second is `0` — every pre-existing row survived and reads back NULL.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-native/AppState.swift omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "✨ feat(meetings): record whether the mic was captured"
```

---

### Task 3: The global setting, and starting a recording already muted

**Files:**
- Modify: `omwhisper-native/AppState.swift`
- Test: `omwhisper-nativeTests/MeetingMicControlTests.swift`, `omwhisper-nativeTests/MeetingTranscriberTests.swift`

**Interfaces:**
- Consumes: `MeetingRecorder.muteMic()`, `beginWriting(to:)` (Task 1).
- Produces:
  - `AppState.recordMeetingMic: Bool` (default `true`)
  - `AppState.meetingMicMuted: Bool` — live state for the UI, `meetingRecorder.isMicMuted`
  - `AppState.muteMeetingMic()`, `AppState.discardMeetingMicAudio()`
  - `MeetingRecorder.start(appName:preferredMicUID:recordMic:)` — new third parameter, defaulted `true` so existing call sites compile.

- [ ] **Step 1: Write the failing tests**

Add to `MeetingMicControlTests.swift`:

```swift
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
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let recorder = MeetingRecorder()

        recorder.beginWriting(to: first)
        recorder.muteMic()
        // A one-way mute is one-way for THAT recording only. Leaking it would
        // silently stop recording the user's voice in every later meeting.
        recorder.beginWriting(to: second)
        #expect(!recorder.isMicMuted)

        recorder.handle(mic: try buffer(), system: try buffer())
        #expect(recorder.micFramesWritten > 0)
    }
```

And add to `MeetingTranscriberTests.swift` — this pins behaviour that already works and that the feature now depends on:

```swift
    @Test("a recording with no mic track still produces a transcript")
    func micLessRecordingStillTranscribes() {
        // transcribeFile returns "" for a missing file and labeledTranscript
        // omits an empty track, so a mic-less meeting must read as others-only
        // rather than failing or emitting an empty "You" heading.
        let out = MeetingTranscriber.labeledTranscript(you: "", others: "We shipped it.")
        #expect(out == "**Others:**\nWe shipped it.")
        #expect(!out.contains("You"))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 > /tmp/mic-t3.log; grep -E "error:|Expectation failed" /tmp/mic-t3.log`

Expected: compile error — `setMicEnabled` does not exist. (The transcriber test should PASS immediately; that is the point of a regression pin.)

- [ ] **Step 3: Add `setMicEnabled` and the `start` parameter**

In `MeetingRecorder.swift`, add next to `muteMic()`:

```swift
    /// Set at the start of a recording from the user's "Record my microphone"
    /// setting. Separate from muteMic() only in intent -- both land on the same
    /// one-way flag, and neither can be undone within a recording.
    nonisolated func setMicEnabled(_ enabled: Bool) {
        state.withLock { $0.micMuted = !enabled }
    }
```

Change the `start` signature:

```swift
    nonisolated func start(appName: String, preferredMicUID: String? = nil, recordMic: Bool = true) throws {
```

and immediately after the existing `beginWriting(to: dir)` call, add:

```swift
        setMicEnabled(recordMic)
```

Order matters: `beginWriting` resets the flag, so `setMicEnabled` must follow it.

- [ ] **Step 4: Add the AppState setting and commands**

In `AppState.swift`, add a key to `SettingsKeys`:

```swift
    static let recordMeetingMic = "recordMeetingMic"
```

Add the setting beside `meetingsCalendarEnabled` (the `access`/`withMutation` pattern is required — a plain computed property over UserDefaults fires no Observation signal):

```swift
    /// Default TRUE — today's behaviour. Defaulting this off would silently stop
    /// capturing every existing user's own voice in every meeting.
    var recordMeetingMic: Bool {
        get {
            access(keyPath: \.recordMeetingMic)
            return UserDefaults.standard.object(forKey: SettingsKeys.recordMeetingMic) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.recordMeetingMic) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.recordMeetingMic)
            }
        }
    }

    /// Live mic state for the recording controls. Bumped through
    /// meetingMicVersion so SwiftUI re-reads it — the recorder is not
    /// @Observable, so mutating it signals nothing on its own.
    var meetingMicMuted: Bool {
        _ = meetingMicVersion
        return meetingRecorder.isMicMuted
    }

    private var meetingMicVersion = 0

    /// Stop capturing the mic for the rest of this recording. One-way.
    func muteMeetingMic() {
        meetingRecorder.muteMic()
        meetingMicVersion &+= 1
    }

    /// Delete this recording's mic track and stop capturing. One-way.
    func discardMeetingMicAudio() {
        meetingRecorder.discardMicTrack()
        meetingMicVersion &+= 1
    }
```

- [ ] **Step 5: Pass the setting into `start`**

In `AppState`, the recorder is started at one place:

```swift
            try meetingRecorder.start(appName: appName, preferredMicUID: audioInputDeviceUID)
```

Change to:

```swift
            try meetingRecorder.start(appName: appName, preferredMicUID: audioInputDeviceUID,
                                      recordMic: recordMeetingMic)
```

This also covers the pre-roll, which begins at detection before any consent prompt exists — the seconds this setting most needs to protect.

- [ ] **Step 6: Run to verify all tests pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 > /tmp/mic-t3.log; grep -E "Test run with|TEST" /tmp/mic-t3.log`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/MeetingRecorder.swift omwhisper-native/AppState.swift omwhisper-nativeTests/
git commit -m "✨ feat(meetings): Record my microphone setting, applied from the pre-roll on"
```

---

### Task 4: The controls and the provenance line

**Files:**
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift`
- Modify: `omwhisper-native/UI/MiniPanelView.swift`

**Interfaces:**
- Consumes: `AppState.recordMeetingMic`, `meetingMicMuted`, `muteMeetingMic()`, `discardMeetingMicAudio()`, `isRecordingMeeting`, `Meeting.micCaptured`.
- Produces: no new API.

No unit tests — pure SwiftUI styling and wiring, which this project verifies live by convention (`PorcelainComponents`, `HubHomeView`, `MiniPanelView` all set that precedent). Use `Color.Porcelain.*` tokens only; never a raw hex or a system semantic colour.

- [ ] **Step 1: Add the settings toggle**

In `HubMeetingsSectionView.swift`, beside the existing "Detect and record meetings" / "Match calendar events" toggles:

```swift
                Toggle("Record my microphone", isOn: $state.recordMeetingMic)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
```

with a caption below it. The copy must describe the strong guarantee, since this path genuinely delivers it:

```swift
                Text("When off, your microphone is never added to the recording — only the other side's audio is captured.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
```

- [ ] **Step 2: Add the live controls to the hub recording bar**

In the same file, inside the `if state.isRecordingMeeting` branch that renders "Stop recording", add before it:

```swift
                    if state.meetingMicMuted {
                        Label("Mic off", systemImage: "mic.slash.fill")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                    } else {
                        Button("Mute my mic") { state.muteMeetingMic() }
                        Button("Discard my audio") { state.discardMeetingMicAudio() }
                            .foregroundStyle(.red)
                        Spacer().frame(width: 12)   // separated from Stop: it is irreversible
                    }
```

`Discard my audio` deliberately gets no confirmation dialog — it is a panic button reached for during a live meeting, and a modal defeats its purpose. Separation and destructive styling carry the warning instead.

- [ ] **Step 3: Add the same controls to the menu-bar panel**

In `MiniPanelView.swift`, below `recordMeetingButton`, add:

```swift
    @ViewBuilder
    private var micControls: some View {
        // The surface that actually matters mid-call: during a Teams meeting the
        // hub window is not open.
        if appState.isRecordingMeeting {
            if appState.meetingMicMuted {
                Label("Mic off", systemImage: "mic.slash.fill")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            } else {
                HStack(spacing: 8) {
                    Button("Mute my mic") { appState.muteMeetingMic() }
                    Button("Discard my audio") { appState.discardMeetingMicAudio() }
                        .foregroundStyle(.red)
                }
                .font(.caption)
            }
        }
    }
```

and render `micControls` directly after `recordMeetingButton` in the panel's body.

- [ ] **Step 4: Add the provenance line to the meeting detail header**

In `HubMeetingsSectionView.swift`, in the detail header beside the existing metadata (`appName · date · duration · speakers · Transcribed on this Mac`):

```swift
                    if meeting.micCaptured == false {
                        // Only for an explicit false. NULL means "recorded before
                        // this was tracked" and must claim nothing.
                        Label("Your microphone wasn't recorded", systemImage: "mic.slash")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                    }
```

- [ ] **Step 5: Build, run the suite, and relaunch**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 > /tmp/mic-t4.log; grep -E "Test run with|TEST" /tmp/mic-t4.log`

Then rebuild Debug and relaunch OmWhisper-Dev.

- [ ] **Step 6: Live-verify, with checks that can fail**

Each of these has a failing outcome; "it looked fine" is not one of them.

1. **Setting off → no mic file.** Turn "Record my microphone" off, record a short meeting, stop. Then:
   `ls ~/Library/Application\ Support/com.omwhisper.mac.dev/Meetings/<newest>/` — expected: `them.caf` present, **`me.caf` absent**. Talk during the recording so an unmuted run would definitely have produced one.
2. **Control run.** Turn it back on, record again while talking. `me.caf` must now exist and be non-empty. Without this, step 1 proves nothing — a broken recorder produces no `me.caf` either.
3. **Mute mid-recording.** Start recording with the setting on, talk, hit `Mute my mic` from the menu bar, keep talking, stop. `me.caf` exists and its duration is roughly the pre-mute stretch, not the whole recording. The transcript's `You` turns stop at the mute point.
4. **Discard.** Record, talk, hit `Discard my audio`, stop. `me.caf` is gone, the transcript has no `You` turns, and the detail header shows "Your microphone wasn't recorded".
5. **`them.caf` survives all of the above** — muting the mic must never stop recording the meeting.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/UI/
git commit -m "✨ feat(meetings): mic controls in the menu bar and hub"
```

---

### Task 5: Keep the mic out of the aggregate device entirely

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingRecorder.swift`

**Interfaces:**
- Consumes: the `recordMic` parameter on `start` (Task 3).
- Produces: no new API — an internal strengthening of the same behaviour.

**This task is deliberately last and separately rejectable.** Tasks 1–4 already deliver the whole feature. This one upgrades the global-off case from "captured and never written" to "never captured", which is what lets the settings copy say *"your microphone is never added to the recording"* honestly. If live verification fails, revert this task alone and weaken that one sentence — everything else still works.

**The hazard, stated up front:** `handleRaw` currently requires `abl.count >= 2` and hardcodes `abl[0]` as mic and `abl[1]` as system. That indexing was established empirically, by live buffer-shape logging. Remove the mic sub-device and the list has ONE buffer, `handleRaw` returns early on its guard, and **nothing is recorded at all** — including the meeting. Do not skip step 3.

- [ ] **Step 1: Store whether the mic is in the aggregate**

Add to `State`:

```swift
        /// Whether the mic sub-device is in the aggregate, which decides the
        /// SHAPE of every buffer list the IOProc receives. Not the same as
        /// micMuted: muted still delivers a mic buffer that we drop.
        var micInAggregate = true
```

- [ ] **Step 2: Build the aggregate without the mic when it is not wanted**

In `start()`, replace the aggregate description literal with:

```swift
        // With the mic excluded there is no sub-device and no main sub-device --
        // a tap-only aggregate. This is what makes "we never recorded your mic"
        // a fact about the device rather than a promise about our code.
        var description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "OmWhisper Meeting Capture",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        if recordMic {
            description[kAudioAggregateDeviceMainSubDeviceKey] = micUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: micUID]]
        }
        state.withLock { $0.micInAggregate = recordMic }
```

`beginWriting(to:)` must not reset `micInAggregate` — it is set per `start()` after `beginWriting` runs. Leave it out of that method.

- [ ] **Step 3: Make `handleRaw` handle both shapes**

Replace `handleRaw` entirely:

```swift
    nonisolated private func handleRaw(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        // The buffer list's shape follows the aggregate's composition, so branch
        // on what we built rather than guessing from the count. With the mic
        // excluded the tap is the ONLY buffer and therefore index 0 -- the old
        // `count >= 2` guard would have rejected every callback and recorded
        // nothing at all, meeting audio included.
        let micIncluded = state.withLock { $0.micInAggregate }
        if micIncluded {
            guard abl.count >= 2,
                  let micBuffer = Self.pcmBuffer(from: abl[0], sampleRate: streamSampleRate),
                  let systemBuffer = Self.pcmBuffer(from: abl[1], sampleRate: streamSampleRate) else { return }
            handle(mic: micBuffer, system: systemBuffer)
        } else {
            guard abl.count >= 1,
                  let systemBuffer = Self.pcmBuffer(from: abl[0], sampleRate: streamSampleRate) else { return }
            handleSystemOnly(systemBuffer)
        }
    }

    /// The mic-excluded path. Separate from handle(mic:system:) because there is
    /// no mic buffer to pass it -- synthesising a silent one would defeat the
    /// point and risk writing a silent me.caf.
    nonisolated func handleSystemOnly(_ systemBuffer: AVAudioPCMBuffer) {
        state.withLock { s in
            if let url = s.meetingDirectory?.appendingPathComponent("them.caf") {
                if s.systemFile == nil {
                    s.systemFile = try? AVAudioFile(forWriting: url, settings: systemBuffer.format.settings)
                }
                try? s.systemFile?.write(from: systemBuffer)
            }
        }
    }
```

- [ ] **Step 4: Add a test for the mic-excluded write path**

Add to `MeetingMicControlTests.swift`:

```swift
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
```

- [ ] **Step 5: Run the suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 > /tmp/mic-t5.log; grep -E "Test run with|TEST" /tmp/mic-t5.log`

Expected: PASS.

- [ ] **Step 6: Live-verify — the step this task exists for**

No unit test reaches `AudioHardwareCreateAggregateDevice`. Rebuild Debug, relaunch, then with "Record my microphone" **off**, record a meeting while audio plays (a video call, or any audio out of the speakers) and talk out loud:

1. `them.caf` exists and is non-empty — **the tap-only aggregate works.** If this is empty, the aggregate failed or the buffer index is wrong; revert this task.
2. `me.caf` does not exist.
3. The Console shows no `AudioHardwareCreateAggregateDevice` failure: `log show --last 5m --predicate 'subsystem CONTAINS "omwhisper"' | grep -i aggregate`
4. Turn the setting back on and record again — `me.caf` returns. This is the control that proves step 2 measured the setting and not a broken recorder.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/MeetingRecorder.swift omwhisper-nativeTests/MeetingMicControlTests.swift
git commit -m "✨ feat(meetings): leave the mic out of the aggregate when it is not wanted"
```

---

## Self-Review

**Spec coverage.** Global setting → Task 3. Never enters the process → Task 5. Two one-way live buttons → Tasks 1 and 4. No confirmation on discard → Task 4 step 2. Menu bar + hub → Task 4. `micCaptured` nullable, file-derived → Tasks 1 and 2. Header line → Task 4 step 4. Transcription with no mic track → **already implemented**; Task 3 pins it with a regression test rather than rebuilding it. Testing section → Tasks 1, 2, 3, 5. Out-of-scope items are not implemented anywhere.

**One gap found and closed while reviewing:** nothing reset `micMuted` between recordings, so a one-way mute would have leaked into every later meeting and silently stopped recording the user's voice for good. `beginWriting(to:)` now resets it, and `muteDoesNotLeakBetweenRecordings` in Task 3 fails if that regresses.

**Type consistency.** `micCaptured` is `Bool` on `MeetingRecorder` (derived) and `Bool?` on `Meeting` (stored, nullable). Deliberate, and the insert in Task 2 step 5 assigns the non-optional into the optional, which is valid. `setMicEnabled(_:)` and `muteMic()` both write `State.micMuted`; `handle(mic:system:)` keeps its argument labels from the existing code.
