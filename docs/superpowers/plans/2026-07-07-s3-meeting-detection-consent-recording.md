# S3 Sub-project 1: Meeting Detection, Consent & Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect when the user is in a call, ask consent via a 10-second countdown panel, and — only on explicit accept — record both sides (system audio + mic) via ScreenCaptureKit to two separate files. No transcription, summary, or UI beyond a Settings toggle and a debug self-test.

**Architecture:** New `Meetings/` group. `CallDetection` (pure bundle-ID/AX/URL matching) + `MeetingWatcher` (2s CoreAudio poll driving a pure, testable state-transition function, wrapping a `MeetingRecorder`/`MeetingConsentPanel` pair for side effects) + `MeetingRecorder` (`SCStreamOutput`/`SCStreamDelegate`, dual-track ScreenCaptureKit capture) + `MeetingConsentPanel` (a new, interactive `NSPanel` — not `OverlayPanel`, which is deliberately click-through) + a debug-only `MeetingSelfTest`.

**Tech Stack:** Swift 6, ScreenCaptureKit, CoreAudio (`AudioObjectGetPropertyData`), AppKit, Swift Testing.

## Global Constraints

- Off by default: `AppState.meetingsEnabled` defaults to `false`. `MeetingWatcher` is not instantiated or started unless this is on — no poll timer runs at all for a user who hasn't opted in.
- `MeetingWatcher`'s poll must be suppressed entirely whenever `AppState.dictation != .idle` — own dictation must never trigger a false consent prompt.
- Consent timeout (10s) or explicit decline → **nothing is ever recorded**. This must hold even under error conditions — never record without an explicit accept.
- System audio + mic capture uses **ScreenCaptureKit**, not `AVAudioEngine` — verified against the real macOS 26 SDK headers (not guessed): VoIP apps hold the input device exclusively during a call, so a plain `AVAudioEngine` tap silently records nothing while a call is active. SCK's `captureMicrophone` is a separate, coexisting capture path.
- Two independent `.caf` files per meeting (`them.caf`, `me.caf`) — not one interleaved file.
- No transcription, summarization, or UI beyond a Settings toggle in this plan — that's sub-project 2, a separate plan.
- Real, SDK-verified ScreenCaptureKit API surface (from `ScreenCaptureKit.framework`'s Objective-C headers, which is what actually defines this API — the Swift interface is a thin re-export):
  ```swift
  import ScreenCaptureKit

  let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
  let display = content.displays.first!  // SCDisplay

  let filter = SCContentFilter(display: display, excludingWindows: [])

  let config = SCStreamConfiguration()
  config.capturesAudio = true
  config.captureMicrophone = true          // macOS 15+, always available here (macOS 26 floor)
  config.excludesCurrentProcessAudio = true
  config.width = 2                          // SCK requires a video stream even for audio-only capture
  config.height = 2
  config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1fps — minimize video overhead
  config.sampleRate = 48000
  config.channelCount = 2

  let stream = SCStream(filter: filter, configuration: config, delegate: self)
  try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: someQueue)        // system audio ("them")
  try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: someQueue)   // mic ("me")
  try await stream.startCapture()
  try await stream.stopCapture()

  // SCStreamOutput (requires NSObject conformance — this is an @objc optional protocol):
  final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
      func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) { ... }
      func stream(_ stream: SCStream, didStopWithError error: Error) { ... }
  }
  ```
  `CMSampleBuffer` → `AVAudioPCMBuffer` conversion (verified against `CMSampleBuffer.h`):
  ```swift
  guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc) else { return }
  let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
  guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
  pcmBuffer.frameLength = pcmBuffer.frameCapacity
  CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, 0, Int32(frameCount), pcmBuffer.mutableAudioBufferList)
  try audioFile.write(from: pcmBuffer)
  ```

## File Structure

```
omwhisper-native/
├── Meetings/
│   ├── CallDetection.swift          # CREATE — bundle-ID allowlist + AX/frontmost/browser-URL matching (pure)
│   ├── MeetingWatcher.swift         # CREATE — 2s poll, pure state-transition function, owns recorder+panel
│   ├── MeetingRecorder.swift        # CREATE — SCK dual-track capture
│   ├── MeetingConsentPanel.swift    # CREATE — interactive NSPanel, 10s countdown
│   └── MeetingSelfTest.swift        # CREATE — #if DEBUG diagnostic
├── AppState.swift                   # MODIFY — meetingsEnabled setting, meetingWatcher collaborator
├── OmWhisperApp.swift                # MODIFY — #if DEBUG menu item
└── UI/
    ├── MeetingsSettingsView.swift   # CREATE — Settings tab
    └── SettingsView.swift            # MODIFY — add Meetings tab
omwhisper-nativeTests/
├── CallDetectionTests.swift          # CREATE
└── MeetingWatcherLogicTests.swift    # CREATE
```

---

### Task 1: `CallDetection` — call-app allowlist + verification

**Files:**
- Create: `omwhisper-native/Meetings/CallDetection.swift`
- Test: `omwhisper-nativeTests/CallDetectionTests.swift`

**Interfaces:**
- Produces: `CallDetection.callerApps: [String: CallDetection.CallerApp]`, `CallDetection.meetingDomains: [String]`, `CallDetection.recognizedApp(bundleID:isFrontmost:hasCallLikeWindowTitle:) -> String?`, `CallDetection.isMeetingURL(_:) -> Bool`, `CallDetection.hasCallLikeTitle(_:) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
// omwhisper-nativeTests/CallDetectionTests.swift
import Testing
@testable import OmWhisper

struct CallDetectionTests {
    @Test func zoomIsRecognizedWithoutVerification() {
        // Zoom doesn't need verification (it's essentially only mic-active during a call).
        let result = CallDetection.recognizedApp(bundleID: "us.zoom.xos", isFrontmost: false, hasCallLikeWindowTitle: false)
        #expect(result == "Zoom")
    }

    @Test func slackNeedsFrontmostOrCallLikeTitle() {
        // Slack runs persistently outside calls -> needs verification.
        let notInCall = CallDetection.recognizedApp(bundleID: "com.tinyspeck.slackmacgap", isFrontmost: false, hasCallLikeWindowTitle: false)
        #expect(notInCall == nil)

        let frontmost = CallDetection.recognizedApp(bundleID: "com.tinyspeck.slackmacgap", isFrontmost: true, hasCallLikeWindowTitle: false)
        #expect(frontmost == "Slack")

        let callLikeTitle = CallDetection.recognizedApp(bundleID: "com.tinyspeck.slackmacgap", isFrontmost: false, hasCallLikeWindowTitle: true)
        #expect(callLikeTitle == "Slack")
    }

    @Test func unrecognizedBundleIDReturnsNil() {
        let result = CallDetection.recognizedApp(bundleID: "com.omwhisper.mac", isFrontmost: true, hasCallLikeWindowTitle: false)
        #expect(result == nil)
    }

    @Test func meetingURLsAreRecognized() {
        #expect(CallDetection.isMeetingURL("https://meet.google.com/abc-defg-hij"))
        #expect(CallDetection.isMeetingURL("https://zoom.us/j/1234567890"))
        #expect(CallDetection.isMeetingURL("https://teams.microsoft.com/l/meetup-join/xyz"))
    }

    @Test func nonMeetingURLsAreNotRecognized() {
        #expect(!CallDetection.isMeetingURL("https://github.com/rockykusuma/omwhisper-native"))
        #expect(!CallDetection.isMeetingURL(nil))
    }

    @Test func callLikeTitlesAreRecognized() {
        #expect(CallDetection.hasCallLikeTitle("Zoom Meeting"))
        #expect(CallDetection.hasCallLikeTitle("Calling John Appleseed"))
        #expect(CallDetection.hasCallLikeTitle("Huddle in #general"))
    }

    @Test func ordinaryTitlesAreNotCallLike() {
        #expect(!CallDetection.hasCallLikeTitle("Inbox — Slack"))
        #expect(!CallDetection.hasCallLikeTitle(""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/CallDetectionTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: FAIL — `CallDetection` doesn't exist yet.

- [ ] **Step 3: Create `CallDetection.swift`**

```swift
//
//  CallDetection.swift
//  OmWhisper
//
//  Identifies whether the frontmost/mic-active context is a real call, not just
//  "the mic is on" — ported from smriti's MeetingWatcher.callerApps/looksInCall
//  (github.com/rockykusuma/smriti, same author, MIT). Apps that also run
//  persistently outside calls (Slack, Discord, Teams, WhatsApp, Webex) need
//  extra verification (frontmost, or a call-like window title); apps that are
//  essentially only mic-active during a real call (Zoom, FaceTime) don't.
//

import Foundation

nonisolated enum CallDetection {
    struct CallerApp {
        let name: String
        let needsVerification: Bool
    }

    static let callerApps: [String: CallerApp] = [
        "us.zoom.xos": CallerApp(name: "Zoom", needsVerification: false),
        "com.apple.FaceTime": CallerApp(name: "FaceTime", needsVerification: false),
        "com.microsoft.teams2": CallerApp(name: "Teams", needsVerification: true),
        "com.microsoft.teams": CallerApp(name: "Teams", needsVerification: true),
        "net.whatsapp.WhatsApp": CallerApp(name: "WhatsApp", needsVerification: true),
        "com.tinyspeck.slackmacgap": CallerApp(name: "Slack", needsVerification: true),
        "com.hnc.Discord": CallerApp(name: "Discord", needsVerification: true),
        "Cisco-Systems.Spark": CallerApp(name: "Webex", needsVerification: true),
    ]

    static let meetingDomains = [
        "meet.google", "zoom.us", "teams.microsoft", "whereby.com", "web.whatsapp",
    ]

    private static let callLikeWords = ["call", "calling", "ringing", "meeting", "huddle"]

    /// nil = not a recognized call. For apps needing verification, either
    /// `isFrontmost` or `hasCallLikeWindowTitle` must also be true.
    static func recognizedApp(bundleID: String, isFrontmost: Bool, hasCallLikeWindowTitle: Bool) -> String? {
        guard let app = callerApps[bundleID] else { return nil }
        guard app.needsVerification else { return app.name }
        return (isFrontmost || hasCallLikeWindowTitle) ? app.name : nil
    }

    static func isMeetingURL(_ url: String?) -> Bool {
        guard let url else { return false }
        return meetingDomains.contains { url.localizedCaseInsensitiveContains($0) }
    }

    static func hasCallLikeTitle(_ title: String) -> Bool {
        guard !title.isEmpty else { return false }
        return callLikeWords.contains { title.localizedCaseInsensitiveContains($0) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/CallDetectionTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 6/6 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/CallDetection.swift omwhisper-nativeTests/CallDetectionTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(meetings): add CallDetection (bundle-ID allowlist + verification)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 2: `MeetingWatcher` — state machine + pure transition logic

**Files:**
- Create: `omwhisper-native/Meetings/MeetingWatcher.swift`
- Test: `omwhisper-nativeTests/MeetingWatcherLogicTests.swift`

**Interfaces:**
- Consumes: nothing yet — `MeetingRecorder`/`MeetingConsentPanel` are Tasks 3-4. Their call sites are stored closure properties (`onStartRecording`/`onStopRecording`/`onShowConsentPanel`) defaulting to no-ops, so this file compiles and its tests run standalone; Task 5 assigns the real objects' methods to these closures once they exist.
- Produces: `MeetingWatcherState`, `MeetingWatcher.nextState(current:micActive:activeDuration:idleDuration:detectedCall:) -> MeetingWatcherState` (pure, static, testable), `MeetingWatcher` class (the real poll-driven object, wired up fully in Task 5 once `MeetingRecorder`/`MeetingConsentPanel` exist).

This task's pure logic is fully testable now; the class wrapping it needs `MeetingRecorder`/`MeetingConsentPanel` (Tasks 3-4) to actually start recording or show the panel — until then its side-effect closures are simple stored properties the class calls, satisfied by no-ops in this task and wired to the real objects in Task 5.

- [ ] **Step 1: Write the failing tests**

```swift
// omwhisper-nativeTests/MeetingWatcherLogicTests.swift
import Testing
@testable import OmWhisper

struct MeetingWatcherLogicTests {
    @Test func idleStaysIdleWithoutMic() {
        let next = MeetingWatcher.nextState(current: .idle, micActive: false, activeDuration: .zero, idleDuration: .zero, detectedCall: nil)
        #expect(next == .idle)
    }

    @Test func idleTransitionsToMicActiveWhenMicTurnsOn() {
        let next = MeetingWatcher.nextState(current: .idle, micActive: true, activeDuration: .zero, idleDuration: .zero, detectedCall: nil)
        #expect(next == .micActive)
    }

    @Test func micActiveStaysUntilThreeSecondDebounce() {
        let next = MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: .seconds(1), idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .micActive)
    }

    @Test func micActivePromptsAfterDebounceWithRecognizedCall() {
        let next = MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: .seconds(3), idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .prompting(appName: "Zoom"))
    }

    @Test func micActiveDeclinesAfterDebounceWithNoRecognizedCall() {
        // Own dictation or an unrelated app -- never prompt.
        let next = MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: .seconds(3), idleDuration: .zero, detectedCall: nil)
        #expect(next == .declined)
    }

    @Test func micActiveGoesIdleIfMicTurnsOffBeforeDebounce() {
        let next = MeetingWatcher.nextState(current: .micActive, micActive: false, activeDuration: .seconds(1), idleDuration: .zero, detectedCall: nil)
        #expect(next == .idle)
    }

    @Test func promptingResetsToIdleIfMicGoesOff() {
        let next = MeetingWatcher.nextState(current: .prompting(appName: "Zoom"), micActive: false, activeDuration: .zero, idleDuration: .zero, detectedCall: nil)
        #expect(next == .idle)
    }

    @Test func promptingStaysUntilExternalConsentDecision() {
        // The consent panel's own accept/decline/timeout drives the real
        // transition out of .prompting -- this function alone just holds while
        // the mic is still active.
        let next = MeetingWatcher.nextState(current: .prompting(appName: "Zoom"), micActive: true, activeDuration: .zero, idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .prompting(appName: "Zoom"))
    }

    @Test func recordingStaysWhileMicActive() {
        let next = MeetingWatcher.nextState(current: .recording(appName: "Zoom"), micActive: true, activeDuration: .zero, idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .recording(appName: "Zoom"))
    }

    @Test func recordingStaysUntilEightSecondIdleDebounce() {
        let next = MeetingWatcher.nextState(current: .recording(appName: "Zoom"), micActive: false, activeDuration: .zero, idleDuration: .seconds(3), detectedCall: nil)
        #expect(next == .recording(appName: "Zoom"))
    }

    @Test func recordingFinalizesAfterEightSecondIdleDebounce() {
        let next = MeetingWatcher.nextState(current: .recording(appName: "Zoom"), micActive: false, activeDuration: .zero, idleDuration: .seconds(8), detectedCall: nil)
        #expect(next == .idle)
    }

    @Test func declinedStaysUntilMicGoesIdle() {
        let next = MeetingWatcher.nextState(current: .declined, micActive: true, activeDuration: .zero, idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .declined)
    }

    @Test func declinedRearmsWhenMicGoesIdle() {
        let next = MeetingWatcher.nextState(current: .declined, micActive: false, activeDuration: .zero, idleDuration: .zero, detectedCall: nil)
        #expect(next == .idle)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/MeetingWatcherLogicTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: FAIL — `MeetingWatcherState`/`MeetingWatcher` don't exist yet.

- [ ] **Step 3: Create `MeetingWatcher.swift`**

```swift
//
//  MeetingWatcher.swift
//  OmWhisper
//
//  Mic-open detection + consent state machine, ported from smriti's
//  MeetingWatcher.swift (github.com/rockykusuma/smriti, same author, MIT).
//  Polls kAudioDevicePropertyDeviceIsRunningSomewhere every 2s -- cheap
//  property reads, no audio tap while idle. Timing values (3s start-debounce,
//  8s end-debounce, 10s consent countdown) are carried over from smriti's
//  implementation, already proven against real calls.
//

import CoreAudio
import Foundation

nonisolated enum MeetingWatcherState: Equatable {
    case idle
    case micActive
    case prompting(appName: String)
    case recording(appName: String)
    case declined
}

nonisolated enum MeetingWatcherTiming {
    static let pollInterval: Duration = .seconds(2)
    static let startDebounce: Duration = .seconds(3)
    static let endDebounce: Duration = .seconds(8)
    static let consentTimeout: Duration = .seconds(10)
}

@MainActor
final class MeetingWatcher {
    private(set) var state: MeetingWatcherState = .idle
    private var pollTimer: Timer?
    private var activeSince: ContinuousClock.Instant?
    private var idleSince: ContinuousClock.Instant?

    /// Injected so this can be constructed and unit-exercised without the real
    /// recorder/panel (Tasks 3-4) -- Task 5 wires these to MeetingRecorder/
    /// MeetingConsentPanel. Both default to no-ops so this file compiles standalone.
    var onStartRecording: (String) -> Void = { _ in }
    var onStopRecording: () -> Void = {}
    var onShowConsentPanel: (String, @escaping (Bool) -> Void) -> Void = { _, respond in respond(false) }

    /// True while `AppState.dictation != .idle` -- suppresses the whole watcher
    /// so our own dictation never triggers a false consent prompt.
    var isSuppressed: () -> Bool = { false }

    /// Pure decision: given the current state and freshly-measured mic/call
    /// signals, what's the next state? Side effects (starting the recorder,
    /// showing the consent panel) happen in the caller when it observes a
    /// state *change*, not inside this function.
    nonisolated static func nextState(
        current: MeetingWatcherState,
        micActive: Bool,
        activeDuration: Duration,
        idleDuration: Duration,
        detectedCall: String?
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
        case .recording(let appName):
            guard !micActive else { return current }
            return idleDuration >= MeetingWatcherTiming.endDebounce ? .idle : current
        case .declined:
            return micActive ? current : .idle
        }
    }

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: MeetingWatcherTiming.pollInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Called by the caller's onStartRecording closure if MeetingRecorder.start()
    /// throws -- without this, a failed recorder start would leave `state` stuck
    /// showing `.recording` (set optimistically before the async start call)
    /// while no audio is actually being captured, only self-correcting whenever
    /// the mic eventually goes idle on its own (up to the 8s end-debounce later).
    func failedToStartRecording() {
        state = .idle
    }

    private func tick() {
        guard !isSuppressed() else { return }
        let micActive = Self.microphoneInUse()
        let now = ContinuousClock.now

        if micActive {
            if activeSince == nil { activeSince = now }
            idleSince = nil
        } else {
            if idleSince == nil { idleSince = now }
            activeSince = nil
        }

        let activeDuration = activeSince.map { now - $0 } ?? .zero
        let idleDuration = idleSince.map { now - $0 } ?? .zero
        let detectedCall = micActive ? CallDetection.recognizedApp(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            isFrontmost: true,
            hasCallLikeWindowTitle: false
        ) : nil

        let previous = state
        state = Self.nextState(current: previous, micActive: micActive, activeDuration: activeDuration, idleDuration: idleDuration, detectedCall: detectedCall)

        guard state != previous else { return }
        switch state {
        case .prompting(let appName):
            onShowConsentPanel(appName) { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.state = .recording(appName: appName)
                    self.onStartRecording(appName)
                } else {
                    self.state = .declined
                }
            }
        case .idle where previous.isRecording:
            onStopRecording()
        default:
            break
        }
    }

    /// kAudioDevicePropertyDeviceIsRunningSomewhere on the default input device --
    /// true if *any* client in any process currently has an IO stream running,
    /// not which app specifically. Two trivial property reads, no allocation.
    nonisolated static func microphoneInUse() -> Bool {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID)
        guard deviceStatus == noErr else { return false }

        var isRunning: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let runningStatus = AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &isRunningSize, &isRunning)
        guard runningStatus == noErr else { return false }
        return isRunning != 0
    }
}

private extension MeetingWatcherState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
```

- [ ] **Step 4: Add `import AppKit` for `NSWorkspace`**

Find:
```swift
import CoreAudio
import Foundation
```

Replace with:
```swift
import AppKit
import CoreAudio
import Foundation
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/MeetingWatcherLogicTests 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 12/12 tests.

- [ ] **Step 6: Run full suite to check for regressions**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 96/96 (78 existing + 6 CallDetection + 12 MeetingWatcherLogic).

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/MeetingWatcher.swift omwhisper-nativeTests/MeetingWatcherLogicTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(meetings): add MeetingWatcher state machine" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 3: `MeetingRecorder` — dual-track ScreenCaptureKit capture

**Files:**
- Create: `omwhisper-native/Meetings/MeetingRecorder.swift`

**Interfaces:**
- Produces: `MeetingRecorder`, `MeetingRecorder.start(appName:) async throws`, `MeetingRecorder.stop() async`.

No unit tests — hardware/permission-dependent, matches `AudioCapture`/`ScreenContextReader` precedent. Verified via Task 6's self-test and this sub-project's live-verification pass (Task 7).

- [ ] **Step 1: Create `MeetingRecorder.swift`**

```swift
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
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = AVAudioFormat(cmAudioFormatDescription: formatDesc) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, 0, Int32(frameCount), pcmBuffer.mutableAudioBufferList)
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`. If a Swift 6 Sendable/isolation error appears on the `SCStreamOutput`/`SCStreamDelegate` conformance, check that `@unchecked Sendable` is still present on the class (SCK's delegate protocols are `@objc` and predate Swift concurrency annotations, so the compiler can't verify their thread-safety automatically) and that the mutable properties (`stream`, `systemFile`, `micFile`, `meetingDirectory`, `micPeak`) are only ever touched from `sampleQueue`'s callbacks or the actor-isolated `start`/`stop` calls — never both concurrently.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Meetings/MeetingRecorder.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(meetings): add MeetingRecorder (dual-track ScreenCaptureKit capture)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 4: `MeetingConsentPanel`

**Files:**
- Create: `omwhisper-native/Meetings/MeetingConsentPanel.swift`

**Interfaces:**
- Produces: `MeetingConsentPanel`, `MeetingConsentPanel.show(appName:onDecision: @escaping (Bool) -> Void)`.

No unit tests — SwiftUI/AppKit view, matching this project's convention. Live-verified in Task 7.

- [ ] **Step 1: Create `MeetingConsentPanel.swift`**

```swift
//
//  MeetingConsentPanel.swift
//  OmWhisper
//
//  Interactive consent prompt for meeting recording -- a NEW NSPanel, not
//  OverlayPanel reused: that panel is deliberately `ignoresMouseEvents = true`
//  for the display-only dictation HUD, incompatible with a panel that needs a
//  clickable countdown button. Non-activating, floating, top-right, matching
//  smriti's positioning. 10-second timeout -- "silence = no", always.
//

import AppKit
import SwiftUI

@MainActor
final class MeetingConsentPanel {
    private var panel: NSPanel?
    private var countdownTimer: Timer?

    func show(appName: String, onDecision: @escaping (Bool) -> Void) {
        dismiss()

        var remaining = Int(MeetingWatcherTiming.consentTimeout.components.seconds)
        let content = MeetingConsentView(appName: appName, secondsRemaining: remaining) { [weak self] accepted in
            self?.dismiss()
            onDecision(accepted)
        }
        let hosting = NSHostingView(rootView: content)
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.contentView = hosting
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        position(newPanel)
        newPanel.orderFrontRegardless()
        panel = newPanel
        NSSound(named: "Submarine")?.play()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            remaining -= 1
            guard remaining > 0 else {
                self?.dismiss()
                onDecision(false)
                return
            }
        }
    }

    func dismiss() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
    }
}

private struct MeetingConsentView: View {
    let appName: String
    @State var secondsRemaining: Int
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Record this \(appName) call?")
                .font(.headline)
            Text("No response in \(Int(MeetingWatcherTiming.consentTimeout.components.seconds))s = don't record. Stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Not now") { onDecision(false) }
                Spacer()
                Button("Record (\(secondsRemaining))") { onDecision(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if secondsRemaining > 0 { secondsRemaining -= 1 }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Meetings/MeetingConsentPanel.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(meetings): add MeetingConsentPanel" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 5: `AppState` wiring + Settings tab

**Files:**
- Modify: `omwhisper-native/AppState.swift`
- Create: `omwhisper-native/UI/MeetingsSettingsView.swift`
- Modify: `omwhisper-native/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `MeetingWatcher`, `MeetingRecorder`, `MeetingConsentPanel` (Tasks 2-4).
- Produces: `AppState.meetingsEnabled`.

No new tests — pure wiring calling already-tested/live-verified pieces, matching Task 3 (S2) and Task 3 (M3)'s precedent.

- [ ] **Step 1: Add the `meetingsEnabled` setting, right after `autoDeleteAfterDays`**

Find:
```swift
    /// nil = off. 0 doubles as "unset" since UserDefaults.integer(forKey:) already
    /// returns 0 for a missing key — no separate "has a value" bookkeeping needed.
    var autoDeleteAfterDays: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: SettingsKeys.autoDeleteAfterDays)
            return value == 0 ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: SettingsKeys.autoDeleteAfterDays) }
    }

    // MARK: Core loop collaborators
```

Replace with:
```swift
    /// nil = off. 0 doubles as "unset" since UserDefaults.integer(forKey:) already
    /// returns 0 for a missing key — no separate "has a value" bookkeeping needed.
    var autoDeleteAfterDays: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: SettingsKeys.autoDeleteAfterDays)
            return value == 0 ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: SettingsKeys.autoDeleteAfterDays) }
    }
    /// Off by default — every Smriti-derived feature ships off by default.
    /// MeetingWatcher isn't started at all unless this is on: no poll timer,
    /// no consent prompts, no recording capability for a user who never opens
    /// this tab. access(keyPath:)/withMutation(keyPath:) needed for the same
    /// reason as the M3 polish settings — a plain get/set computed property
    /// over UserDefaults never fires an Observation change notification on
    /// its own, and this Toggle needs to reflect external state changes.
    var meetingsEnabled: Bool {
        get {
            access(keyPath: \.meetingsEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.meetingsEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.meetingsEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.meetingsEnabled)
            }
            if newValue {
                meetingWatcher.isSuppressed = { [weak self] in self?.dictation != .idle }
                meetingWatcher.onStartRecording = { [weak self] appName in
                    Task {
                        do {
                            try await self?.meetingRecorder.start(appName: appName)
                        } catch {
                            log.error("meeting recording failed to start: \(error)")
                            self?.meetingWatcher.failedToStartRecording()
                        }
                    }
                }
                meetingWatcher.onStopRecording = { [weak self] in
                    Task { await self?.meetingRecorder.stop() }
                }
                meetingWatcher.onShowConsentPanel = { [weak self] appName, respond in
                    self?.meetingConsentPanel.show(appName: appName, onDecision: respond)
                }
                meetingWatcher.start()
            } else {
                meetingWatcher.stop()
            }
        }
    }

    // MARK: Core loop collaborators
```

- [ ] **Step 2: Add the `SettingsKeys` entry**

Find:
```swift
    static let hasImportedLegacyHistory = "hasImportedLegacyHistory"
```

Replace with:
```swift
    static let hasImportedLegacyHistory = "hasImportedLegacyHistory"
    static let meetingsEnabled = "meetingsEnabled"
```

- [ ] **Step 3: Add the collaborators, right after `polishSelectedTextHotkey`**

Find:
```swift
    /// kVK_ANSI_P — Polish Selected Text: copy the frontmost app's selection,
    /// polish it, paste it back in place. Not a dictation session — dictation
    /// stays .idle throughout; overlayPhase alone drives the brief pill.
    @ObservationIgnored private lazy var polishSelectedTextHotkey = GlobalHotkey(
        keyCode: 35,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginPolishSelectedText()
    }
```

Replace with:
```swift
    /// kVK_ANSI_P — Polish Selected Text: copy the frontmost app's selection,
    /// polish it, paste it back in place. Not a dictation session — dictation
    /// stays .idle throughout; overlayPhase alone drives the brief pill.
    @ObservationIgnored private lazy var polishSelectedTextHotkey = GlobalHotkey(
        keyCode: 35,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginPolishSelectedText()
    }
    @ObservationIgnored private let meetingWatcher = MeetingWatcher()
    @ObservationIgnored private let meetingRecorder = MeetingRecorder()
    @ObservationIgnored private let meetingConsentPanel = MeetingConsentPanel()
```

- [ ] **Step 4: Start the watcher on launch if already enabled from a previous session**

Find:
```swift
        if !isRunningUnderTests {
            hotkey.start()
            pushToTalk.start()
            smartDictationHotkey.start()
            polishSelectedTextHotkey.start()
```

Replace with:
```swift
        if !isRunningUnderTests {
            hotkey.start()
            pushToTalk.start()
            smartDictationHotkey.start()
            polishSelectedTextHotkey.start()
            if meetingsEnabled { meetingsEnabled = true }  // re-runs the setter's wiring/start path
```

- [ ] **Step 5: Create `MeetingsSettingsView.swift`**

```swift
//
//  MeetingsSettingsView.swift
//  OmWhisper
//
//  Meeting detection/consent/recording settings (S3 sub-project 1). See
//  docs/superpowers/specs/2026-07-07-s3-meeting-detection-consent-recording-design.md.
//

import SwiftUI

struct MeetingsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section {
                Toggle("Detect and record meetings", isOn: $state.meetingsEnabled)
                Text("When a recognized call app is active, you'll be asked for consent before anything is recorded — a 10-second countdown, and no response means nothing is recorded. Recordings stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    MeetingsSettingsView().environment(AppState())
}
```

- [ ] **Step 6: Add the Meetings tab to `SettingsView.swift`**

Find:
```swift
            Tab("AI", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("About", systemImage: "info.circle") {
```

Replace with:
```swift
            Tab("AI", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("Meetings", systemImage: "person.2.wave.2") {
                MeetingsSettingsView()
            }
            Tab("About", systemImage: "info.circle") {
```

- [ ] **Step 7: Build and run full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 96/96 (no new tests this task).

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/UI/MeetingsSettingsView.swift omwhisper-native/UI/SettingsView.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(meetings): wire MeetingWatcher into AppState + add Settings tab" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 6: Debug self-test diagnostic

**Files:**
- Create: `omwhisper-native/Meetings/MeetingSelfTest.swift`
- Modify: `omwhisper-native/OmWhisperApp.swift`

**Interfaces:**
- Consumes: `MeetingRecorder` (Task 3).
- Produces: `MeetingSelfTest.run() async -> String` (a human-readable verdict report).

No tests — this *is* the manual diagnostic tool, matching smriti's own convention of it being outside the automated suite. `#if DEBUG`-gated; never compiled into release builds.

- [ ] **Step 1: Create `MeetingSelfTest.swift`**

```swift
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

nonisolated enum MeetingSelfTest {
    static func run() async -> String {
        let recorder = MeetingRecorder()
        do {
            try await recorder.start(appName: "SelfTest")
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
```

- [ ] **Step 2: Add the debug menu item to `OmWhisperApp.swift`**

Find:
```swift
        addItem(to: menu, title: "Settings…", action: #selector(openSettings), key: ",")
        addItem(to: menu, title: "History…", action: #selector(openHistory))
        addItem(to: menu, title: "Check for Updates…", action: #selector(checkForUpdates))
            .isEnabled = updaterController.updater.canCheckForUpdates
        addItem(to: menu, title: "Quit OmWhisper", action: #selector(quit), key: "q")
```

Replace with:
```swift
        addItem(to: menu, title: "Settings…", action: #selector(openSettings), key: ",")
        addItem(to: menu, title: "History…", action: #selector(openHistory))
        addItem(to: menu, title: "Check for Updates…", action: #selector(checkForUpdates))
            .isEnabled = updaterController.updater.canCheckForUpdates
        #if DEBUG
        menu.addItem(.separator())
        addItem(to: menu, title: "Meeting Self-Test…", action: #selector(runMeetingSelfTest))
        #endif
        addItem(to: menu, title: "Quit OmWhisper", action: #selector(quit), key: "q")
```

- [ ] **Step 3: Add the action, right after the existing `checkForUpdates` action**

Find:
```swift
    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
```

Replace with:
```swift
    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    #if DEBUG
    @objc private func runMeetingSelfTest() {
        Task {
            let report = await MeetingSelfTest.run()
            let alert = NSAlert()
            alert.messageText = "Meeting Self-Test"
            alert.informativeText = report
            alert.runModal()
        }
    }
    #endif
```

- [ ] **Step 4: Build and run full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: PASS, 96/96.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingSelfTest.swift omwhisper-native/OmWhisperApp.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(meetings): add debug self-test diagnostic" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 7: Live verification + progress tracker update

**Files:**
- Modify: `CLAUDE.md`

No code changes beyond the doc update — this task is live verification of Tasks 1-6 together, on real hardware.

- [ ] **Step 1: Full clean build + test**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' clean build test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`, 96/96 tests passing.

- [ ] **Step 2: Live-verify permissions + self-test**

Launch the built app. Enable Settings → Meetings. Run the debug "Meeting Self-Test…" menu item — grant Screen Recording when prompted (relaunch the app afterward if the grant doesn't take effect immediately, a known OS quirk noted in the design spec), speak during the 5s window, and confirm both tracks report `OK ✓` (not `SILENT ✗`).

- [ ] **Step 3: Live-verify the consent flow with a real call**

Start a real Zoom/Meet/FaceTime call (or a browser tab to meet.google.com). Confirm the consent panel appears within a few seconds of the mic going active, showing the correct app name. Test **both** paths: (a) let it time out — confirm no `.caf` files are created; (b) click Record — confirm `them.caf`/`me.caf` are created and both contain real audio when the call ends (mic idle for 8s).

- [ ] **Step 4: Live-verify suppression**

Start a normal dictation session (Cmd+Shift+V) — confirm the consent panel never appears, even though the mic is active.

- [ ] **Step 5: Check for stray processes**

Run: `ps aux | grep "OmWhisper.app/Contents/MacOS/OmWhisper" | grep -v grep`
Expected: no output after quitting — clean up with `pkill -f "OmWhisper.app/Contents/MacOS/OmWhisper"` if anything lingers.

- [ ] **Step 6: Update `CLAUDE.md`'s Progress Tracker**

Update the S1–S6 row (or add detail to it) describing what shipped: `CallDetection`, `MeetingWatcher`, `MeetingRecorder` (ScreenCaptureKit dual-track), `MeetingConsentPanel`, the debug self-test, and the Meetings Settings tab — plus the actual observed behavior from Steps 2-4 (self-test verdicts, real-call consent flow, suppression). Note transcription/summary/UI (sub-project 2) remain a separate, not-yet-started plan.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "$(printf '%s\n\n%s' "📝 docs: mark S3 sub-project 1 (meeting detection/consent/recording) shipped" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```
