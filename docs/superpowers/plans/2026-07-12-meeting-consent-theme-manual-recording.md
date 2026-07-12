# Themed Meeting Consent Panel + Manual Recording — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-skin the meeting-consent panel to OmWhisper's dark identity, and add user-initiated meeting recording (start/stop from the hub Meetings section and the menu-bar mini-panel).

**Architecture:** Extract the recording start/stop bodies from the watcher's closures into shared `AppState` helpers, add an observable `isRecordingMeeting` flag + a `toggleMeetingRecording()` entry point, and give `MeetingWatcher` two tiny external state setters so a manual session and the 2s auto-detect poll don't collide. Both new UI entry points read `isRecordingMeeting` and call `toggleMeetingRecording()`.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPanel`), `@Observable` state, CoreAudio (existing `MeetingRecorder`).

## Global Constraints

- **Xcode scheme is `omwhisper-native`** (product name is "OmWhisper") — all build/test commands use `-scheme omwhisper-native`.
- **Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** — every unannotated type/func is `@MainActor`. `MeetingRecorder.start(appName:)` is `nonisolated ... throws` (sync); `MeetingRecorder.stop()` is `nonisolated ... async`.
- **Dark surface tokens only** for the consent panel (over-other-apps surface): `Color.omBackground`, `Color.omBorder`, `Color.omEmerald`, `Color.omTeal`, `Color.omGlyphCore`. Secondary dark text = `Color.omGlyphCore.opacity(0.55)`. Dark button text on the emerald→teal capsule = `Color(white: 0.03)`. **`Color(hex:)` is `private`** — never call it outside `OmColors.swift`; use named `om*` tokens.
- **Porcelain tokens** (`Color.Porcelain.*`) for the hub button and mini-panel row (app surfaces).
- **UX copy voice:** no exclamation marks; state mechanisms plainly. Existing consent copy is kept verbatim.
- **Testing convention:** pure logic → Swift Testing unit tests; SwiftUI view code + CoreAudio/hardware paths → verified live, not unit-tested (per CLAUDE.md). Full suite is currently **289** tests and must stay green (regression proof) after every task.
- **Feature gating:** all manual-recording UI is shown only when `meetingsEnabled` is on; `toggleMeetingRecording()` is a no-op when it's off.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `omwhisper-native/Meetings/MeetingWatcher.swift` | Mic-open detection + consent state machine | Add `enterRecording(appName:)` and `markDeclined()` |
| `omwhisper-native/AppState.swift` | Root state + meeting orchestration | Extract `beginRecording`/`endRecording`; add `isRecordingMeeting` + `toggleMeetingRecording()`; rewire two closures |
| `omwhisper-native/Meetings/MeetingConsentPanel.swift` | Floating consent prompt | Re-skin `MeetingConsentView` to dark `om*` identity |
| `omwhisper-native/UI/HubMeetingsSectionView.swift` | Hub Meetings section | Start/Stop button in `settingsBar` |
| `omwhisper-native/UI/MiniPanelView.swift` | Menu-bar mini-panel | Meeting record row (when `meetingsEnabled`) |

---

## Task 1: Manual recording backend

Adds the shared recording helpers, the observable flag, the toggle entry point, and the watcher coordination methods. No new unit tests: `MeetingWatcher.enterRecording`/`markDeclined` are trivial state setters whose meaningful semantics (`.recording` holds; `.declined` never re-prompts while the mic is live) are already asserted by the existing `MeetingWatcherLogicTests` `nextState` cases, and the `AppState` methods drive CoreAudio hardware (verified live, per convention). Verification is build + full-suite regression + live.

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingWatcher.swift` (after `failedToStartRecording()`, ~line 98)
- Modify: `omwhisper-native/AppState.swift` (closures ~313–330; `recordFinishedMeeting` ~344; new observable var near meeting state)

**Interfaces:**
- Consumes: `MeetingRecorder.start(appName: String) throws`, `MeetingRecorder.stop() async`, existing `recordFinishedMeeting()`, `MeetingWatcherState`.
- Produces:
  - `MeetingWatcher.enterRecording(appName: String)` — sets `state = .recording(appName:)`
  - `MeetingWatcher.markDeclined()` — sets `state = .declined`
  - `AppState.isRecordingMeeting: Bool` (`private(set)`, observable)
  - `AppState.toggleMeetingRecording()`
  - `AppState.beginRecording(appName: String)` (private), `AppState.endRecording() async` (private)

- [ ] **Step 1: Add the two watcher coordination methods**

In `MeetingWatcher.swift`, immediately after the `failedToStartRecording()` method (before `private func tick()`):

```swift
    /// Manual start: treat as an ongoing recording so the auto-detect poll won't
    /// re-prompt, and still auto-stops it 8s after the mic goes idle (backup to
    /// the explicit Stop button). Paired with AppState.beginRecording.
    func enterRecording(appName: String) {
        state = .recording(appName: appName)
    }

    /// Manual stop: mark declined so the poll won't immediately re-prompt while
    /// the same call's mic is still live. Resets to .idle on its own once the
    /// mic idles (see nextState's .declined case).
    func markDeclined() {
        state = .declined
    }
```

- [ ] **Step 2: Add the observable recording flag to AppState**

In `AppState.swift`, add a stored (NOT `@ObservationIgnored`) observable property so both UIs mirror recording state. Place it just above the `meetingStartedAt`/`meetingAppName` declarations (~line 686):

```swift
    /// True whenever a meeting is being recorded — auto-detected OR manual.
    /// Observable (not @ObservationIgnored) so the hub button and mini-panel row
    /// reflect it. Flipped only in beginRecording/endRecording.
    private(set) var isRecordingMeeting = false
```

- [ ] **Step 3: Extract the shared recording helpers**

In `AppState.swift`, add these two private methods next to `recordFinishedMeeting()` (~line 344). `beginRecording` is sync (start is sync-throwing); `endRecording` is async (stop is async):

```swift
    /// Start the recorder and mark recording. Shared by the auto-detect closure
    /// and the manual toggle. On failure, resets the watcher so it isn't stuck
    /// showing .recording with no audio actually flowing.
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

    /// Stop the recorder, clear the flag, and persist the finished-meeting row.
    private func endRecording() async {
        await meetingRecorder.stop()
        isRecordingMeeting = false
        recordFinishedMeeting()
    }
```

- [ ] **Step 4: Rewire the watcher closures to the shared helpers**

In `AppState.swift`, replace the existing `onStartRecording`/`onStopRecording` closures (currently ~lines 313–330) with:

```swift
                meetingWatcher.onStartRecording = { [weak self] appName in
                    self?.beginRecording(appName: appName)
                }
                meetingWatcher.onStopRecording = { [weak self] in
                    Task { await self?.endRecording() }
                }
```

(The `isSuppressed` and `onShowConsentPanel` assignments directly above/below stay unchanged.)

- [ ] **Step 5: Add the manual toggle**

In `AppState.swift`, add below `endRecording()`:

```swift
    /// User-initiated start/stop, available anytime meetingsEnabled is on
    /// (records system audio + mic regardless of whether a call is detected).
    /// Coordinates with the watcher so the 2s poll and this manual session don't
    /// fight. Clicking record IS the consent — no consent panel here.
    func toggleMeetingRecording() {
        guard meetingsEnabled else { return }
        if isRecordingMeeting {
            meetingWatcher.markDeclined()
            Task { await endRecording() }
        } else {
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Recording"
            meetingWatcher.enterRecording(appName: appName)
            beginRecording(appName: appName)
        }
    }
```

- [ ] **Step 6: Build and run the full suite (regression)**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, test count still **289** (no new tests, none broken). If the build fails on actor isolation, confirm `MeetingRecorder.start`/`stop` are called as in the existing closures (sync `try` / `await`) and that `isRecordingMeeting` is not `@ObservationIgnored`.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/MeetingWatcher.swift omwhisper-native/AppState.swift
git commit -m "✨ feat(meetings): manual recording backend (toggle + shared start/stop helpers)"
```

---

## Task 2: Re-theme the consent panel (dark `om*` identity)

Pure re-skin of the SwiftUI content in `MeetingConsentPanel.swift`. Panel chrome (position, shadow, non-activating, `NSSound("Submarine")` chime, 10s auto-decline `Task`, countdown `Timer`) is unchanged. Verified live.

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingConsentPanel.swift` (the `private struct MeetingConsentView`, ~lines 75–100)

**Interfaces:**
- Consumes: `MeetingWatcherTiming.consentTimeout`, the injected `appName`, `secondsRemaining`, `onDecision`.
- Produces: (no API change — same `MeetingConsentView` initializer)

- [ ] **Step 1: Replace the MeetingConsentView body**

Replace the entire `var body` of `MeetingConsentView` with the dark-themed version. Keep the `@State var secondsRemaining`, `let appName`, `let onDecision`, and the `.onReceive` countdown exactly as they are:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.omEmerald).frame(width: 8, height: 8)
                Text("Record this \(appName) call?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.omGlyphCore)
            }
            Text("No response in \(Int(MeetingWatcherTiming.consentTimeout.components.seconds))s = don't record. Stays on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(Color.omGlyphCore.opacity(0.55))
            HStack {
                Button("Not now") { onDecision(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                Spacer()
                Button { onDecision(true) } label: {
                    Text("Record (\(secondsRemaining))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(white: 0.03))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                LinearGradient(colors: [Color.omEmerald, Color.omTeal],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color.omBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1)
        )
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if secondsRemaining > 0 { secondsRemaining -= 1 }
        }
    }
```

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Meetings/MeetingConsentPanel.swift
git commit -m "💄 feat(meetings): re-skin consent panel to dark om identity"
```

---

## Task 3: Hub Meetings Start/Stop button

Adds a Start/Stop recording control to `HubMeetingsSectionView.settingsBar`, shown only when `meetingsEnabled`. Porcelain tokens. Verified live.

**Files:**
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift` (the `settingsBar(state:)` method, ~lines 36–46)

**Interfaces:**
- Consumes: `state.meetingsEnabled`, `state.isRecordingMeeting`, `state.toggleMeetingRecording()` (Task 1).

- [ ] **Step 1: Add the record button to the settings bar**

In `HubMeetingsSectionView.swift`, replace the `settingsBar(state:)` method with:

```swift
    private func settingsBar(state: AppState) -> some View {
        HStack {
            Toggle("Detect and record meetings", isOn: Binding(
                get: { state.meetingsEnabled }, set: { state.meetingsEnabled = $0 }
            ))
            .tint(Color.Porcelain.emerald)
            .foregroundStyle(Color.Porcelain.ink)
            Spacer()
            if state.meetingsEnabled {
                Button { state.toggleMeetingRecording() } label: {
                    HStack(spacing: 6) {
                        if state.isRecordingMeeting {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text("Stop recording")
                        } else {
                            Image(systemName: "record.circle")
                            Text("Start recording")
                        }
                    }
                }
                .tint(Color.Porcelain.emerald)
            }
        }
        .padding(12)
    }
```

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/HubMeetingsSectionView.swift
git commit -m "✨ feat(meetings): Start/Stop recording button in hub Meetings section"
```

---

## Task 4: Mini-panel meeting record row

Adds a meeting record row to `MiniPanelView`, shown only when `meetingsEnabled`, visually distinct from the existing "Start Dictating" gradient button (a ghost row, not a second gradient pill). Porcelain tokens. Verified live.

**Files:**
- Modify: `omwhisper-native/UI/MiniPanelView.swift` (the `body` VStack ~lines 33–45; add a computed row ~after `styleRow`, ~line 114)

**Interfaces:**
- Consumes: `appState.meetingsEnabled`, `appState.isRecordingMeeting`, `appState.toggleMeetingRecording()` (Task 1).

- [ ] **Step 1: Insert the row into the body**

In `MiniPanelView.swift`, in `body`, add the meeting row right after `styleRow` (before the `if let lastEntry` block):

```swift
            styleRow
            if appState.meetingsEnabled {
                meetingRecordRow
            }
            if let lastEntry {
```

- [ ] **Step 2: Add the meetingRecordRow computed view**

Add this computed property after the `styleRow` property (~after line 114):

```swift
    // Distinct from the big "Start Dictating" gradient button above — dictation
    // and meeting recording are different actions. A ghost row, shown only when
    // meeting detection is enabled.
    private var meetingRecordRow: some View {
        Button { appState.toggleMeetingRecording() } label: {
            HStack(spacing: 6) {
                if appState.isRecordingMeeting {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Stop recording")
                } else {
                    Image(systemName: "record.circle").font(.system(size: 11))
                    Text("Record meeting")
                }
                Spacer()
            }
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.isRecordingMeeting ? Color.Porcelain.ink : Color.Porcelain.dim)
    }
```

- [ ] **Step 3: Build**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/MiniPanelView.swift
git commit -m "✨ feat(meetings): meeting record row in menu-bar mini-panel"
```

---

## Live verification (after all tasks, on real hardware)

The unit suite can't cover the CoreAudio/SwiftUI surface. After merging, verify live:

1. **Consent panel theme** — with "Detect and record meetings" on, join/start a real call (Zoom/Meet/FaceTime). The consent panel appears top-right in the dark identity (dark card, emerald dot, emerald→teal Record pill, countdown ticking, Submarine chime). Clicking Record starts recording; letting it time out declines.
2. **Manual start — hub** — open OmWhisper → Meetings. "Start recording" is visible (feature on). Click it → it flips to a red dot + "Stop recording". Click Stop → a new meeting row appears in the list ("Recorded").
3. **Manual start — mini-panel** — left-click the menu-bar icon → the "Record meeting" ghost row is present. Click → "Stop recording" (red dot). It mirrors the hub button (both reflect `isRecordingMeeting`). Stop → meeting row persists.
4. **Auto path still works** — the detect → consent → record → mic-idle-auto-stop flow is unchanged; a detected-and-accepted meeting also flips both buttons to "Stop recording" while recording.
5. **Feature off** — with the toggle off, neither the hub button nor the mini-panel row is shown.

## Self-Review

- **Spec coverage:** consent re-skin → Task 2; manual backend (helpers, flag, toggle, watcher coordination) → Task 1; hub entry point → Task 3; mini-panel entry point → Task 4. All spec sections mapped.
- **Placeholders:** none — every code step is complete, using verified reusable patterns (`Color(white: 0.03)` + emerald→teal capsule from onboarding; `omGlyphCore.opacity(0.55)` secondary text; Porcelain ghost rows).
- **Type consistency:** `toggleMeetingRecording()`, `isRecordingMeeting`, `beginRecording(appName:)`, `endRecording()`, `enterRecording(appName:)`, `markDeclined()` are named identically in the interface blocks and every call site.
