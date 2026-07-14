# Meetings Pass — Auto-Stop + Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make meeting recording auto-stop reliably (and detect calls) using a monitor-robust AX call-window signal, and produce interleaved per-speaker transcripts via FluidAudio diarization + WhisperKit segment timestamps.

**Architecture:** Part A swaps `MeetingWatcher`'s mic-idle signal (blinded by our own recorder) for `CallDetection.hasActiveCallWindow(pid:)` — used for both start and stop, frontmost/display-independent. Part B rebuilds `MeetingTranscriber` around transcribe-with-timestamps → diarize → time-align → collapse → render, with a fallback to today's `AppleEngine` You/Others.

**Tech Stack:** Swift 6 (MainActor-by-default), AX (`ApplicationServices`), WhisperKit + FluidAudio (app-target only), Swift Testing.

## Global Constraints

- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Types callable from tests/off-MainActor need explicit `nonisolated`.
- Swift Testing (`import Testing`, `@Test`, `#expect`), `@testable import OmWhisper`. No XCUITest.
- **WhisperKit / FluidAudio must stay out of the test target.** All pure logic (`MeetingDiarization`, `CallDetection.hasCallLikeTitle`) must not import them.
- Build/test: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test`. Swift Testing summary is `Test run with N tests…`. Full suite is **301 tests** on `main` today.
- SourceKit false-positives ("No such module 'FluidAudio'/'WhisperKit'", "cannot find X") are noise — trust `** BUILD SUCCEEDED **`.
- On-device only — recorded-call audio never egresses (standing S3 rule).
- Verified APIs (do not re-guess): FluidAudio — `DiarizerManager()`, `try await DiarizerModels.downloadIfNeeded()`, `manager.initialize(models:)`, `try manager.performCompleteDiarization(samples, sampleRate: 16000) -> DiarizationResult` whose `.segments: [TimedSpeakerSegment]` have `speakerId: String`, `startTimeSeconds: Float`, `endTimeSeconds: Float`. WhisperKit — `pipe.transcribe(audioArray: [Float], decodeOptions:) -> [TranscriptionResult]`, each `.segments: [TranscriptionSegment]` with `text: String`, `start: Float`, `end: Float`.

## File Structure

- **Modify** `omwhisper-native/Meetings/CallDetection.swift` — add `hasActiveCallWindow(pid:)` (AX) + `activeCall()` (running call app → name+pid). Reuses existing `hasCallLikeTitle`/`callerApps`.
- **Modify** `omwhisper-native/Meetings/MeetingWatcher.swift` — new signals in `nextState`; `tick()` tracks the recorded call's window (pid, seen-then-gone) instead of mic-idle.
- **Modify** `omwhisper-nativeTests/MeetingWatcherLogicTests.swift` — update for the new `nextState`.
- **Create** `omwhisper-native/Meetings/MeetingDiarization.swift` — pure `TranscriptSegment` + align/relabel/merge/collapse/render.
- **Create** `omwhisper-nativeTests/MeetingDiarizationTests.swift`.
- **Modify** `omwhisper-native/Transcription/WhisperEngine.swift` — add `transcribeSegments(samples:)`.
- **Create** `omwhisper-native/Meetings/MeetingDiarizer.swift` — FluidAudio wrapper (effectful).
- **Modify** `omwhisper-native/Meetings/MeetingTranscriber.swift` — orchestrate diarized pipeline + fallback; add a 16 kHz mono file reader.
- **Modify** `omwhisper-native/AppState.swift` — pass `whisperEngine` into `transcribeMeeting`.

---

### Task 1: CallDetection — AX call-window detection

**Files:**
- Modify: `omwhisper-native/Meetings/CallDetection.swift`

**Interfaces:**
- Produces: `CallDetection.hasActiveCallWindow(pid: pid_t) -> Bool`; `CallDetection.activeCall() -> (name: String, pid: pid_t)?`.

No new unit test (AX/NSWorkspace effectful; the reused `hasCallLikeTitle` is already tested). Build-verified; behavior live-verified in Task 6.

- [ ] **Step 1: Add the AX import + methods**

At the top of `CallDetection.swift`, ensure `import AppKit` and add `import ApplicationServices`. Then add to the `CallDetection` enum (after `hasCallLikeTitle`):

```swift
    /// True if the app with this pid currently has any window whose title looks
    /// like a call (reuses hasCallLikeTitle). Frontmost- and display-independent:
    /// AXWindows lists every window on every monitor regardless of focus — the
    /// key property for multi-monitor call detection. Called on the main actor
    /// by MeetingWatcher.
    static func hasActiveCallWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for window in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, hasCallLikeTitle(title) {
                return true
            }
        }
        return false
    }

    /// The first running recognized call app that appears to be in a call, as
    /// (name, pid). Non-verification apps (Zoom/FaceTime) count on being run
    /// while the mic is active (the watcher only calls this when the mic is on);
    /// verification apps (Teams/Slack/…) additionally require a call-like window.
    static func activeCall() -> (name: String, pid: pid_t)? {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, let caller = callerApps[bundleID] else { continue }
            let pid = app.processIdentifier
            if !caller.needsVerification { return (caller.name, pid) }
            if hasActiveCallWindow(pid: pid) { return (caller.name, pid) }
        }
        return nil
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Meetings/CallDetection.swift
git commit -m "✨ feat(meetings): AX call-window detection (frontmost/monitor-independent)"
```

---

### Task 2: MeetingWatcher — call-window signal for start + stop

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingWatcher.swift`
- Test: `omwhisper-nativeTests/MeetingWatcherLogicTests.swift`

**Interfaces:**
- Consumes: `CallDetection.activeCall()`, `CallDetection.hasActiveCallWindow(pid:)` (Task 1).
- Produces (new `nextState` signature): `nextState(current:, micActive:, activeDuration:, detectedCall:, recordingCallGone:, callGoneDuration:) -> MeetingWatcherState`.

- [ ] **Step 1: Update the failing tests**

Replace the body of `MeetingWatcherLogicTests.swift` with tests for the new signature (keep the file's existing `import`/`@Suite` header; adjust the suite name if it differs):

```swift
import Testing
@testable import OmWhisper

@Suite("MeetingWatcherLogic")
struct MeetingWatcherLogicTests {
    typealias S = MeetingWatcherState
    let start = MeetingWatcherTiming.startDebounce
    let end = MeetingWatcherTiming.endDebounce

    @Test func idleToMicActiveOnMic() {
        #expect(MeetingWatcher.nextState(current: .idle, micActive: true, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: .zero) == .micActive)
    }

    @Test func micActivePromptsOnCallAfterDebounce() {
        #expect(MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: start,
            detectedCall: "Teams", recordingCallGone: false, callGoneDuration: .zero) == .prompting(appName: "Teams"))
    }

    @Test func micActiveDeclinesWhenNoCall() {
        #expect(MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: start,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: .zero) == .declined)
    }

    @Test func recordingStaysWhileCallWindowPresent() {
        // Window never gone → keeps recording even though mic (held by us) is "active".
        #expect(MeetingWatcher.nextState(current: .recording(appName: "Teams"), micActive: true, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: end) == .recording(appName: "Teams"))
    }

    @Test func recordingStopsWhenCallWindowGonePastDebounce() {
        #expect(MeetingWatcher.nextState(current: .recording(appName: "Teams"), micActive: true, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: true, callGoneDuration: end) == .idle)
    }

    @Test func recordingHoldsBeforeDebounce() {
        #expect(MeetingWatcher.nextState(current: .recording(appName: "Teams"), micActive: true, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: true, callGoneDuration: .seconds(1)) == .recording(appName: "Teams"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "error:|BUILD FAILED" | head -5`
Expected: build failure — `nextState` argument labels don't match (extra/renamed params).

- [ ] **Step 3: Rewrite `nextState`**

In `MeetingWatcher.swift`, replace the `nextState(...)` function with:

```swift
    /// Pure state transition. Start path uses mic-activity + a detected call
    /// (frontmost-independent). Stop path uses ONLY the recorded call's window
    /// going away — never the mic, which our own recorder holds open the whole
    /// time. `recordingCallGone` is true only once we've actually seen the call
    /// window and it then disappeared, so an app that never exposes a call-like
    /// title simply never auto-stops (manual Stop still works) rather than
    /// false-stopping mid-call.
    nonisolated static func nextState(
        current: MeetingWatcherState,
        micActive: Bool,
        activeDuration: Duration,
        detectedCall: String?,
        recordingCallGone: Bool,
        callGoneDuration: Duration
    ) -> MeetingWatcherState {
        switch current {
        case .idle:
            return micActive ? .micActive : .idle
        case .micActive:
            guard micActive else { return .idle }
            guard activeDuration >= MeetingWatcherTiming.startDebounce else { return .micActive }
            if let detectedCall { return .prompting(appName: detectedCall) }
            return .declined
        case .prompting:
            return micActive ? current : .idle
        case .recording:
            return (recordingCallGone && callGoneDuration >= MeetingWatcherTiming.endDebounce) ? .idle : current
        case .declined:
            return micActive ? current : .idle
        }
    }
```

- [ ] **Step 4: Rewrite `tick()` + tracking state**

Replace the stored fields `activeSince`/`idleSince` (lines 36-37) with:

```swift
    private var activeSince: ContinuousClock.Instant?
    /// The pid of the app whose call we're recording — for the AX window auto-stop.
    private var recordingPID: pid_t?
    /// pid captured at prompt time, promoted to recordingPID if consent is accepted.
    private var pendingCallPID: pid_t?
    /// True once we've observed the recorded call's window during this recording.
    private var sawCallWindow = false
    /// When the recorded call window first went missing after having been seen.
    private var callGoneSince: ContinuousClock.Instant?
```

Replace `tick()` (lines 114-155) with:

```swift
    private func tick() {
        guard !isSuppressed() else { return }
        let micActive = Self.microphoneInUse()
        let now = ContinuousClock.now
        if micActive { if activeSince == nil { activeSince = now } } else { activeSince = nil }
        let activeDuration = activeSince.map { now - $0 } ?? .zero

        // Frontmost-independent call detection for the start path.
        let detected = micActive ? CallDetection.activeCall() : nil

        // Recorded-call window tracking for the stop path.
        var recordingCallGone = false
        var callGoneDuration: Duration = .zero
        if case .recording = state, let pid = recordingPID {
            let hasWindow = CallDetection.hasActiveCallWindow(pid: pid)
            if hasWindow {
                sawCallWindow = true
                callGoneSince = nil
            } else if sawCallWindow, callGoneSince == nil {
                callGoneSince = now
            }
            recordingCallGone = sawCallWindow && !hasWindow
            callGoneDuration = callGoneSince.map { now - $0 } ?? .zero
        }

        let previous = state
        state = Self.nextState(current: previous, micActive: micActive, activeDuration: activeDuration,
                               detectedCall: detected?.name, recordingCallGone: recordingCallGone, callGoneDuration: callGoneDuration)
        guard state != previous else { return }
        switch state {
        case .prompting(let appName):
            pendingCallPID = detected?.pid
            onShowConsentPanel(appName) { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.recordingPID = self.pendingCallPID
                    self.sawCallWindow = false
                    self.callGoneSince = nil
                    self.state = .recording(appName: appName)
                    self.onStartRecording(appName)
                } else {
                    self.state = .declined
                }
            }
        case .idle where previous.isRecording:
            recordingPID = nil
            onStopRecording()
        default:
            break
        }
    }
```

Also update `enterRecording(appName:)` (manual start, lines 103-105) to reset the tracking and best-effort capture the pid so manual recordings can still auto-stop when the call window is detectable:

```swift
    func enterRecording(appName: String) {
        recordingPID = CallDetection.activeCall()?.pid
        sawCallWindow = false
        callGoneSince = nil
        state = .recording(appName: appName)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "error:|MeetingWatcherLogic.*(passed|failed)|Test run with|BUILD FAILED" | tail -5`
Expected: `MeetingWatcherLogic` suite passes; `Test run with N tests…` (N reflects the replaced tests, roughly unchanged from 301).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Meetings/MeetingWatcher.swift omwhisper-nativeTests/MeetingWatcherLogicTests.swift
git commit -m "✨ feat(meetings): auto-stop + start-detect via call-window (fixes multi-monitor)"
```

---

### Task 3: MeetingDiarization — pure alignment/merge/collapse/render

**Files:**
- Create: `omwhisper-native/Meetings/MeetingDiarization.swift`
- Test: `omwhisper-nativeTests/MeetingDiarizationTests.swift`

**Interfaces:**
- Produces: `TranscriptSegment` (`text`, `start`, `end`, `speaker`); `MeetingDiarization.alignSpeakers(texts:speakers:)`, `.relabelOthers(_:)`, `.mergeByTime(_:)`, `.collapseTurns(_:)`, `.renderInterleaved(_:)`, `.overlap(_:_:_:_:)`.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/MeetingDiarizationTests.swift`:

```swift
import Testing
@testable import OmWhisper

@Suite("MeetingDiarization")
struct MeetingDiarizationTests {
    typealias D = MeetingDiarization

    @Test func alignPicksMostOverlappingSpeaker() {
        let texts = [(text: "hello", start: 0.0, end: 2.0)]
        let speakers = [(id: "A", start: 0.0, end: 1.0), (id: "B", start: 1.0, end: 5.0)]
        // overlap with A = 1.0, with B = 1.0 → tie broken by max's stability; assert one of them, then a clear case:
        let clear = D.alignSpeakers(texts: [(text: "x", start: 2.0, end: 3.0)], speakers: speakers)
        #expect(clear.first?.speaker == "B")
        _ = texts
    }

    @Test func alignFallsBackToNearestWhenNoOverlap() {
        let texts = [(text: "y", start: 10.0, end: 11.0)]
        let speakers = [(id: "A", start: 0.0, end: 1.0), (id: "B", start: 8.0, end: 9.0)]
        #expect(D.alignSpeakers(texts: texts, speakers: speakers).first?.speaker == "B")
    }

    @Test func relabelMapsOthersToSpeakerNByFirstAppearance() {
        let segs = [
            TranscriptSegment(text: "a", start: 0, end: 1, speaker: "You"),
            TranscriptSegment(text: "b", start: 1, end: 2, speaker: "xyz"),
            TranscriptSegment(text: "c", start: 2, end: 3, speaker: "abc"),
            TranscriptSegment(text: "d", start: 3, end: 4, speaker: "xyz"),
        ]
        let r = D.relabelOthers(segs).map(\.speaker)
        #expect(r == ["You", "Speaker 1", "Speaker 2", "Speaker 1"])
    }

    @Test func mergeSortsByStart() {
        let segs = [
            TranscriptSegment(text: "late", start: 5, end: 6, speaker: "You"),
            TranscriptSegment(text: "early", start: 1, end: 2, speaker: "Speaker 1"),
        ]
        #expect(D.mergeByTime(segs).map(\.text) == ["early", "late"])
    }

    @Test func collapseFoldsConsecutiveSameSpeaker() {
        let segs = [
            TranscriptSegment(text: "one", start: 0, end: 1, speaker: "You"),
            TranscriptSegment(text: "two", start: 1, end: 2, speaker: "You"),
            TranscriptSegment(text: "hi", start: 2, end: 3, speaker: "Speaker 1"),
        ]
        let c = D.collapseTurns(segs)
        #expect(c.count == 2)
        #expect(c.first?.text == "one two")
        #expect(c.first?.end == 2)
    }

    @Test func renderProducesMarkdownHeadings() {
        let turns = [
            TranscriptSegment(text: "hello there", start: 0, end: 2, speaker: "You"),
            TranscriptSegment(text: "hi", start: 2, end: 3, speaker: "Speaker 1"),
        ]
        #expect(D.renderInterleaved(turns) == "**You:**\nhello there\n\n**Speaker 1:**\nhi")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "cannot find 'MeetingDiarization'|cannot find 'TranscriptSegment'|BUILD FAILED" | head -3`
Expected: build failure — types not found.

- [ ] **Step 3: Write the implementation**

Create `omwhisper-native/Meetings/MeetingDiarization.swift`:

```swift
//
//  MeetingDiarization.swift
//  OmWhisper
//
//  Pure logic to turn timestamped ASR segments + speaker diarization segments
//  into an interleaved, per-speaker markdown transcript. No WhisperKit/FluidAudio
//  here — those effectful pieces live in MeetingDiarizer / WhisperEngine and
//  hand plain tuples to these functions, which are fully unit-tested.
//  See docs/superpowers/specs/2026-07-14-meetings-autostop-diarization-design.md.
//

import Foundation

nonisolated struct TranscriptSegment: Equatable {
    var text: String
    var start: Double
    var end: Double
    var speaker: String
}

nonisolated enum MeetingDiarization {
    /// Seconds of overlap between two [start,end) intervals (0 if disjoint).
    static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }

    /// Label each ASR text segment with the speaker whose diarization segment
    /// overlaps it most; when nothing overlaps, use the speaker nearest by midpoint.
    static func alignSpeakers(
        texts: [(text: String, start: Double, end: Double)],
        speakers: [(id: String, start: Double, end: Double)]
    ) -> [TranscriptSegment] {
        texts.map { t in
            let mostOverlap = speakers.max { a, b in
                overlap(t.start, t.end, a.start, a.end) < overlap(t.start, t.end, b.start, b.end)
            }
            let label: String
            if let best = mostOverlap, overlap(t.start, t.end, best.start, best.end) > 0 {
                label = best.id
            } else {
                let mid = (t.start + t.end) / 2
                label = speakers.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.id
                    ?? "Speaker 1"
            }
            return TranscriptSegment(text: t.text, start: t.start, end: t.end, speaker: label)
        }
    }

    /// Map raw diarization speaker ids (any strings) to "Speaker 1", "Speaker 2", …
    /// in order of first appearance. "You" is left untouched.
    static func relabelOthers(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var mapping: [String: String] = [:]
        var next = 1
        return segments.map { seg in
            if seg.speaker == "You" { return seg }
            let label: String
            if let existing = mapping[seg.speaker] {
                label = existing
            } else {
                label = "Speaker \(next)"
                mapping[seg.speaker] = label
                next += 1
            }
            var out = seg
            out.speaker = label
            return out
        }
    }

    /// Sort by start time (stable).
    static func mergeByTime(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated().sorted { l, r in
            l.element.start != r.element.start ? l.element.start < r.element.start : l.offset < r.offset
        }.map(\.element)
    }

    /// Fold consecutive same-speaker segments into one turn (text space-joined).
    static func collapseTurns(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for seg in segments {
            if var last = out.last, last.speaker == seg.speaker {
                last.text += " " + seg.text
                last.end = seg.end
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }

    /// Markdown: **Speaker:**\ntext, blank line between turns.
    static func renderInterleaved(_ turns: [TranscriptSegment]) -> String {
        turns.map { "**\($0.speaker):**\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n\n")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "MeetingDiarization.*(passed|failed)|Test run with|BUILD FAILED" | tail -4`
Expected: `MeetingDiarization` suite passes; `Test run with N tests…` (N up by 6).

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingDiarization.swift omwhisper-nativeTests/MeetingDiarizationTests.swift
git commit -m "✨ feat(meetings): pure diarization align/merge/collapse/render"
```

---

### Task 4: Effectful engines — Whisper segments + FluidAudio diarizer

**Files:**
- Modify: `omwhisper-native/Transcription/WhisperEngine.swift`
- Create: `omwhisper-native/Meetings/MeetingDiarizer.swift`

**Interfaces:**
- Produces: `WhisperEngine.transcribeSegments(samples: [Float]) async throws -> [(text: String, start: Double, end: Double)]`; `MeetingDiarizer.diarize(samples: [Float], sampleRate: Int) async throws -> [(id: String, start: Double, end: Double)]`.

No new unit test (both need WhisperKit/FluidAudio, out of the test target). Build-verified; live-verified in Task 6.

- [ ] **Step 1: Add `transcribeSegments` to WhisperEngine**

After `ensureModelLoaded(...)` in `WhisperEngine.swift`, add:

```swift
    /// Batch-transcribe a 16 kHz mono Float sample array into timestamped
    /// segments (for meeting diarization — the streaming transcribe() drops
    /// timestamps). Loads the requested model from disk if needed; throws
    /// modelNotDownloaded if it isn't downloaded.
    func transcribeSegments(samples: [Float]) async throws -> [(text: String, start: Double, end: Double)] {
        let requested = state.withLockUnchecked { $0.requestedModel }
        if !state.withLockUnchecked({ $0.pipe != nil && $0.loadedModel == requested }) {
            guard Self.isDownloaded(requested) else { throw EngineError.modelNotDownloaded }
            try await ensureModelLoaded()
        }
        guard let pipe = state.withLockUnchecked({ $0.pipe }) else { throw EngineError.modelNotDownloaded }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: DecodingOptions(task: .transcribe))
        return results.flatMap { $0.segments }.map {
            (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: Double($0.start), end: Double($0.end))
        }
    }
```

- [ ] **Step 2: Create the FluidAudio diarizer wrapper**

Create `omwhisper-native/Meetings/MeetingDiarizer.swift`:

```swift
//
//  MeetingDiarizer.swift
//  OmWhisper
//
//  Thin effectful wrapper over FluidAudio's DiarizerManager: 16 kHz mono Float
//  samples → speaker time-segments. Models auto-download once (downloadIfNeeded)
//  like Parakeet's. Kept out of the test target (FluidAudio is app-only); the
//  logic that consumes its output is the tested MeetingDiarization.
//

import FluidAudio
import Foundation

nonisolated enum MeetingDiarizer {
    /// Diarize a mono 16 kHz sample array → (speakerId, start, end) segments.
    static func diarize(samples: [Float], sampleRate: Int = 16000) async throws
        -> [(id: String, start: Double, end: Double)] {
        let manager = DiarizerManager()
        let models = try await DiarizerModels.downloadIfNeeded()
        manager.initialize(models: models)
        let result = try manager.performCompleteDiarization(samples, sampleRate: sampleRate)
        return result.segments.map {
            (id: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3`
Expected: `** BUILD SUCCEEDED **`. (If FluidAudio names differ, reconcile against the checkout — the plan header lists the verified signatures.)

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/Transcription/WhisperEngine.swift omwhisper-native/Meetings/MeetingDiarizer.swift
git commit -m "✨ feat(meetings): Whisper segment ASR + FluidAudio diarizer wrappers"
```

---

### Task 5: MeetingTranscriber — orchestrate diarized pipeline + fallback

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingTranscriber.swift`
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `MeetingDiarization.*` (Task 3), `WhisperEngine.transcribeSegments` + `MeetingDiarizer.diarize` (Task 4).
- Produces: `MeetingTranscriber.transcribeMeeting(directory:engine:whisper:)` (new `whisper:` param).

No new unit test (orchestration over already-tested pure logic + effectful engines). Build + suite green; live-verified in Task 6.

- [ ] **Step 1: Add a 16 kHz mono file reader + the diarized pipeline**

In `MeetingTranscriber.swift`, add (alongside the existing helpers):

```swift
    /// Read a .caf into a 16 kHz mono Float array (what WhisperKit/FluidAudio want).
    static func read16kMono(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        else { return [] }
        let converter = BufferConverter()
        var samples: [Float] = []
        let chunk: AVAudioFrameCount = 8192
        var remaining = file.length
        while remaining > 0 {
            let n = AVAudioFrameCount(min(Int64(chunk), remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n),
                  (try? file.read(into: buf, frameCount: n)) != nil, buf.frameLength > 0,
                  let converted = try? converter.convertBuffer(buf, to: target),
                  let ch = converted.floatChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))
            remaining -= Int64(buf.frameLength)
        }
        return samples
    }

    /// Diarized interleaved transcript. Throws to let the caller fall back.
    static func diarizedTranscript(directory: URL, whisper: WhisperEngine) async throws -> String {
        let youSamples = read16kMono(directory.appendingPathComponent("me.caf"))
        let themSamples = read16kMono(directory.appendingPathComponent("them.caf"))

        let youTexts = youSamples.isEmpty ? [] : try await whisper.transcribeSegments(samples: youSamples)
        let youSegs = youTexts.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, speaker: "You") }

        var themSegs: [TranscriptSegment] = []
        if !themSamples.isEmpty {
            let themTexts = try await whisper.transcribeSegments(samples: themSamples)
            let speakers = try await MeetingDiarizer.diarize(samples: themSamples)
            guard !speakers.isEmpty else { throw MeetingTranscriberError.noSpeakers }
            themSegs = MeetingDiarization.alignSpeakers(texts: themTexts, speakers: speakers)
        }

        let merged = MeetingDiarization.mergeByTime(youSegs + themSegs)
        let relabeled = MeetingDiarization.relabelOthers(merged)
        let turns = MeetingDiarization.collapseTurns(relabeled)
        return MeetingDiarization.renderInterleaved(turns)
    }

    enum MeetingTranscriberError: Error { case noSpeakers }
```

- [ ] **Step 2: Route `transcribeMeeting` through diarized-then-fallback**

Replace the existing `transcribeMeeting(directory:engine:)` with:

```swift
    /// Diarized interleaved transcript when a Whisper model is available and
    /// diarization finds speakers; otherwise the legacy on-device You/Others
    /// transcript. Never throws for the "no Whisper / no speakers" case — it
    /// falls back so a meeting always transcribes.
    static func transcribeMeeting(directory: URL, engine: TranscriptionEngine, whisper: WhisperEngine) async throws -> String {
        if whisper.isReady {
            if let diarized = try? await diarizedTranscript(directory: directory, whisper: whisper),
               !diarized.isEmpty {
                return diarized
            }
        }
        let you = try await transcribeFile(directory.appendingPathComponent("me.caf"), engine: engine)
        let others = try await transcribeFile(directory.appendingPathComponent("them.caf"), engine: engine)
        return labeledTranscript(you: you, others: others)
    }
```

- [ ] **Step 3: Update the AppState call site**

In `AppState.swift`, find where `MeetingTranscriber.transcribeMeeting(directory:engine:)` is called (inside `transcribeMeeting(id:)`) and add the `whisper:` argument:

```swift
        let transcript = try await MeetingTranscriber.transcribeMeeting(directory: dir, engine: AppleEngine(), whisper: whisperEngine)
```

(Match the surrounding code's `directory`/`engine` argument names; only the new `whisper: whisperEngine` is added. `whisperEngine` is the existing stored `let whisperEngine = WhisperEngine()`.)

- [ ] **Step 4: Build + run the suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "error:|Test run with|BUILD FAILED" | tail -5`
Expected: `Test run with N tests…`, no errors. Existing `MeetingTranscriberTests` (`labeledTranscript`) still pass (fallback path unchanged).

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingTranscriber.swift omwhisper-native/AppState.swift
git commit -m "✨ feat(meetings): diarized interleaved transcript with You/Others fallback"
```

---

### Task 6: Live verification (manual — user)

Not automated. On real hardware:

- [ ] **Multi-monitor start:** join a Teams/Zoom call on a second display and immediately work on the main display → the consent prompt still appears (start-detection no longer needs the call app frontmost).
- [ ] **Auto-stop:** leave/end the call → recording auto-stops within ~10s of the call window closing, no manual Stop needed, including when the call app was never frontmost.
- [ ] **Diarization:** record a real 3–4 person call → Transcribe & Summarize → the transcript is interleaved with per-speaker headings (You / Speaker 1 / Speaker 2 …) roughly tracking who spoke. FluidAudio diarizer models auto-download on first run.
- [ ] **Fallback:** with no Whisper model downloaded, Transcribe still produces the You/Others transcript (no crash).
- [ ] **Manual override:** the Stop button still stops immediately at any time.

---

## Self-Review

**1. Spec coverage:**
- Part A auto-stop via AX call-window → Task 1 (`hasActiveCallWindow`) + Task 2 (`nextState`/`tick` stop path). ✓
- Part A start-detection frontmost-independent → Task 1 (`activeCall`) + Task 2 (start path). ✓
- Multi-monitor robustness → inherent in AX window enumeration (Task 1). ✓
- Manual Stop override preserved → Task 2 leaves `markDeclined`/Stop wiring; `enterRecording` updated. ✓
- Part B interleaved per-speaker transcript → Task 3 (pure) + Task 4 (engines) + Task 5 (orchestrate). ✓
- Generic Speaker N labels → Task 3 `relabelOthers`. ✓
- Fallback to You/Others (no Whisper / ≤ speakers) → Task 5 `transcribeMeeting` + `noSpeakers`. ✓
- On-device throughout → WhisperKit + FluidAudio + AppleEngine, no network egress. ✓
- Two-plan note in spec → delivered as one plan per user request; parts are still committed separately (Tasks 1-2 vs 3-5). ✓
- Tests: Part A `nextState`, Part B align/relabel/merge/collapse/render → Tasks 2, 3. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step is complete. The only "match the surrounding names" note (Task 5 Step 3) is a real call-site adaptation, with the exact added argument given.

**3. Type consistency:** `TranscriptSegment`/`MeetingDiarization.*` defined in Task 3, consumed in Task 5. `transcribeSegments`/`MeetingDiarizer.diarize` defined in Task 4, consumed in Task 5. `nextState` new signature defined in Task 2, exercised by its tests. `hasActiveCallWindow`/`activeCall` defined in Task 1, consumed in Task 2. Tuple shapes `(text,start,end)` and `(id,start,end)` are consistent across Tasks 3-5.
