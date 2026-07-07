# Design: S3 Sub-project 1 — Meeting Detection, Consent & Recording

> Written 2026-07-07. Brainstormed via `superpowers:brainstorming`. Implements the
> first half of the "S3 — Meeting intelligence" milestone from
> `docs/SMRITI_INTEGRATION_PLAN.md`. Transcription, `PolishBackend` summarization,
> and the Meetings UI are a separate sub-project 2, deliberately deferred — mirrors
> how M3 shipped `SystemLLM` before Ollama/Cloud, and how S2 shipped screen-context
> dictation before S1's full memory capture.

## Goal

Detect when the user is in a call (Zoom/Meet/Teams/FaceTime/WhatsApp/Slack/Discord/
Webex, or a browser-based meeting), ask consent via a 10-second countdown panel
("silence = no, always"), and — only on explicit accept — record both sides of the
call (system audio + mic) to disk as two separate files. Nothing is transcribed,
summarized, or surfaced in any UI yet; that's sub-project 2. Off by default, per
this project's standing privacy contract for every Smriti-derived feature.

## Reference: smriti's implementation

Investigated directly from `/Users/rakeshkusuma/Documents/PersonalProjects/smriti`
(same author, MIT, read-only reference per this project's conventions):

- **`MeetingRecorder.swift`** — smriti uses **ScreenCaptureKit (SCK)** for both
  system audio and the mic track (`SCStreamConfiguration.captureMicrophone`),
  reasoning that VoIP apps (Zoom, Teams, WhatsApp, etc.) hold the input device
  exclusively during a call, so a naive `AVAudioEngine` mic tap silently
  records nothing while the calling app is active — SCK's microphone capture
  coexists with the calling app rather than fighting it for exclusive access.
  **Not ported as-is**: SCK requires Screen Recording permission and produces
  a system "Currently Sharing" indicator even for pure audio capture (a real,
  user-visible cost confirmed live — see Amendment below) — this project uses
  a genuinely audio-only replacement instead. Two independent `.caf` files
  (`them.caf`, `me.caf`), not one interleaved/stereo file, still apply.

  **Amendment (2026-07-08, after live verification):** SCK's audio-only use
  still triggers macOS's full "Screen & System Audio Recording" permission
  and system-wide "Currently Sharing" indicator, and a real crash during live
  testing (MeetingRecorder's SCStreamOutput callback running on the wrong
  actor — see the M3/S2-established `nonisolated` pattern) left that indicator
  orphaned, requiring a logout to clear. The user correctly pushed back:
  recording the *screen* for an *audio-only* feature is disproportionate and
  privacy-hostile, especially when a real app (confirmed via System Settings —
  "Littlebird" appears under a distinct "System Audio Recording Only" section,
  not "Screen & System Audio Recording") already ships audio-only capture on
  macOS. Verified directly against the macOS 26 SDK's CoreAudio headers:
  `AudioHardwareTapping.h`/`CATapDescription.h` — `AudioHardwareCreateProcessTap`
  (macOS 14.2+) taps system-wide audio output via
  `CATapDescription.initStereoGlobalTapButExcludeProcesses:` (excluding
  OmWhisper's own process), no screen involvement at all. `AudioHardware.h`'s
  `AudioHardwareCreateAggregateDevice` combines a real sub-device (the physical
  mic, via `kAudioAggregateDeviceSubDeviceListKey`) and that tap (via
  `kAudioAggregateDeviceTapListKey`) into one virtual input device — reading
  from the aggregate rather than the raw mic device sidesteps the VoIP-app-
  exclusive-access problem the same way SCK did, without ScreenCaptureKit.
  `AVAudioEngine`'s input node is pointed at this aggregate device via the
  exact same `kAudioOutputUnitProperty_CurrentDevice` mechanism
  `AudioCapture.swift` already uses for mic device selection — reused, not
  new machinery. The aggregate delivers one multi-channel buffer (mic channels
  followed by tap channels, per a fixed sub-device/tap ordering this code
  controls) rather than SCK's two separate callback types, so `MeetingRecorder`
  slices it by channel range into the same two `.caf` files. Net effect: no
  Screen Recording permission, no video frame, no system sharing indicator —
  only the microphone access this app already has for dictation.
- **`MeetingWatcher.swift`** — `microphoneInUse()` polls CoreAudio's
  `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device
  every 2s (cheap property reads, no audio tap while idle). A full state machine
  (`idle → micActive → prompting → recording → declined → idle`) with debounced
  start (3s) and end (8s) detection, plus a real call-app allowlist
  (`callerApps`: bundle IDs) combined with an Accessibility window-title check
  (`looksInCall()`) for apps that also run persistently outside calls (Teams,
  WhatsApp, Slack, Discord, Webex) — Zoom/FaceTime skip that extra check since
  they're essentially only mic-active during an actual call. Browser-based
  meetings detected via active-tab URL against a domain list.
  Consent panel: non-activating floating `NSPanel`, top-right, 10s countdown,
  **timeout means nothing is ever recorded** — stated explicitly in the UI copy,
  not just an implementation detail.
- **`MeetingSelfTest.swift`** — a CLI diagnostic that runs the real recorder for a
  few seconds, prompts the user to speak/play audio, and reports per-track
  duration/sample-rate/peak-dBFS with an explicit pass/fail verdict. Built
  specifically to catch a historical "mic track silently empty" regression
  without needing a live two-person call to reproduce it.
- **Permissions**: Screen Recording is TCC-gated with no async request API (first
  `SCShareableContent`/`startCapture()` call triggers the system dialog) and,
  notably, often requires an **app relaunch** after granting to take effect — a
  real UX gotcha, not a hypothetical one.
- **Not ported**: `MicCheck.swift` (a separate, unrelated CLI mic-level meter, not
  the detection mechanism), the `ClaudeCLI` subprocess summarization (replaced by
  `PolishBackend` in sub-project 2), and the macOS-15-fallback branch for
  `captureMicrophone` availability (irrelevant — this project targets macOS 26+).

## Scope for this pass

In scope: mic-open detection, call-app identification, consent panel, dual-track
SCK recording to disk, a debug-only self-test diagnostic, a Settings toggle.

Explicitly **not** in scope (sub-project 2, separate spec):

- Transcription of the recorded `.caf` files.
- Summary / action-items generation via `PolishBackend`.
- Any Meetings UI (list, detail view, search, history integration).
- GRDB schema additions for meeting metadata.

## Architecture

New `Meetings/` group, following the existing `Context/`/`Vocabulary/`/`History/`
collaborator pattern.

### `Meetings/CallDetection.swift`

```swift
nonisolated enum CallDetection {
    /// Bundle ID -> (display name, needs extra verification). Apps that also run
    /// persistently outside calls (Teams, WhatsApp, Slack, Discord, Webex) need
    /// verification; apps that are essentially only mic-active during a real call
    /// (Zoom, FaceTime) don't.
    static let callerApps: [String: (name: String, needsVerification: Bool)]
    static let meetingDomains: [String]  // meet.google, zoom.us, teams.microsoft, ...

    /// Frontmost app + (for apps needing verification) an AX window-title check
    /// for call-like words ("Calling", "Meeting", "Huddle", ...), or the active
    /// browser tab's URL against meetingDomains. nil = no recognized call.
    static func currentCall(browserURL: String?) -> String?
}
```

The AX window-title check and browser-tab-URL read reuse `ScreenContextReader`'s
existing AX walk patterns from S2 rather than introducing a second AX mechanism.

### `Meetings/MeetingWatcher.swift`

```swift
nonisolated enum MeetingWatcherState: Equatable {
    case idle
    case micActive(since: ContinuousClock.Instant)
    case prompting(appName: String)
    case recording(appName: String)
    case declined
}

@MainActor
final class MeetingWatcher {
    private(set) var state: MeetingWatcherState = .idle
    private var pollTimer: Timer?
    private let recorder: MeetingRecorder
    private let consentPanel: MeetingConsentPanel

    /// Only instantiated/started when AppState.meetingsEnabled is true — the
    /// poll timer itself never runs for a user who hasn't opted in.
    func start()
    func stop()
}
```

2s poll (`kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input
device) drives the state machine. Suppressed entirely whenever
`AppState.dictation != .idle`. Full timing table in "Consent Flow & Timing" below.

### `Meetings/MeetingRecorder.swift`

CoreAudio process tap + aggregate device, **not ScreenCaptureKit** (see the
Amendment above). `start(appName:)`:

1. Creates a system-audio tap via `AudioHardwareCreateProcessTap` with a
   `CATapDescription.initStereoGlobalTapButExcludeProcesses([ourPID])` —
   everything except OmWhisper's own audio.
2. Creates an aggregate device via `AudioHardwareCreateAggregateDevice`,
   combining the real default input device (`kAudioAggregateDeviceSubDeviceListKey`,
   also the `kAudioAggregateDeviceMainSubDeviceKey` clock source) and the tap
   (`kAudioAggregateDeviceTapListKey`), `kAudioAggregateDeviceIsPrivateKey`
   true (scoped to this process, not published system-wide).
3. Points an `AVAudioEngine`'s input node at the aggregate device via
   `kAudioOutputUnitProperty_CurrentDevice` — the identical mechanism
   `AudioCapture.setInputDevice(_:on:)` already uses for the mic-picker
   Settings feature, reused verbatim rather than reimplemented.
4. Installs a tap on that input node; each buffer's channels split at a fixed
   boundary (mic channel count, known from the sub-device's own channel
   count) into two `AVAudioPCMBuffer`s, written to `me.caf`/`them.caf` via
   `AVAudioFile`.

`stop()` removes the engine tap, stops the engine, and destroys both the
aggregate device (`AudioHardwareDestroyAggregateDevice`) and the process tap
(`AudioHardwareDestroyProcessTap`) — unlike SCK's stream lifecycle, these are
explicit HAL objects that must be torn down, not just an async stop call;
skipping this leaks a system-visible (if no longer screen-recording-flagged)
audio device. Tracks peak mic level across the recording; logs a warning on
`stop()` if it never exceeds ~-100dBFS (the "calling app blocked mic capture"
self-check, unchanged from the SCK-based design).

### `Meetings/MeetingConsentPanel.swift`

A new `NSPanel` — **not** `OverlayPanel` reused, since that panel is deliberately
`ignoresMouseEvents = true` for the display-only dictation HUD, incompatible with
a panel that needs a clickable countdown button. Non-activating, floating,
top-right positioning, live "Record (N)" countdown button, system sound on
appear.

### `Meetings/MeetingSelfTest.swift` (debug-only)

`#if DEBUG` menu item on `AppDelegate`'s status-bar menu. Runs the real
`MeetingRecorder` for ~5s, prompts (via a simple alert/overlay text) to speak and
play audio during the window, then reports duration/sample-rate/peak-dBFS per
file with an `OK ✓` / `very quiet ⚠︎` / `SILENT ✗` verdict (~-60dBFS threshold).
Never compiled into release builds.

### `AppState` additions

```swift
var meetingsEnabled: Bool   // default false — master toggle
```

```swift
@ObservationIgnored private lazy var meetingWatcher = MeetingWatcher()
```

Started/stopped by observing `meetingsEnabled` (mirrors how `contextAwareDictationEnabled`
gates S2's capture — a plain settings-driven enable/disable, not tied to app launch).

## Consent Flow & Timing

State machine: `idle → micActive(since:) → prompting → recording → declined → idle`.

| Transition | Condition |
|---|---|
| `idle → micActive` | `kAudioDevicePropertyDeviceIsRunningSomewhere` becomes true |
| `micActive → prompting` | mic active continuously for **3s** *and* `CallDetection.currentCall` is non-nil |
| `micActive → idle` | mic goes idle before 3s (blip, not a real call) |
| `prompting → recording` | user clicks the consent panel's Record button |
| `prompting → declined` | **10s timeout with no response, or explicit decline** — either way, nothing is ever recorded |
| `prompting → idle` | mic goes idle before the user responds (false-positive call that ended immediately) — panel auto-dismisses |
| `recording → idle` | mic idle continuously for **8s** (longer than the start debounce, to tolerate brief mid-call silence/mute) — finalizes the recording |
| `declined → idle` | mic goes fully idle (re-arms detection; prevents re-prompting every 2s for the same declined call) |
| any state | → suppressed entirely while `AppState.dictation != .idle` |

All values (2s poll / 3s start-debounce / 8s end-debounce / 10s countdown) are
carried over from smriti's implementation — already proven against real calls,
not reinvented.

## Recording & Storage

Two independent `.caf` files per meeting: `them.caf` (system audio) and `me.caf`
(mic), written incrementally. Stored at
`~/Library/Application Support/com.omwhisper.mac/meetings/<timestamp>_<appname>/`
— alongside, not inside, `history.db`; sub-project 2 will add a reference from a
`meetings` table into that same GRDB database (this project's "one database"
rule applies to metadata, not to the audio files themselves).

## Settings

New **Meetings** tab in `SettingsView`'s `TabView`:

- **Master toggle**, default **OFF**. `MeetingWatcher` isn't instantiated/started
  unless this is on — no poll timer, no consent prompts, no recording capability
  at all for a user who never opens this tab. One toggle, not two: smriti has a
  separate `autoRecordMeetings` flag, but since consent is *always* required
  regardless of that flag (it only gates whether the prompt fires at all, never
  whether it's skipped), a "detect but never even ask" middle state doesn't add
  real user value at this stage — easy to split into two settings later if it
  turns out to matter.

## Error Handling & Permissions

- **Permissions**: only Microphone — already granted for dictation, via the
  existing `com.apple.security.device.audio-input` entitlement. No Screen
  Recording prompt, no new entitlement, no app-relaunch gotcha (that whole
  class of friction was specific to ScreenCaptureKit and no longer applies).
- **Recording failure** (`OSStatus` non-`noErr` from any HAL call, disk write
  failure): never crash, never leave the consent panel stuck in `.prompting`.
  Falls back to `.declined`-equivalent, logs the error, no partial/corrupt
  meeting directory left behind. If the tap or aggregate device was partially
  created before a later step failed, `start()`'s error path must still
  destroy whatever was created — a half-built aggregate device is exactly the
  kind of orphaned system object the SCK crash taught us to avoid.
- **Unsigned dev-build TCC crash risk**: smriti found CoreAudio/Speech TCC
  queries can abort unsigned `swift build` binaries outright and built a guard
  around it. Xcode's automatic-signing debug builds are typically unaffected, so
  no guard is pre-built here for a maybe-non-issue — verify empirically during
  live testing (this project's established pattern) and only add a guard if it
  actually reproduces.

## Testing

Following this project's established convention (pure logic unit-tested;
hardware/TCC-dependent code live-verified):

- **`CallDetection`'s allowlist matching + title-keyword heuristic** — pure,
  unit-testable independent of any real AX walk (matches `ScreenContextReader`'s
  S2 precedent).
- **`MeetingWatcher`'s state-machine transitions** — extracted as static,
  testable functions (elapsed time + mic state + call-detection result → next
  state), matching `AppState.exitPhase`'s existing pattern.
- **`MeetingRecorder`'s actual CoreAudio tap/aggregate-device capture** — not
  unit-tested (hardware/permission-dependent, matches `AudioCapture`/
  `ScreenContextReader` precedent). Verified via the debug self-test
  diagnostic plus a real live call during this sub-project's live-verification
  pass. The channel-splitting boundary (mic channel count) is the one piece
  worth a pure unit test if it can be isolated from the live HAL calls —
  otherwise it's covered implicitly by the self-test's per-track peak check.
- **`MeetingConsentPanel`** — SwiftUI/AppKit view, not unit-tested, matching this
  project's convention. Live-verified.
