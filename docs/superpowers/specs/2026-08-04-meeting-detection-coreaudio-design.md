# Meeting Detection via CoreAudio — Design

**Date:** 2026-08-04
**Status:** Approved. Pending an implementation plan.
**Area:** S3 meeting detection (`Meetings/CallDetection.swift`, `Meetings/MeetingWatcher.swift`,
`Meetings/MeetingConsentPanel.swift`).

## Problem

A real Microsoft Teams call ran for over half an hour on 2026-08-03 and **no consent prompt
ever appeared.** The meeting was recorded only because it was started by hand.

Teams is in `callerApps` with `needsVerification: true`, so detection required either
frontmost-ness or a call-like window title. The only check `activeCall()` actually performs is
the title one — and Memory captured Teams' real window title during that very call:

```
2026-08-03T11:10:12Z | Microsoft Teams | D-WHAS | Microsoft Teams
```

`hasCallLikeTitle` looks for `call`, `calling`, `ringing`, `meeting`, `huddle`. **`D-WHAS |
Microsoft Teams` contains none of them.** New Teams puts the *meeting name* in the title, not
the word "Meeting". So `hasActiveCallWindow` returned false on every 2-second poll for the
entire call, `activeCall()` returned nil, and the watcher went `.micActive` → `.declined`
after its 3-second debounce without ever prompting.

### Three separate defects, one missed meeting

**1. The title heuristic is a guess that vendors invalidate.** It was ported from smriti and
assumes call windows announce themselves. Teams does not. Any fix that tunes the word list
merely moves the guess.

**2. `recognizedApp` is dead code whose tests assert behaviour the app does not have.**
`CallDetection.recognizedApp(bundleID:isFrontmost:hasCallLikeWindowTitle:)` contains the escape
hatch that would have caught this call — `isFrontmost || hasCallLikeWindowTitle`, and Teams
*was* frontmost. But `activeCall()` never calls it; it applies the title check directly. The
only callers of `recognizedApp` are five assertions in `CallDetectionTests`, including
`slackNeedsFrontmostOrCallLikeTitle`, which passes while describing a code path production
never reaches. `isMeetingURL`/`meetingDomains` are dead in the same way — test-only — so
browser meetings were never detected at all.

This is the shape recorded in CLAUDE.md's Verification section: **a check that cannot fail.**
The tests exercise a pure function that nothing in the app consults.

**3. `.declined` conflates "the user said no" with "we failed to detect".** `nextState` sends
`.micActive` → `.declined` when no call is recognised within the start debounce, and
`.declined` clears only when the mic goes idle — it never re-consults `detectedCall`. So a
detection miss is latched for the life of the mic session, and there is no second chance.

**And auto-stop is broken by the same root cause.** The stop path requires `sawCallWindow` to
have become true before `recordingCallGone` can be, so with a title like `D-WHAS | Microsoft
Teams` an auto-started Teams recording would never have auto-stopped either. The manually
started recording on 2026-08-03 had `recordingPID == nil` and ran until stopped by hand.

## The signal that actually exists

CoreAudio will name the exact process holding the microphone.
`kAudioHardwarePropertyProcessObjectList` enumerates audio processes;
`kAudioProcessPropertyIsRunningInput` says whether each is capturing input right now;
`kAudioProcessPropertyBundleID` names it. Probed live against the running Teams call, from a
process with **neither Accessibility nor Screen Recording permission**, every error code `0`:

```
audio processes: 35
  com.omwhisper.mac.dev            input=YES     ← our own recorder
  com.microsoft.teams2.modulehost  input=YES     ← the actual call
  com.google.Chrome.helper         input=no
  …
```

This is direct evidence of a call rather than an inference from a window title, it needs no
permission, and the app already uses this CoreAudio process family — `MeetingRecorder` taps it
via `AudioHardwareCreateProcessTap`. It is proven ground, not a new dependency.

### Two facts the probe forced into the design

**The capturing process is a helper.** `com.microsoft.teams2.modulehost` holds the mic;
`com.microsoft.teams2` holds the windows. Matching must be **prefix-based** — an exact
bundle-ID match misses Teams again, which is today's bug in a new costume.

**The owning app's pid is not the audio process's pid.** Teams' main app was pid 2221 while
the capturing helper was pid 2500, and the helper has no windows. Detection must return the
owning app's pid, or `callWindowTitle` finds nothing and every auto-detected meeting falls back
to being titled by app name.

## Architecture

**`Meetings/AudioProcesses.swift`** (new, `nonisolated enum`) owns the CoreAudio reads and
nothing else:

```swift
struct AudioProcess: Equatable {
    let bundleID: String
    let pid: pid_t
}

/// Processes capturing microphone input right now. Empty when the property
/// reads fail — a detection miss, never a crash.
static func capturingInput() -> [AudioProcess]
```

**`CallDetection`** keeps the policy and becomes almost entirely pure. `activeCall()` is
rewritten to consult `AudioProcesses.capturingInput()` instead of walking AX windows:

1. Drop any process whose bundle ID is ours (`com.omwhisper.mac`, prefix-matched so
   `com.omwhisper.mac.dev` is covered — the dev build showed `input=YES` beside Teams in the
   probe, and without this our own recorder and our own dictation register as a call).
2. Map each remaining bundle ID through `callerApp(forAudioBundleID:)` (pure, prefix-based).
3. For a browser bundle, additionally require a meeting URL (below).
4. Resolve the owning app's pid: the running application whose bundle ID equals the matched
   base ID, falling back to the audio process's own pid when no such app is running.

**Browsers require a URL, not merely input.** Any WebRTC page captures the microphone, so a
browser alone means nothing. A browser bundle counts as a call only when its focused window
resolves to a meeting URL: `ScreenContextReader.copyAttribute(_, kAXFocusedWindowAttribute)` →
`BrowserURL.url(bundleId:window:)` → `CallDetection.isMeetingURL`. This gives `isMeetingURL`,
`meetingDomains` and `BrowserURL` their first real callers.

### What is deleted

| Removed | Why |
|---|---|
| `recognizedApp` | Dead. Its tests assert behaviour production never had. |
| `hasActiveCallWindow` | Its only callers were `activeCall()` and the stop path, both rewritten. |
| `CallerApp.needsVerification` and the two-tier scheme | The tiers existed solely to decide whether to consult the title. `CallerApp` collapses to a name. |
| `MeetingWatcher.microphoneInUse()` | No caller once detection names the process. |
| `MeetingWatcher.sawCallWindow` / `callGoneSince` | Replaced by a single detection-gone duration. |

Net: less code than today.

### What is deliberately kept

**`hasCallLikeTitle` and `callLikeWords` stay.** `callWindowTitle` uses them to *prefer* a
call-like window when naming a meeting (`titles.first(where: hasCallLikeTitle) ?? longest`).
They stop being a detection signal and remain a title-selection one. Deleting them would break
SP1's meeting identity.

Also unchanged: `callWindowTitle`, `cleanedMeetingTitle`, the 2s poll, the 3s/8s/10s timings,
`MeetingRecorder`, and the consent panel's visual design.

## State machine

`nextState` keys on the call rather than the microphone. It loses `micActive`,
`recordingCallGone` and `callGoneDuration`, and gains `detected: String?` with a single
`detectedGoneDuration`.

| From | Condition | To |
|---|---|---|
| `.idle` | `detected != nil` | `.detecting` |
| `.detecting` | `detected == nil` | `.idle` |
| `.detecting` | held ≥ 3s (`startDebounce`) | `.prompting` |
| `.prompting` | `detected == nil` | `.idle` |
| `.recording` | gone ≥ 8s (`endDebounce`) | `.idle` (stop) |
| `.declined` | `detected == nil` | `.idle` |
| `.awaitingRetry` | `detected == nil` | `.idle` |
| `.awaitingRetry` | ≥ 60s since timeout (`MeetingWatcherTiming.retryCooldown`) | `.prompting` |

`.recording` is entered as it is today — from the consent callback's accept path, or from
`enterRecording` when the user starts a recording by hand.

`.micActive` is renamed `.detecting`, since it no longer means "some mic is on" but "a
recognised call app is capturing input".

**This fixes auto-stop.** The stop condition becomes "the call app stopped capturing input for
8 seconds" — precise, and it works for every app regardless of window titles. Our own recorder
holding the mic open the whole time no longer confuses it, because our own bundle is excluded
from detection.

## Timeout is not a decline

An explicit "Not now" still latches to `.declined` for the rest of the call. A **timeout** —
the user never saw the prompt — goes to `.awaitingRetry(appName:since:)`, prompts once more
after 60 seconds, and only then falls to `.declined`. Worst case is two prompts per call.

Teams opens the microphone on its pre-join audio screen, so the first prompt frequently lands
while the user is still choosing a device. Treating that silence as a refusal is the same
conflation as defect 3.

The consent panel's callback changes from `(Bool) -> Void` to `(MeetingConsent) -> Void` with
cases `.accepted`, `.declined`, `.timedOut`. **A Bool cannot carry the distinction**, and
passing `false` for both is exactly the bug. The panel's own 10-second countdown reports
`.timedOut`; its "Not now" button reports `.declined`. Its visible copy changes from
"No response in 10s = don't record" to wording that reflects one retry.

## Failure handling

- Any CoreAudio property read failing yields an empty process list: a detection miss, handled
  by the existing `.idle` path. Manual Record remains available, as it was on 2026-08-03.
- A browser whose AX tree yields no URL is not a call. Silence is the safe direction: a false
  positive prompts during ordinary browsing, a false negative costs one auto-started recording.
- A recognised app whose owning application is not in `NSWorkspace.runningApplications` falls
  back to the audio process's pid; a missing title then falls back to the app name, as today.

## Testing

Everything except the CoreAudio enumeration is pure and tested directly:

- **Prefix matching**, pinned to the bundle IDs observed live: `com.microsoft.teams2.modulehost`
  matches Teams, `com.google.Chrome.helper` matches Chrome. An exact-match implementation must
  fail this test — it is the regression guard for the original bug.
- **Own-bundle exclusion** for both `com.omwhisper.mac` and `com.omwhisper.mac.dev`.
- **Browser requires a meeting URL**, asserted in both directions: `meet.google.com` counts,
  an ordinary URL does not.
- **State machine**: start debounce, stop debounce, `.declined` latching through continued
  detection, and the retry path — including that the *second* timeout goes quiet.

The CoreAudio read itself gets `--diagnose-meeting-detection` (DEBUG, stdout as the evidence
channel, matching `MeetingDiagnostics` and `MeetingAIDiagnostics`), printing every audio process
with its input state and what detection concludes. A unit test asserting "some process is
capturing input" would pass on a silent CI runner and prove nothing.

**Deleted alongside the code they cover:** the `recognizedApp` tests. Keeping tests for a
deleted function is how the current situation arose.

## Live verification

Each of these can come back negative:

1. Join a Teams call → the consent prompt appears within ~5s, naming Teams.
2. Hang up → the recording auto-stops within ~10s **without** clicking Stop. This has never
   worked for Teams.
3. Open a Google Meet in Chrome → prompt appears.
4. **Play a YouTube video in Chrome → no prompt.** The control. Without it, "browsers are
   detected" is untested in the direction that matters.
5. Let the prompt time out → it reappears about a minute later, once, then stays quiet.

## Out of scope

Changing the 2s poll or the 3s/8s/10s timings · the recorder · the consent panel's visual
design · per-app tuning beyond the bundle-ID list · detecting calls in apps not in
`callerApps` · speaker-only participation (listening without a microphone).

## Exit criteria

A Teams call whose window title contains no call-word produces a consent prompt within the
start debounce and auto-stops within the end debounce after the call ends; a browser capturing
audio prompts only when a meeting URL is present; a timed-out prompt is retried exactly once;
an explicit decline is not; and no dead detection function remains behind a passing test.
