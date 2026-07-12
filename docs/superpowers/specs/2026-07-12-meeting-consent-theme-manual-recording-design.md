# Meeting consent panel theming + manual recording — Design

**Date:** 2026-07-12
**Milestone:** S3 follow-up (meeting detection/recording, already shipped)
**Status:** Approved, ready for implementation plan

## Problem

Two gaps in the shipped Meetings feature:

1. **The consent panel is unthemed.** When a call is detected, `MeetingConsentPanel`
   floats a top-right prompt with a 10s countdown and a "Submarine" chime. It uses
   plain system styling (`.font(.headline)`, native buttons) — it doesn't look like
   OmWhisper.

2. **No manual recording.** Recording is 100% driven by the auto-detect → consent
   flow. If the 10s window is missed (or detection didn't fire), there is no way to
   start a recording. The user wants to open the app and start it themselves.

## Design

### 1. Re-theme the consent panel (dark `om*` identity)

The consent panel is a floating surface that sits **over other apps**, the same
category as the overlay HUD and onboarding. Per the design system's scope rule,
that category uses the **dark emerald-on-green-black identity** (`om*` tokens),
not the light/adaptive Porcelain of the hub windows.

`MeetingConsentView` (the SwiftUI content in `MeetingConsentPanel.swift`) changes:

- **Card:** `Color.omBackground` fill (opaque), 1pt `Color.omBorder @ 35%` stroke,
  16pt corner radius. The existing panel chrome (top-right position, `hasShadow`,
  non-activating, `NSSound("Submarine")` chime, 10s auto-decline `Task`) is
  unchanged — only the SwiftUI content is re-skinned. The hosting panel stays
  `backgroundColor = .clear` / `isOpaque = false` so the rounded card corners show.
- **Title** ("Record this {app} call?"): `Color.omGlyphCore`.
- **Subtitle** ("No response in 10s = don't record. Stays on this Mac."):
  `Color.omGlyphCore.opacity(0.55)` — the established onboarding idiom for
  secondary text on dark (`omDim` is not a defined `Color` token, only in comments).
- **Record dot:** a small emerald filled circle (`Color.omEmerald`) before the
  title, for warmth. No orb (keeps the transient panel light; the orb needs an
  `AppState` the panel doesn't hold).
- **Buttons:**
  - "Not now" — ghost/plain, `Color.omGlyphCore.opacity(0.55)`.
  - "Record (n)" — emerald→teal gradient pill
    (`LinearGradient([.omEmerald, .omTeal])`), dark text `#04120C`, countdown `n`
    still driven by the view's own `Timer` `.onReceive`. Keeps `.defaultAction`
    keyboard shortcut.

Copy, timing, and behavior are unchanged — this is a pure re-skin.

### 2. Manual recording

Available **anytime `meetingsEnabled` is on** — captures system audio + mic via the
existing `MeetingRecorder` regardless of whether a call app is currently detected
(so it works exactly in the "detection missed it / I was too slow" case).

**Shared recording helpers (AppState).** The start/stop bodies currently inlined in
the watcher's `onStartRecording`/`onStopRecording` closures are extracted so both the
auto-detect path and the new manual path go through the same code:

```
private func beginRecording(appName: String) {
    do {
        try meetingRecorder.start(appName: appName)
        meetingStartedAt = Date()
        meetingAppName = appName
        isRecordingMeeting = true
    } catch {
        log.error("meeting recording failed to start: \(error)")
        meetingWatcher.failedToStartRecording()
        isRecordingMeeting = false
    }
}

private func endRecording() async {
    await meetingRecorder.stop()
    isRecordingMeeting = false
    recordFinishedMeeting()
}
```

The watcher's `onStartRecording` closure becomes `self?.beginRecording(appName:)`
and `onStopRecording` becomes `await self?.endRecording()` — behavior-preserving.

**Observable state.** New `private(set) var isRecordingMeeting = false` on the
`@Observable` AppState. Because both auto and manual recording flip it, the two UIs
mirror recording state including auto-detected sessions (the button reads "Stop"
whenever a meeting is recording, not just manual ones).

**Manual toggle.**

```
func toggleMeetingRecording() {
    guard meetingsEnabled else { return }
    if isRecordingMeeting {
        meetingWatcher.markDeclined()      // won't re-prompt this call
        Task { await endRecording() }
    } else {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Recording"
        meetingWatcher.enterRecording(appName: appName)  // poll won't re-prompt; auto-stops on mic-idle
        beginRecording(appName: appName)
    }
}
```

**Watcher coordination (MeetingWatcher).** Two small external state setters so a
manual session and the 2s poll don't fight:

```
/// Manual start: treat as an ongoing recording — the poll won't re-prompt, and
/// still auto-stops it 8s after the mic goes idle (backup to the manual Stop).
func enterRecording(appName: String) { state = .recording(appName: appName) }

/// Manual stop: mark declined so the poll won't immediately re-prompt while the
/// same call's mic is still live. Resets to .idle on its own when the mic idles.
func markDeclined() { state = .declined }
```

The explicit Stop button is the reliable stop; watcher auto-stop is a bonus for the
common case where the recorder's mic tap keeps the input device "running somewhere".

Launch wiring is already guaranteed: `init()` runs `if meetingsEnabled { meetingsEnabled = true }`
(AppState.swift:763), which re-runs the setter's watcher wiring + `start()`.

### 3. Two entry points (both Porcelain — app surfaces, not over-other-apps)

- **Hub Meetings section** (`HubMeetingsSectionView.settingsBar`): a Start/Stop
  button beside the "Detect and record meetings" toggle, shown only when
  `meetingsEnabled`. While `isRecordingMeeting`, it shows a small red dot +
  "Recording…" and the button reads "Stop recording"; otherwise "Start recording".
  Porcelain tokens (`Color.Porcelain.*`), matching the section.
- **Menu-bar mini-panel** (`MiniPanelView`): a meeting record row shown only when
  `meetingsEnabled`, placed below `styleRow` and visually **distinct** from the
  existing "Start Dictating" gradient button (dictation ≠ meeting recording). A
  secondary/ghost row: "Record meeting" (idle) / red dot + "Stop recording"
  (active), `Color.Porcelain.*`. Reads `appState.isRecordingMeeting`.

## Out of scope (YAGNI)

- No elapsed-time / duration display while recording.
- No breadcrumb from a timed-out consent panel ("start it from the app") — the
  Meetings section always has the Start button when enabled.
- No recording when `meetingsEnabled` is off.
- No consent panel for manual start — clicking Record **is** the consent.
- Manual start `appName` is best-effort (frontmost app name, else "Recording"); no
  call-app disambiguation.

## Files touched

| File | Change |
|---|---|
| `Meetings/MeetingConsentPanel.swift` | Re-skin `MeetingConsentView` to dark `om*` tokens |
| `Meetings/MeetingWatcher.swift` | `+ enterRecording(appName:)`, `+ markDeclined()` |
| `AppState.swift` | Extract `beginRecording`/`endRecording`; `+ isRecordingMeeting`; `+ toggleMeetingRecording()`; rewire two closures |
| `UI/HubMeetingsSectionView.swift` | Start/Stop button in `settingsBar` |
| `UI/MiniPanelView.swift` | Meeting record row (when `meetingsEnabled`) |

## Testing

- `MeetingWatcher`: `enterRecording` sets `.recording`, `markDeclined` sets
  `.declined` — pure state assertions alongside existing `MeetingWatcherLogicTests`.
- Consent panel re-skin, hub button, and mini-panel row are SwiftUI view code —
  verified live per this project's convention (no unit tests for pure view layout).
- Live: consent panel renders in dark identity over a real call; manual Start from
  both the hub and mini-panel records + shows Stop; Stop finalizes a meeting row;
  auto-detect path still works unchanged.
