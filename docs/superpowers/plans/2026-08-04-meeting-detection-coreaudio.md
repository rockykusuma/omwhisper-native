# Meeting Detection via CoreAudio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect meeting calls by asking CoreAudio which process is capturing microphone input, replacing a window-title heuristic that missed a real 30-minute Teams call.

**Architecture:** A new `Meetings/AudioProcesses.swift` owns the CoreAudio property reads and nothing else. `CallDetection` keeps the policy — prefix matching (the capturing process is usually a helper), own-bundle exclusion, a meeting-URL gate for browsers, and resolving the owning app's pid. `MeetingWatcher`'s state machine keys on that detection instead of on the microphone, which also fixes auto-stop, and its sweep moves off MainActor because the browser URL check walks an accessibility tree.

**Tech Stack:** Swift 6, CoreAudio (`AudioHardware.h` process objects), Accessibility API, Swift Testing.

## Global Constraints

- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: anything meant to run off the main thread needs an explicit `nonisolated` marker. A missing marker shows up as a real build error, not a warning.
- Build and test with `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test`. The scheme is `omwhisper-native`; the product is `OmWhisper`.
- Debug builds are **OmWhisper-Dev** (`com.omwhisper.mac.dev`). Both bundle IDs must be excluded from detection.
- Test suite is at 476 tests in 68 suites before this work. Every task ends green.
- Xcode groups are file-system-synchronized: creating a `.swift` file on disk is enough. Never hand-edit `project.pbxproj` to add files.
- SourceKit in this project reports false "cannot find X in scope" errors. Only a real `xcodebuild` result counts.
- No new dependencies. Everything used here is in the macOS SDK or already in the app.

### Values measured live on 2026-08-03, against a real Teams call — do not re-derive

- The mic was held by `com.microsoft.teams2.modulehost` (pid 2500); the windows were on `com.microsoft.teams2` (pid 2221).
- `com.omwhisper.mac.dev` reported `input=YES` at the same time as Teams.
- Teams' window title was `D-WHAS | Microsoft Teams` — no call-word in it.
- CoreAudio sweep cost: 211ms first call, ~12ms steady state over 36 processes. No permission needed; every error code was 0.

---

### Task 1: AudioProcesses + a diagnostics flag to prove it works

**Files:**
- Create: `omwhisper-native/Meetings/AudioProcesses.swift`
- Create: `omwhisper-native/Meetings/MeetingDetectionDiagnostics.swift`
- Modify: `omwhisper-native/main.swift:14-32`

**Interfaces:**
- Consumes: nothing.
- Produces: `AudioProcesses.capturingInput() -> [AudioProcesses.AudioProcess]`, where `AudioProcess` is `struct { let bundleID: String; let pid: pid_t }`, `Equatable`, `Sendable`.

There is no unit test for this task. A test asserting "some process is capturing input" passes on a silent CI runner and proves nothing — it is a check that cannot fail. The evidence channel is the diagnostics flag, run against a real call, exactly as `MeetingDiagnostics` and `MeetingAIDiagnostics` already do for their pipelines.

- [ ] **Step 1: Create `AudioProcesses.swift`**

```swift
//
//  AudioProcesses.swift
//  OmWhisper
//
//  Which processes are capturing microphone input right now, from CoreAudio's
//  process objects. This is the meeting-detection signal: direct evidence that
//  an app has the mic open, rather than an inference from a window title.
//
//  Needs no permission -- probed live 2026-08-03 from a process holding neither
//  Accessibility nor Screen Recording, and every property read returned 0.
//  Costs ~12ms steady state over 36 processes; the FIRST call costs ~211ms
//  establishing the connection to coreaudiod, which is why the caller runs this
//  off MainActor.
//
//  Reads only. The tap-and-record side of this same CoreAudio process family
//  lives in MeetingRecorder.
//

import CoreAudio
import Foundation

nonisolated enum AudioProcesses {
    struct AudioProcess: Equatable, Sendable {
        /// The bundle ID of the capturing process, which is often a HELPER --
        /// com.microsoft.teams2.modulehost, not com.microsoft.teams2. Callers
        /// must match by prefix, never exact equality.
        let bundleID: String
        let pid: pid_t
    }

    /// Processes capturing microphone input right now. Empty when any property
    /// read fails: a detection miss, never a crash. The caller treats that
    /// identically to "no call", and manual recording still works.
    static func capturingInput() -> [AudioProcess] {
        processObjects().compactMap { object in
            guard isRunningInput(object), let bundleID = bundleID(object) else { return nil }
            guard let pid = pid(object) else { return nil }
            return AudioProcess(bundleID: bundleID, pid: pid)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
            size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    /// Unmanaged<CFString>? rather than CFString?: passing `&value` where the
    /// variable holds an object reference is a real Swift 6 warning
    /// ("forming UnsafeMutableRawPointer to a variable of type Optional<CFString>").
    /// Unmanaged is a pointer-wrapping struct, so this form compiles clean.
    private static func bundleID(_ object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var out: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out) == noErr,
              let value = out?.takeRetainedValue() as String?,
              !value.isEmpty else { return nil }
        return value
    }

    private static func pid(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }
}
```

- [ ] **Step 2: Create `MeetingDetectionDiagnostics.swift`**

`CallDetection.callAppBundleID`, `isOwnProcess` and the rewritten `activeCall()` arrive in Tasks 2 and 3. Write only the part that exists now; Step 5 of Task 3 extends this file.

```swift
//
//  MeetingDetectionDiagnostics.swift
//  OmWhisper
//
//  DEBUG-only: prints what meeting detection actually sees. Exists because a
//  unit test asserting "something is capturing input" passes on a silent CI
//  runner and proves nothing -- the only real check is running this during a
//  real call. Same stdout-as-evidence-channel convention as MeetingDiagnostics
//  and MeetingAIDiagnostics.
//
//  Run: OmWhisper-Dev.app/Contents/MacOS/OmWhisper-Dev --diagnose-meeting-detection
//

#if DEBUG
import Foundation

nonisolated enum MeetingDetectionDiagnostics {
    static func run() {
        print("=== meeting detection ===")
        let processes = AudioProcesses.capturingInput()
        print("processes capturing microphone input: \(processes.count)")
        for process in processes {
            print("  \(process.bundleID) pid=\(process.pid)")
        }
        if processes.isEmpty {
            print("  <none> — nothing has the mic open right now")
        }
    }
}
#endif
```

- [ ] **Step 3: Wire the flag in `main.swift`**

Insert immediately after `#if DEBUG` on line 14, before the existing `--diagnose-meeting` block. `firstIndex(of:)` is an exact string match, so `--diagnose-meeting-detection` and `--diagnose-meeting` cannot collide, but ordering it first keeps the reading order obvious.

```swift
if CommandLine.arguments.contains("--diagnose-meeting-detection") {
    MeetingDetectionDiagnostics.run()
    exit(0)
}
```

- [ ] **Step 4: Build and run the suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 476 tests still passing. No new tests in this task.

- [ ] **Step 5: Run the diagnostics against reality**

```bash
BIN=$(xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
"$BIN/OmWhisper-Dev.app/Contents/MacOS/OmWhisper-Dev" --diagnose-meeting-detection
```

Expected with nothing capturing: `processes capturing microphone input: 0` and the `<none>` line.
Expected while any app holds the mic (start a Photo Booth or Voice Memos recording if no call is available): that app's bundle ID appears with a non-zero pid.

**This step must actually be run.** If it prints 0 while something is demonstrably recording, the property reads are wrong and the rest of the plan is built on sand.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Meetings/AudioProcesses.swift \
        omwhisper-native/Meetings/MeetingDetectionDiagnostics.swift \
        omwhisper-native/main.swift
git commit -m "✨ feat(meetings): read which process is capturing mic input

CoreAudio names the process holding the microphone -- direct evidence of a
call, where the current window-title heuristic is a guess. Needs no
permission. Paired with --diagnose-meeting-detection because a unit test
asserting 'something is capturing input' passes on a silent CI runner."
```

---

### Task 2: Detection policy — prefix matching, own-bundle exclusion, owning pid

**Files:**
- Modify: `omwhisper-native/Meetings/CallDetection.swift:17-46` (types, `callerApps`, `recognizedApp`) and `:116-124` (`activeCall`)
- Modify: `omwhisper-nativeTests/CallDetectionTests.swift:5-26` (delete the `recognizedApp` tests, add the new ones)

**Interfaces:**
- Consumes: `AudioProcesses.capturingInput() -> [AudioProcesses.AudioProcess]` from Task 1.
- Produces:
  - `CallDetection.matchesBundle(_ bundleID: String, base: String) -> Bool`
  - `CallDetection.callAppBundleID(forAudioBundleID: String) -> String?` — returns the **base** bundle ID
  - `CallDetection.isOwnProcess(_ bundleID: String) -> Bool`
  - `CallDetection.owningPID(baseBundleID: String) -> pid_t?`
  - `CallDetection.activeCall() -> (name: String, pid: pid_t)?` — signature unchanged, implementation replaced

`hasActiveCallWindow` still has a caller in `MeetingWatcher.tick()` and is deleted in Task 4, not here. `hasCallLikeTitle` and `callLikeWords` are **kept**: `callWindowTitle` uses them at line 96 to prefer a call-like window when naming a meeting. They stop being a detection signal and remain a title-selection one.

- [ ] **Step 1: Write the failing tests**

Replace lines 5-26 of `omwhisper-nativeTests/CallDetectionTests.swift` (the three `recognizedApp` tests — `zoomIsRecognizedWithoutVerification`, `slackNeedsFrontmostOrCallLikeTitle`, `unrecognizedBundleIDReturnsNil`) with:

```swift
    @Test("the helper process that actually holds the mic matches its parent app")
    func helperBundleIDsMatchTheirApp() {
        // Observed live 2026-08-03 during a real Teams call:
        // com.microsoft.teams2.modulehost held the mic while
        // com.microsoft.teams2 held the windows. An exact-match implementation
        // misses Teams -- which is the original bug wearing a new costume.
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.microsoft.teams2.modulehost")
                == "com.microsoft.teams2")
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.google.Chrome.helper")
                == "com.google.Chrome")
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.microsoft.teams2")
                == "com.microsoft.teams2")
    }

    @Test("a bundle ID that merely starts with a known one does not match")
    func siblingBundleIDsDoNotMatch() {
        // com.microsoft.teams2 must not match the com.microsoft.teams entry:
        // matching requires a dot boundary, not a bare string prefix.
        #expect(CallDetection.matchesBundle("com.microsoft.teams2", base: "com.microsoft.teams") == false)
        #expect(CallDetection.matchesBundle("com.microsoft.teams2.modulehost", base: "com.microsoft.teams") == false)
        #expect(CallDetection.matchesBundle("com.microsoft.teams.helper", base: "com.microsoft.teams"))
        #expect(CallDetection.matchesBundle("com.microsoft.teams", base: "com.microsoft.teams"))
    }

    @Test("our own audio process is never a call")
    func ownProcessIsNotACall() {
        // The live probe showed com.omwhisper.mac.dev input=YES beside Teams:
        // the recorder holds the mic for the whole meeting and dictation holds
        // it too, so without this the app detects itself as a call.
        #expect(CallDetection.isOwnProcess("com.omwhisper.mac"))
        #expect(CallDetection.isOwnProcess("com.omwhisper.mac.dev"))
        #expect(CallDetection.isOwnProcess("com.microsoft.teams2") == false)
    }

    @Test("apps that merely use the mic are not calls")
    func unknownBundleIDIsNotACall() {
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.apple.Music") == nil)
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.spotify.client") == nil)
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.apple.VoiceMemos") == nil)
    }

    @Test("browsers are matched by bundle, then gated on the page")
    func browsersAreMatchedByBundle() {
        // Bundle matching admits the browser; Task 3's URL check is what
        // decides whether it is actually a call.
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "company.thebrowser.Browser")
                == "company.thebrowser.Browser")
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.apple.Safari") == "com.apple.Safari")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)" | head`
Expected: compile errors — `type 'CallDetection' has no member 'callAppBundleID'`, `'matchesBundle'`, `'isOwnProcess'`.

- [ ] **Step 3: Rewrite the types and matching in `CallDetection.swift`**

Replace lines 17-46 (from `nonisolated enum CallDetection {` through the closing brace of `recognizedApp`) with:

```swift
nonisolated enum CallDetection {
    /// Base bundle ID -> display name. The process that actually holds the mic
    /// is frequently a helper below one of these, so every lookup goes through
    /// `matchesBundle`, never a dictionary subscript.
    ///
    /// No verification tier any more: an app in this list capturing microphone
    /// input IS the evidence. The old two-tier scheme existed only to decide
    /// whether to consult the window title, and the title heuristic is what
    /// missed a real 30-minute Teams call on 2026-08-03.
    static let callerApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.apple.FaceTime": "FaceTime",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "Cisco-Systems.Spark": "Webex",
    ]

    /// Our own bundle. Prefix-matched, so the Debug build
    /// (com.omwhisper.mac.dev) is covered by the same entry.
    static let ownBundleID = "com.omwhisper.mac"

    static let meetingDomains = [
        "meet.google", "zoom.us", "teams.microsoft", "whereby.com", "web.whatsapp",
    ]

    private static let callLikeWords = ["call", "calling", "ringing", "meeting", "huddle"]

    /// Exact match, or a dotted child (`base.helper`). The dot is load-bearing:
    /// a bare `hasPrefix` would make com.microsoft.teams2 match the
    /// com.microsoft.teams entry, and in general would match any app whose ID
    /// merely starts with another's.
    static func matchesBundle(_ bundleID: String, base: String) -> Bool {
        bundleID == base || bundleID.hasPrefix(base + ".")
    }

    /// The BASE bundle ID of the call app this audio process belongs to, or nil
    /// if it is not one we recognise. Browsers are admitted here and gated on
    /// the page URL by `activeCall` -- any WebRTC site opens the mic.
    static func callAppBundleID(forAudioBundleID bundleID: String) -> String? {
        if let base = callerApps.keys.first(where: { matchesBundle(bundleID, base: $0) }) {
            return base
        }
        return BrowserURL.browserBundleIds.first { matchesBundle(bundleID, base: $0) }
    }

    /// True for OmWhisper's own audio process. The recorder holds the mic for a
    /// whole meeting and dictation holds it too, so without this the app
    /// detects itself -- the live probe showed com.omwhisper.mac.dev
    /// input=YES beside Teams.
    static func isOwnProcess(_ bundleID: String) -> Bool {
        matchesBundle(bundleID, base: ownBundleID)
    }
```

Do not add a closing brace — this replaces the opening of the enum and its first members; the rest of the file follows unchanged.

- [ ] **Step 4: Rewrite `activeCall()`**

Replace lines 116-124 (the whole existing `activeCall()`, including its doc comment) with:

```swift
    /// The call currently capturing microphone input, as (display name, owning
    /// app pid). Nil when nothing recognised has the mic open.
    ///
    /// Replaces an AX window-title walk: on 2026-08-03 a real Teams call ran
    /// for over half an hour titled "D-WHAS | Microsoft Teams", which contains
    /// none of the call words, so detection returned nil on every poll.
    static func activeCall() -> (name: String, pid: pid_t)? {
        for process in AudioProcesses.capturingInput() {
            guard !isOwnProcess(process.bundleID),
                  let base = callAppBundleID(forAudioBundleID: process.bundleID) else { continue }
            let pid = owningPID(baseBundleID: base) ?? process.pid
            let name = callerApps[base]
                ?? NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? base
            return (name, pid)
        }
        return nil
    }

    /// The pid of the app that OWNS this bundle ID, not the helper that happens
    /// to hold the mic. Teams captured on com.microsoft.teams2.modulehost
    /// (pid 2500) while its windows lived on com.microsoft.teams2 (pid 2221) --
    /// without this, callWindowTitle finds no windows and every auto-detected
    /// meeting falls back to being titled by app name.
    static func owningPID(baseBundleID: String) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == baseBundleID }?
            .processIdentifier
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. Test count drops by 3 (the deleted `recognizedApp` tests) and rises by 5, so 478 in 68 suites.

If the build fails with "cannot find 'BrowserURL' in scope", it is SourceKit noise — re-run the real build. `BrowserURL` is in the same target at `omwhisper-native/Memory/BrowserURL.swift`.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Meetings/CallDetection.swift omwhisper-nativeTests/CallDetectionTests.swift
git commit -m "🐛 fix(meetings): detect calls from the mic, not the window title

activeCall() now asks which process is capturing input. Matching is by
PREFIX with a dot boundary -- the capturing process is a helper
(com.microsoft.teams2.modulehost), and a bare prefix would make
com.microsoft.teams2 match the com.microsoft.teams entry.

Resolves the OWNING app's pid: the helper has no windows, so passing its
pid to callWindowTitle would leave every auto-detected meeting titled by
app name. Excludes our own bundle, .dev included -- the recorder holds
the mic for a whole meeting.

Deletes recognizedApp and the verification tiers. recognizedApp held the
escape hatch that would have caught this call and nothing ever called it;
its three tests asserted behaviour production never had."
```

---

### Task 3: Browsers count only with a meeting URL

**Files:**
- Modify: `omwhisper-native/Meetings/CallDetection.swift` (the `activeCall()` written in Task 2, plus one new function)
- Modify: `omwhisper-native/Meetings/MeetingDetectionDiagnostics.swift`
- Modify: `omwhisper-nativeTests/CallDetectionTests.swift`

**Interfaces:**
- Consumes: `CallDetection.callAppBundleID`, `isOwnProcess`, `owningPID` from Task 2; `BrowserURL.isBrowser(_:) -> Bool` and `BrowserURL.url(bundleId:window:) -> String?` from `omwhisper-native/Memory/BrowserURL.swift`; `ScreenContextReader.copyAttribute(_:_:) -> AnyObject?` from `omwhisper-native/Context/ScreenContextReader.swift`.
- Produces: `CallDetection.hasMeetingPage(pid: pid_t, bundleID: String) -> Bool`.

This gives `isMeetingURL`, `meetingDomains` and `BrowserURL` their first production callers — until now they were reachable only from tests.

- [ ] **Step 1: Write the failing test**

Add to `omwhisper-nativeTests/CallDetectionTests.swift`:

```swift
    @Test("an ordinary browser page is not a meeting")
    func ordinaryPagesAreNotMeetings() {
        // The control for browser detection. Any WebRTC page opens the mic, so
        // "a browser is capturing input" cannot mean "a call" on its own --
        // without this the app would prompt during a YouTube video.
        #expect(!CallDetection.isMeetingURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(!CallDetection.isMeetingURL("https://github.com/rockykusuma/omwhisper-native"))
        #expect(!CallDetection.isMeetingURL(nil))
        #expect(CallDetection.isMeetingURL("https://meet.google.com/abc-defg-hij"))
        #expect(CallDetection.isMeetingURL("https://teams.microsoft.com/l/meetup-join/xyz"))
    }
```

- [ ] **Step 2: Run it to confirm the current state**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: PASS — `isMeetingURL` already behaves correctly; this test pins the rule the next step depends on. The behaviour that is genuinely missing is the *gate*, which has no unit-testable form (it needs a live AX tree) and is covered by the live check in Task 6.

- [ ] **Step 3: Add `hasMeetingPage` to `CallDetection.swift`**

Place it immediately after `owningPID`:

```swift
    /// A browser holding the mic means nothing on its own -- any WebRTC page
    /// does it -- so it counts as a call only when the focused window resolves
    /// to a meeting URL. Silence is the safe direction here: a false positive
    /// prompts during ordinary browsing, a false negative costs one
    /// auto-started recording and the Record button still works.
    static func hasMeetingPage(pid: pid_t, bundleID: String) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        guard let window = ScreenContextReader.copyAttribute(appElement, kAXFocusedWindowAttribute)
        else { return false }
        // Not `as?`: the compiler rejects that as dead code ("conditional
        // downcast to CoreFoundation type 'AXUIElement' will always succeed").
        // Same construct and same reason as ScreenContextReader.swift:66.
        let windowElement = window as! AXUIElement
        return isMeetingURL(BrowserURL.url(bundleId: bundleID, window: windowElement))
    }
```

- [ ] **Step 4: Add the gate to `activeCall()`**

In the `for` loop written in Task 2, insert the browser check after `let pid = ...` and before `let name = ...`:

```swift
            if BrowserURL.isBrowser(base), !hasMeetingPage(pid: pid, bundleID: base) { continue }
```

- [ ] **Step 5: Extend the diagnostics to print the verdict**

Replace the body of `MeetingDetectionDiagnostics.run()` with:

```swift
    static func run() {
        print("=== meeting detection ===")
        let processes = AudioProcesses.capturingInput()
        print("processes capturing microphone input: \(processes.count)")
        for process in processes {
            let base = CallDetection.callAppBundleID(forAudioBundleID: process.bundleID)
            let own = CallDetection.isOwnProcess(process.bundleID)
            print("  \(process.bundleID) pid=\(process.pid) own=\(own) callApp=\(base ?? "-")")
            if let base, BrowserURL.isBrowser(base) {
                let pid = CallDetection.owningPID(baseBundleID: base) ?? process.pid
                print("    browser: meetingPage=\(CallDetection.hasMeetingPage(pid: pid, bundleID: base))")
            }
        }
        if processes.isEmpty {
            print("  <none> — nothing has the mic open right now")
        }
        if let call = CallDetection.activeCall() {
            print("activeCall -> \(call.name) pid=\(call.pid)")
            print("  callWindowTitle -> \(CallDetection.callWindowTitle(pid: call.pid) ?? "<none>")")
        } else {
            print("activeCall -> nil")
        }
    }
```

- [ ] **Step 6: Build, test, and run the diagnostics**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 479 tests.

Then run the flag as in Task 1 Step 5. With nothing capturing, expect `activeCall -> nil`.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/CallDetection.swift \
        omwhisper-native/Meetings/MeetingDetectionDiagnostics.swift \
        omwhisper-nativeTests/CallDetectionTests.swift
git commit -m "✨ feat(meetings): a browser is a call only on a meeting URL

Any WebRTC page opens the mic, so a browser capturing input cannot mean a
call on its own -- the YouTube case is the control. Reads the focused
window's URL through BrowserURL, giving isMeetingURL, meetingDomains and
BrowserURL their first production callers; all three were test-only, so
browser meetings were never detected at all."
```

---

### Task 4: The state machine keys on the call, not the microphone

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingWatcher.swift:17-30` (states and timings), `:34-91` (stored state and `nextState`), `:131-182` (`tick`), `:184-208` (delete `microphoneInUse`)
- Modify: `omwhisper-native/Meetings/CallDetection.swift:63-76` (delete `hasActiveCallWindow`)
- Modify: `omwhisper-nativeTests/MeetingWatcherLogicTests.swift` (full rewrite)

**Interfaces:**
- Consumes: `CallDetection.activeCall() -> (name: String, pid: pid_t)?` from Tasks 2-3.
- Produces:
  - `MeetingWatcherState` with cases `.idle`, `.detecting`, `.prompting(appName:)`, `.recording(appName:)`, `.declined`, `.awaitingRetry(appName:)`
  - `MeetingWatcherTiming.retryCooldown: Duration`
  - `MeetingWatcher.nextState(current:detected:detectedDuration:callGone:goneDuration:retryWait:) -> MeetingWatcherState`
  - `MeetingWatcher.DetectedCall` — `struct { let name: String; let pid: pid_t }`, `Equatable`, `Sendable`

`.micActive` is renamed `.detecting`: it no longer means "some microphone is on" but "a recognised call app is capturing input". The consent-callback type changes in Task 6, not here — this task keeps `(Bool) -> Void` so the tree stays green, and routes `false` to `.declined` exactly as today.

- [ ] **Step 1: Write the failing tests**

Replace the whole contents of `omwhisper-nativeTests/MeetingWatcherLogicTests.swift` with:

```swift
import Testing
@testable import OmWhisper

struct MeetingWatcherLogicTests {
    let start = MeetingWatcherTiming.startDebounce
    let end = MeetingWatcherTiming.endDebounce
    let cooldown = MeetingWatcherTiming.retryCooldown

    private func next(
        _ current: MeetingWatcherState,
        detected: String? = nil,
        detectedDuration: Duration = .zero,
        callGone: Bool = false,
        goneDuration: Duration = .zero,
        retryWait: Duration = .zero
    ) -> MeetingWatcherState {
        MeetingWatcher.nextState(current: current, detected: detected,
                                 detectedDuration: detectedDuration, callGone: callGone,
                                 goneDuration: goneDuration, retryWait: retryWait)
    }

    @Test("a detected call moves out of idle")
    func idleToDetecting() {
        #expect(next(.idle, detected: "Teams") == .detecting)
        #expect(next(.idle) == .idle)
    }

    @Test("prompting waits for the start debounce")
    func detectingPromptsAfterDebounce() {
        #expect(next(.detecting, detected: "Teams", detectedDuration: .seconds(1)) == .detecting)
        #expect(next(.detecting, detected: "Teams", detectedDuration: start) == .prompting(appName: "Teams"))
    }

    @Test("a call that goes away before the debounce prompts for nothing")
    func detectingGoesIdleWhenCallEnds() {
        #expect(next(.detecting, detectedDuration: .seconds(1)) == .idle)
    }

    @Test("a call that is never recognized does NOT latch to declined")
    func undetectedCallDoesNotLatch() {
        // The 2026-08-03 bug: reaching the debounce with no recognized call
        // used to latch .declined for the whole mic session, so a detection
        // MISS was recorded as the user refusing. There is nothing to decline
        // if nothing was ever detected -- it simply returns to idle and keeps
        // watching.
        #expect(next(.detecting, detected: nil, detectedDuration: start) == .idle)
    }

    @Test("recording continues while the call still holds the mic")
    func recordingHoldsWhileCallActive() {
        #expect(next(.recording(appName: "Teams"), detected: "Teams", goneDuration: end)
                == .recording(appName: "Teams"))
    }

    @Test("recording stops once the call releases the mic past the debounce")
    func recordingStopsWhenCallGone() {
        // This has never worked for Teams: the old stop path required a
        // call-like window title to have been seen first, and
        // "D-WHAS | Microsoft Teams" has no call word in it.
        #expect(next(.recording(appName: "Teams"), callGone: true, goneDuration: end) == .idle)
        #expect(next(.recording(appName: "Teams"), callGone: true, goneDuration: .seconds(1))
                == .recording(appName: "Teams"))
    }

    @Test("a manual recording with no call detected never auto-stops")
    func manualRecordingDoesNotAutoStop() {
        // Recording an app that is not a recognized call -- which is exactly
        // what happened on 2026-08-03 -- has no detection to lose. Without
        // callGone gating this, detected == nil on the first tick would stop
        // the recording after 8 seconds.
        #expect(next(.recording(appName: "Recording"), callGone: false, goneDuration: .seconds(600))
                == .recording(appName: "Recording"))
    }

    @Test("a prompt is abandoned if the call ends first")
    func promptingCancelsWhenCallEnds() {
        #expect(next(.prompting(appName: "Teams")) == .idle)
        #expect(next(.prompting(appName: "Teams"), detected: "Teams") == .prompting(appName: "Teams"))
    }

    @Test("an explicit decline holds for the rest of the call")
    func declinedLatchesWhileCallContinues() {
        #expect(next(.declined, detected: "Teams", detectedDuration: .seconds(300)) == .declined)
        #expect(next(.declined) == .idle)
    }

    @Test("a timed-out prompt is asked again after the cooldown")
    func awaitingRetryPromptsAgain() {
        #expect(next(.awaitingRetry(appName: "Teams"), detected: "Teams", retryWait: .seconds(5))
                == .awaitingRetry(appName: "Teams"))
        #expect(next(.awaitingRetry(appName: "Teams"), detected: "Teams", retryWait: cooldown)
                == .prompting(appName: "Teams"))
    }

    @Test("a retry waiting on a call that ended goes quiet")
    func awaitingRetryGoesIdleWhenCallEnds() {
        #expect(next(.awaitingRetry(appName: "Teams"), retryWait: cooldown) == .idle)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head`
Expected: `type 'MeetingWatcherTiming' has no member 'retryCooldown'` and argument-label errors on `nextState`.

- [ ] **Step 3: Update the state and timing types**

Replace lines 17-30 of `MeetingWatcher.swift`:

```swift
nonisolated enum MeetingWatcherState: Equatable {
    case idle
    /// A recognised call app is capturing microphone input, waiting out the
    /// start debounce before prompting.
    case detecting
    case prompting(appName: String)
    case recording(appName: String)
    /// The user said no. Holds for the rest of this call.
    case declined
    /// The prompt timed out unanswered. Asked once more after retryCooldown --
    /// "I never saw it" is not "no".
    case awaitingRetry(appName: String)
}

nonisolated enum MeetingWatcherTiming {
    static let pollInterval: Duration = .seconds(2)
    static let startDebounce: Duration = .seconds(3)
    static let endDebounce: Duration = .seconds(8)
    static let consentTimeout: Duration = .seconds(10)
    /// How long after an unanswered prompt before asking once more. Teams opens
    /// the mic on its pre-join audio screen, so the first prompt often lands
    /// while the user is still choosing a device.
    static let retryCooldown: Duration = .seconds(60)
}
```

- [ ] **Step 4: Replace the stored state and `nextState`**

Replace lines 34-91 (from `private(set) var state` through the end of `nextState`) with:

```swift
    private(set) var state: MeetingWatcherState = .idle
    private var pollTimer: Timer?
    /// When the current call was first detected, for the start debounce.
    private var detectedSince: ContinuousClock.Instant?
    /// When the recorded call stopped capturing input, for the end debounce.
    private var goneSince: ContinuousClock.Instant?
    /// When the prompt timed out, for the retry cooldown.
    private var retrySince: ContinuousClock.Instant?
    /// True once a call has actually been detected during this recording. A
    /// manual recording over an unrecognised app never sets it and therefore
    /// never auto-stops -- Stop is the only way out, as today.
    private var sawCall = false
    /// One retry per call. A second timeout goes quiet.
    private var hasRetried = false
    /// The pid of the app whose call we're recording -- AppState reads it at
    /// record start to capture the window title.
    private(set) var recordingPID: pid_t?
    private var pendingCallPID: pid_t?

    nonisolated struct DetectedCall: Equatable, Sendable {
        let name: String
        let pid: pid_t
    }

    var onStartRecording: (String) -> Void = { _ in }
    var onStopRecording: () -> Void = {}
    var onShowConsentPanel: (String, @escaping (Bool) -> Void) -> Void = { _, respond in respond(false) }

    /// True while `AppState.dictation != .idle` -- suppresses the whole watcher
    /// so our own dictation never triggers a false consent prompt.
    var isSuppressed: () -> Bool = { false }

    /// Pure decision. Side effects (starting the recorder, showing the consent
    /// panel) happen in the caller when it observes a state *change*.
    ///
    /// Keyed on `detected` rather than on the microphone: our own recorder
    /// holds the mic open for the entire meeting, which is why the old stop
    /// path had to fall back to window titles.
    nonisolated static func nextState(
        current: MeetingWatcherState,
        detected: String?,
        detectedDuration: Duration,
        callGone: Bool,
        goneDuration: Duration,
        retryWait: Duration
    ) -> MeetingWatcherState {
        switch current {
        case .idle:
            return detected == nil ? .idle : .detecting
        case .detecting:
            // No .declined branch here. Reaching the debounce without a
            // recognised call means we failed to detect one, not that the user
            // refused -- conflating those is what latched a missed Teams call
            // for its whole duration on 2026-08-03.
            guard let detected else { return .idle }
            return detectedDuration >= MeetingWatcherTiming.startDebounce
                ? .prompting(appName: detected) : .detecting
        case .prompting:
            return detected == nil ? .idle : current
        case .recording:
            // callGone is true only once a call was actually detected during
            // this recording and has since stopped capturing, so a manual
            // recording of an unrecognised app never auto-stops.
            return (callGone && goneDuration >= MeetingWatcherTiming.endDebounce) ? .idle : current
        case .declined:
            return detected == nil ? .idle : current
        case .awaitingRetry(let appName):
            guard detected != nil else { return .idle }
            return retryWait >= MeetingWatcherTiming.retryCooldown
                ? .prompting(appName: appName) : current
        }
    }
```

- [ ] **Step 5: Rewrite `enterRecording`, `markDeclined` and `tick`**

Replace lines 105-182 (from the `failedToStartRecording` doc comment through the end of `tick`) with:

```swift
    /// Called by the caller's onStartRecording closure if MeetingRecorder.start()
    /// throws -- without this, a failed recorder start would leave `state` stuck
    /// showing `.recording` while no audio is actually being captured.
    func failedToStartRecording() {
        state = .idle
    }

    /// Manual start: treat as an ongoing recording so the auto-detect poll won't
    /// re-prompt. Auto-stop arms only if a recognised call is detected now --
    /// recording an unrecognised app is stopped by the user, not by us.
    func enterRecording(appName: String) {
        let call = CallDetection.activeCall()
        recordingPID = call?.pid
        sawCall = call != nil
        goneSince = nil
        state = .recording(appName: appName)
    }

    /// Manual stop: mark declined so the poll won't immediately re-prompt while
    /// the same call is still live. Resets to .idle once the call ends.
    func markDeclined() {
        state = .declined
    }

    private func tick() {
        guard !isSuppressed(), !isDetecting else { return }
        isDetecting = true
        let detect = performDetection
        Task.detached(priority: .utility) { [weak self] in
            let detected = detect()
            await MainActor.run {
                guard let self else { return }
                // Cleared FIRST and unconditionally: clearing only on the happy
                // path would stop detection forever after one failure, silently.
                self.isDetecting = false
                self.apply(detected)
            }
        }
    }

    private func apply(_ detected: DetectedCall?) {
        let now = ContinuousClock.now
        if detected != nil {
            if detectedSince == nil { detectedSince = now }
        } else {
            detectedSince = nil
        }
        let detectedDuration = detectedSince.map { now - $0 } ?? .zero

        var callGone = false
        var goneDuration: Duration = .zero
        if case .recording = state {
            if detected != nil {
                sawCall = true
                goneSince = nil
            } else if sawCall, goneSince == nil {
                goneSince = now
            }
            callGone = sawCall && detected == nil
            goneDuration = goneSince.map { now - $0 } ?? .zero
        }
        let retryWait = retrySince.map { now - $0 } ?? .zero

        let previous = state
        state = Self.nextState(current: previous, detected: detected?.name,
                               detectedDuration: detectedDuration, callGone: callGone,
                               goneDuration: goneDuration, retryWait: retryWait)

        guard state != previous else { return }
        switch state {
        case .prompting(let appName):
            pendingCallPID = detected?.pid
            retrySince = nil
            onShowConsentPanel(appName) { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.recordingPID = self.pendingCallPID
                    self.sawCall = false
                    self.goneSince = nil
                    self.state = .recording(appName: appName)
                    self.onStartRecording(appName)
                } else {
                    self.state = .declined
                }
            }
        case .idle:
            // Reset the per-call bookkeeping whenever we fall back to idle, so
            // the next call starts from a clean slate rather than inheriting a
            // spent retry.
            retrySince = nil
            hasRetried = false
            if previous.isRecording {
                recordingPID = nil
                sawCall = false
                onStopRecording()
            }
        default:
            break
        }
    }
```

- [ ] **Step 6: Add the in-flight flag and the injectable sweep**

Insert immediately after the `pendingCallPID` declaration added in Step 4:

```swift
    /// The detection sweep is handed off MainActor, so a tick arriving while
    /// one is still running would stack concurrent AX walks. Skipped instead.
    private(set) var isDetecting = false

    /// Injected so the tick loop can be exercised without audio hardware or a
    /// real call. Defaults to the real detector.
    nonisolated(unsafe) var performDetection: @Sendable () -> DetectedCall? = {
        CallDetection.activeCall().map { DetectedCall(name: $0.name, pid: $0.pid) }
    }
```

- [ ] **Step 7: Delete the dead microphone and window checks**

In `MeetingWatcher.swift`, delete `microphoneInUse()` entirely (lines 184-208 in the original file, the whole function including its doc comment) and remove the now-unused `import CoreAudio`.

In `CallDetection.swift`, delete `hasActiveCallWindow(pid:)` (lines 63-76 in the original file, including its doc comment). Its last caller has just been removed. **Keep `callWindowTitle`, `hasCallLikeTitle` and `callLikeWords`** — `callWindowTitle` uses `hasCallLikeTitle` to pick which window names the meeting, and `AppState.swift:668` calls it at record start.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. `MeetingWatcherLogicTests` goes from 11 tests to 11; total lands at 479.

If the build reports `main actor-isolated property cannot be referenced from a Sendable closure` on `performDetection`, the `nonisolated(unsafe)` marker is missing — it is required here for the same reason `MemoryCapture.performCapture` has it.

- [ ] **Step 9: Commit**

```bash
git add omwhisper-native/Meetings/MeetingWatcher.swift \
        omwhisper-native/Meetings/CallDetection.swift \
        omwhisper-nativeTests/MeetingWatcherLogicTests.swift
git commit -m "🐛 fix(meetings): stop when the CALL ends, not when a window vanishes

The state machine now keys on detection instead of the microphone, which
our own recorder holds open for the whole meeting. Auto-stop becomes 'the
call app released the mic for 8s' -- it has never worked for Teams, whose
title carries no call word, so recordingCallGone could never become true.

sawCall keeps a manual recording over an unrecognised app from
auto-stopping after 8 seconds, the same job sawCallWindow did.

Reaching the start debounce with nothing detected no longer latches
.declined: a detection MISS is not the user refusing.

The sweep runs off MainActor with an in-flight guard. MeetingWatcher polls
every 2s and the browser URL check walks a web page's AX tree
breadth-unbounded -- the same shape as the MemoryCapture freeze fixed
2026-08-02. A time budget bounds how much work happens, never which
thread pays for it.

Deletes microphoneInUse and hasActiveCallWindow, both now callerless."
```

---

### Task 5: The in-flight guard has a test that can fail

**Files:**
- Create: `omwhisper-nativeTests/MeetingWatcherConcurrencyTests.swift`

**Interfaces:**
- Consumes: `MeetingWatcher.performDetection`, `MeetingWatcher.isDetecting`, `MeetingWatcher.DetectedCall` from Task 4.
- Produces: nothing.

Modelled directly on `MemoryCaptureConcurrencyTests` in `omwhisper-nativeTests/MemoryCaptureExclusionTests.swift:35-100`. Fixed sleeps are timing guesses — this suite runs in parallel with 68 others, so any single duration is wrong sometimes.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import os
@testable import OmWhisper

@Suite("Meeting detection concurrency")
@MainActor
struct MeetingWatcherConcurrencyTests {
    /// A detection sweep that blocks until released, so "a tick arrived while
    /// one was running" is a real state rather than a timing guess.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var callCount: Int { lock.withLock { $0 } }
        func enter() { lock.withLock { $0 += 1 }; semaphore.wait() }
        func release() { semaphore.signal() }
    }

    /// Polls until `condition` holds or the deadline passes.
    private func waitUntil(
        _ description: String, timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("a tick arriving during a sweep is skipped, and the first still finishes")
    func overlappingTickIsSkipped() async throws {
        let gate = Gate()
        let watcher = MeetingWatcher()
        watcher.performDetection = { gate.enter(); return nil }

        watcher.startForTesting()
        #expect(await waitUntil("sweep starts") { watcher.isDetecting },
                "first sweep never started")

        watcher.startForTesting()                          // must be skipped
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.callCount == 1, "second tick started a concurrent sweep")

        gate.release()
        // Asserting only "the second returned early" would pass even if the
        // guard wedged permanently -- so check the first finished and cleared.
        #expect(await waitUntil("flag clears") { !watcher.isDetecting },
                "flag never cleared after completion")
    }

    @Test("the flag clears after completion, so later ticks run")
    func laterTickRunsAfterCompletion() async throws {
        let gate = Gate()
        let watcher = MeetingWatcher()
        watcher.performDetection = { gate.enter(); return nil }

        watcher.startForTesting()
        #expect(await waitUntil("first sweep starts") { watcher.isDetecting })
        gate.release()
        #expect(await waitUntil("first sweep ends") { !watcher.isDetecting })

        watcher.startForTesting()
        #expect(await waitUntil("second sweep starts") { watcher.isDetecting },
                "a later tick was blocked by a stale in-flight flag")
        gate.release()
        #expect(await waitUntil("second sweep ends") { !watcher.isDetecting })
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head`
Expected: `value of type 'MeetingWatcher' has no member 'startForTesting'`.

- [ ] **Step 3: Add the test hook to `MeetingWatcher.swift`**

`tick()` is private and driven by a `Timer`; a test cannot wait 2 seconds per assertion. Add immediately after `stop()`:

```swift
    /// Runs one tick synchronously. Tests only -- the real driver is the poll
    /// timer, whose 2s interval makes a test either slow or flaky.
    func startForTesting() { tick() }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 481 tests in 69 suites.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-nativeTests/MeetingWatcherConcurrencyTests.swift \
        omwhisper-native/Meetings/MeetingWatcher.swift
git commit -m "🔍 test(meetings): the detection in-flight guard, both directions

A blocking sweep makes 'a tick arrived mid-sweep' a real state instead of
a timing guess, and the assertions cover the failure the obvious test
misses: that the FIRST sweep still completes and the flag clears, so a
guard that wedged permanently cannot pass."
```

---

### Task 6: A timed-out prompt is not a refusal

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingConsentPanel.swift:21-58` (the `show` signature and timeout), `:75-125` (the view)
- Modify: `omwhisper-native/Meetings/MeetingWatcher.swift` (the `onShowConsentPanel` type and the `.prompting` handler from Task 4)
- Modify: `omwhisper-native/AppState.swift:598-600`

**Interfaces:**
- Consumes: `MeetingWatcherState.awaitingRetry(appName:)`, `MeetingWatcher.hasRetried`, `retrySince` from Task 4.
- Produces: `MeetingConsent` — `nonisolated enum { case accepted, declined, timedOut }`, `Equatable`.

A `Bool` cannot carry the distinction between "the user said no" and "the user never saw it", and passing `false` for both is exactly the bug being fixed.

- [ ] **Step 1: Add the `MeetingConsent` type**

At the top of `MeetingConsentPanel.swift`, after the imports:

```swift
/// What the consent prompt actually returned. A Bool cannot express the
/// difference between a refusal and an unanswered prompt, and treating them
/// alike is why a prompt missed during a call's pre-join screen silenced
/// recording for the whole meeting.
nonisolated enum MeetingConsent: Equatable {
    case accepted
    case declined
    case timedOut
}
```

- [ ] **Step 2: Change the panel to report it**

Replace the `show` signature on line 21 and the two callbacks:

```swift
    func show(appName: String, onDecision: @escaping (MeetingConsent) -> Void) {
        dismiss()

        let initialSeconds = Int(MeetingWatcherTiming.consentTimeout.components.seconds)
        let content = MeetingConsentView(appName: appName, secondsRemaining: initialSeconds) { [weak self] consent in
            self?.dismiss()
            onDecision(consent)
        }
```

and the timeout task at the end of `show`:

```swift
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: MeetingWatcherTiming.consentTimeout)
            guard !Task.isCancelled else { return }
            self?.dismiss()
            onDecision(.timedOut)
        }
```

- [ ] **Step 3: Update the view and its copy**

In `MeetingConsentView`, change the callback type and the two buttons:

```swift
    let onDecision: (MeetingConsent) -> Void
```

```swift
            Button("Not now") { onDecision(.declined) }
```

```swift
                Button { onDecision(.accepted) } label: {
```

And replace the subtitle on line 88, which currently promises something no longer true:

```swift
            Text("No answer? We'll ask once more, then leave it. Stays on this Mac.")
```

- [ ] **Step 4: Route the three cases in `MeetingWatcher.swift`**

Change the collaborator's type:

```swift
    var onShowConsentPanel: (String, @escaping (MeetingConsent) -> Void) -> Void = { _, respond in respond(.declined) }
```

and replace the `.prompting` case body in `apply(_:)` written in Task 4:

```swift
        case .prompting(let appName):
            pendingCallPID = detected?.pid
            retrySince = nil
            onShowConsentPanel(appName) { [weak self] consent in
                guard let self else { return }
                switch consent {
                case .accepted:
                    self.recordingPID = self.pendingCallPID
                    self.sawCall = false
                    self.goneSince = nil
                    self.state = .recording(appName: appName)
                    self.onStartRecording(appName)
                case .declined:
                    self.state = .declined
                case .timedOut:
                    // One retry per call. A second unanswered prompt goes quiet
                    // rather than interrupting repeatedly.
                    if self.hasRetried {
                        self.state = .declined
                    } else {
                        self.hasRetried = true
                        self.retrySince = ContinuousClock.now
                        self.state = .awaitingRetry(appName: appName)
                    }
                }
            }
```

- [ ] **Step 5: Update the AppState wiring**

`AppState.swift:598-600` forwards `respond` straight through, so it compiles unchanged once both types move together. Verify it reads:

```swift
                meetingWatcher.onShowConsentPanel = { [weak self] appName, respond in
                    self?.meetingConsentPanel.show(appName: appName, onDecision: respond)
                }
```

If the build reports a type mismatch here, the panel and the watcher have diverged — recheck Steps 2 and 4.

- [ ] **Step 6: Run the tests**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 481 tests. No new tests: the retry *timing* is already covered by `awaitingRetryPromptsAgain` and `awaitingRetryGoesIdleWhenCallEnds` in Task 4, and the panel itself is UI, verified live.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/MeetingConsentPanel.swift \
        omwhisper-native/Meetings/MeetingWatcher.swift
git commit -m "✨ feat(meetings): an unanswered prompt is asked once more

Teams opens the mic on its pre-join audio screen, so the first prompt
often lands while the user is still choosing a device. A timeout now
means 'didn't see it' and is retried after 60s; only an explicit Not now
latches for the call, and a second timeout goes quiet.

The callback becomes an enum because a Bool cannot carry that
distinction -- passing false for both is the bug."
```

---

## Live verification

Run after Task 6, from the Debug build. Each of these can come back negative; record what actually happened, not that it "looked right".

```bash
BIN=$(xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
"$BIN/OmWhisper-Dev.app/Contents/MacOS/OmWhisper-Dev" --diagnose-meeting-detection
```

1. **Teams call → prompt.** Join a Teams call with Meetings enabled. The consent prompt appears within ~5 seconds naming Teams. Run the diagnostics mid-call and confirm it prints `com.microsoft.teams2.modulehost` and `activeCall -> Teams`.
2. **Hang up → auto-stop.** The recording stops within ~10 seconds **without** clicking Stop. This has never worked for Teams.
3. **Google Meet in Chrome → prompt.** With a Meet tab focused and the mic live.
4. **The browser gate, both directions — corrected during implementation.** The original step
   here ("play a YouTube video, expect no prompt, confirm `meetingPage=false`") **cannot
   exercise the gate at all**: playing audio does not record any, so Chrome never appears in
   `capturingInput()` and the browser line never prints. The diagnostics now check every
   *running* browser independently of the mic. Open a non-meeting page → `meetingPage=false`
   with a real `domain=` beside it; open a Meet page → `meetingPage=true`.

   **Run this from the app's own context, not a shell.** A binary spawned from a terminal makes
   the terminal the responsible process for TCC, so `AXIsProcessTrusted` is false and every URL
   reads `<no URL read>` regardless of the page — measured, and the reason the domain and trust
   lines were added. The output labels this when it happens. The CoreAudio section needs no
   permission and is unaffected.
5. **Timeout → one retry.** Let the prompt expire. It reappears about a minute later, once. Let it expire again — it stays quiet for the rest of the call.
6. **Manual record of a non-call app does not auto-stop.** Click Record with no call running; confirm it is still recording after a minute.
6b. **Switching windows mid-call does not stop the recording.** During a detected browser
   meeting, move to another window or tab for a minute. The recording must continue — the stop
   path asks whether *this* call is still capturing rather than re-reading the focused window's
   URL, which is the defect found while implementing Task 4.
7. **Shortcuts stay responsive.** During a detected call, press the dictation shortcut repeatedly. It must start instantly every time — the sweep runs off MainActor, and this is the check that proves it.

## Out of scope

Changing the 2s poll or the 3s/8s/10s timings · the recorder · the consent panel's visual design · per-app tuning beyond the bundle-ID list · detecting calls in apps absent from `callerApps` · speaker-only participation.
