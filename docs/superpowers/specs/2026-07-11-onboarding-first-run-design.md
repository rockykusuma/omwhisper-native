# Onboarding / First-Run Flow — Design

**Date:** 2026-07-11
**Milestone:** M2 leftover (the last daily-driver-parity gap; prerequisite for a beta).
Turns the never-wired `docs/onboarding-prototype.html` into a real first-run flow.

## Goal

A first-run flow that (1) front-loads mic + speech permission — today they ambush the user on
their first dictation — (2) proves the product with **one real live dictation**, and (3) teaches
the actual controls (⌘⇧V toggle, Fn/Globe push-to-talk). Then it never shows again.

## Decisions (2026-07-11)

- **Try-it is real, not simulated**: the payoff step runs the genuine capture → on-device
  transcription → overlay pipeline. Finalized text lands in a field *inside the onboarding
  window* (we set it by observing `finalizedTranscript`/`volatileTranscript`), so it does **not**
  paste via `CGEventPost` and therefore does **not** trip the deferred Accessibility permission.
- **Dark identity**: hard-dark emerald-on-green-black, ignoring the appearance picker. Per
  `CLAUDE.md`'s scope rule, the dark identity is scoped to "the overlay HUD and onboarding only."
  Reuses the real `OmOrbView(palette: .dark)`, not the prototype's canvas orb.
- **Front-load mic + speech; defer Accessibility**: the permissions step requests mic and speech
  (both are needed to dictate). Accessibility (for paste) stays deferred to first real paste — no
  prompt during onboarding. No dedicated Accessibility explainer card (user's call; the deferral
  *behavior* is unchanged either way).
- **Launch-at-login opt-in** on the finale (single checkbox over the existing
  `AppState.launchAtLogin`). **No** production re-open entry point (strictly one-time); a
  `#if DEBUG` "Reset Onboarding…" menu item exists only for testing.
- **Skippable throughout**: "Skip setup" sets the completion flag and closes, same as finishing.

## Background (verified against current code)

- **No first-run surface exists.** The app just appears in the menu bar on first launch. There is
  no onboarding window and no first-run flag (the only similar flag is
  `SettingsKeys.hasImportedLegacyHistory`, unrelated).
- **Permissions today are lazy** (`AppState.startDictation`): `requestMicrophonePermission()` and
  `requestSpeechPermission()` (both `nonisolated private`) are called on the *first* dictation
  attempt, each `guard await … else { errorMessage; dictation = .idle }`. Accessibility is checked
  at paste time (`PasteService.hasAccessibilityPermission()`); when missing, `stopDictation` copies
  to the clipboard and sets `errorMessage = "Text copied — grant Accessibility to auto-paste."` A
  "Grant Accessibility Access…" menu item shows when it's missing.
- **The dictation loop is observable.** `startDictation` streams engine events into
  `finalizedTranscript` (accumulated `.final`) and `volatileTranscript` (latest `.partial`); both
  are `@Observable` and already drive `OverlayView`. `stopDictation` collects
  `finalizedTranscript + volatileTranscript`, then runs two `phase == .pasting` blocks: (a) paste
  or clipboard-copy, and (b) `historyStore?.record(...)`.
- **Scene/menu wiring** (`OmWhisperApp.swift`): `Window("OmWhisper", id: "hub")` and
  `Window("Design Gallery", …)`, both `.defaultLaunchBehavior(.suppressed)`. `makeScene()` stores
  `openWindow` on the `AppDelegate` (`openHubAction: OpenWindowAction?`).
  `applicationDidFinishLaunching` sets up the `NSStatusItem` and is guarded by
  `!isRunningUnderTests`. The DEBUG menu already carries self-test items — the "Reset Onboarding…"
  item follows that convention.
- **Reusable UI**: `OmOrbView` (real SwiftUI orb, `.dark`/`.porcelain` palettes),
  `PorcelainComponents.porcelainWindow(colorScheme:)`, the dark `om*` color tokens in
  `OmColors.swift`. `OVERLAY_SPEC.md` documents the HUD anatomy the orb already implements.
- **Controls the flow must teach (the real ones)**: `GlobalHotkey` = Cmd+Shift+V (toggle);
  `PushToTalkMonitor` = hold Fn/Globe (push-to-talk). The prototype's "hold space" and "say
  continue" are browser stand-ins with no real backing — replaced/dropped.

## Architecture

### 1. `AppState` — the only non-UI changes

Three additions; everything else (overlay, sounds, transcript observation) runs unchanged.

- `var onboardingDemoActive = false` — a plain stored `@Observable` property. When `true`,
  `stopDictation` **skips both `phase == .pasting` blocks** (the paste/clipboard-copy block and the
  `historyStore?.record(...)` block). The overlay still shows and animates, sounds still play, and
  `finalizedTranscript`/`volatileTranscript` still update — so the onboarding field mirrors the
  real transcript, but nothing is pasted, copied, or written to history. The onboarding "Try it"
  view sets this `true` on appear and `false` on disappear.

- `func requestDictationPermissions() async -> (mic: Bool, speech: Bool)` — a public MainActor
  wrapper that awaits the two existing `nonisolated private` requesters and returns their results.
  The permissions step calls this; the results drive the per-permission ✓ / denied display.
  (`startDictation` keeps calling the private requesters itself — once granted, they return
  immediately with no second prompt, so the try-it step needs no special permission handling.)

- `var hasCompletedOnboarding: Bool` — UserDefaults-backed via a new
  `SettingsKeys.hasCompletedOnboarding`, using the established `access(keyPath:)` /
  `withMutation(keyPath:)` pattern (so a `@Observable` read/write over external storage fires
  change notifications, matching every other setting in `AppState`).

**No change to `startDictation`.** The demo uses the normal start path (PTT or ⌘⇧V); only the
*stop* path branches on `onboardingDemoActive`.

### 2. `OmWhisperApp.swift` — scene + trigger

- New `Window("Welcome", id: "onboarding") { OnboardingView().environment(appState) }`,
  `.defaultLaunchBehavior(.suppressed)`, fixed size (~840×620, `.windowResizability(.contentSize)`).
- `makeScene()` stores the open action: `delegate.openOnboardingAction = openWindow`.
- `applicationDidFinishLaunching` (already `guard !isRunningUnderTests`): after status-item setup,
  `if !appState.hasCompletedOnboarding { openOnboardingAction?(id: "onboarding") }`.
- `#if DEBUG` menu item "Reset Onboarding…" → sets `hasCompletedOnboarding = false` and opens the
  window (testing affordance only, mirroring the existing Meeting/Memory self-test items).
- A `closeOnboarding()` path: the view calls an injected `onFinish` closure →
  `appState.hasCompletedOnboarding = true`, then dismiss the window (via
  `@Environment(\.dismissWindow)` inside the view, keyed `"onboarding"`).

### 3. `UI/OnboardingView.swift` — the flow

A single container view owning `@State private var step: OnboardingStep` (enum:
`welcome / permissions / tryIt / done`) plus a small step-model, rendering the current step and a
bottom step-dots indicator and a top-right "Skip setup" button. Dark identity throughout
(`Color`/tokens from the `om*` family, `.porcelainWindow(colorScheme: .dark)` on the container).

Pure, testable logic lives in a `nonisolated` helper the container calls:

- `OnboardingStep` enum with `next` / `isLast` and an ordered `allCases` for the dots.
- `func wordsPerMinute(wordCount: Int, seconds: Double) -> Int` — the try-it readout
  (`seconds <= 0 → 0`; otherwise `round(wordCount / (seconds/60))`, clamped ≥ 0). Pure, tested.

**Step views** (private within the file):

1. **Welcome** — `OmOrbView(palette: .dark)` at rest, "OmWhisper" / "Speak. It types.", the
   on-device privacy line (waveform → 💻 → "Your voice never leaves this Mac."), **Begin** →
   `step = .permissions`.

2. **Permissions** — copy: "One permission now. Audio is transcribed on this Mac and discarded."
   A **Grant microphone & speech** button → `await appState.requestDictationPermissions()`; store
   `(mic, speech)` in `@State` and show ✓ granted / "enable later in System Settings" per result.
   **Continue** is always enabled (a denial is not a dead end) → `step = .tryIt`. If either was
   denied, show a soft one-liner ("The magic needs ears — you can enable it in System Settings >
   Privacy & Security.") but still allow Continue.

3. **Try it (real live dictation)** — `.onAppear { appState.onboardingDemoActive = true }`,
   `.onDisappear { appState.onboardingDemoActive = false }`. Instruction: "Hold **Fn** (Globe), or
   press **⌘⇧V**, and say anything." A read-only transcript field bound to
   `appState.finalizedTranscript + appState.volatileTranscript` (mirrors the live overlay).
   **Session timing** (for the WPM readout): the view observes `appState.dictation` and records a
   start `Date` in `@State` when it becomes `.recording` and an end `Date` when it returns to
   `.idle`; seconds = end − start. Once `appState.dictation == .idle && !finalizedTranscript.isEmpty`
   (i.e. a real demo session produced text), reveal the readout —
   `wordsPerMinute(wordCount: finalizedTranscript.split(whereSeparator: \.isWhitespace).count, seconds:)`
   — and a **Feels fast →** button → `step = .done`. A **Start/Stop** button (label follows
   `appState.dictation`: "Start" when `.idle`, "Stop" when `.recording`; calls
   `appState.toggleDictation()`) lets users who can't/won't hold a key run the demo too.

4. **Done (you're set)** — "It lives in your menu bar now." Teach **⌘⇧V** (toggle) and **Fn hold**
   (push-to-talk) with `kbd`-style chips. A **"Launch OmWhisper when I log in"** checkbox bound to
   `appState.launchAtLogin`. **Start dictating** → `onFinish()` (sets flag + dismisses).

The container passes `onFinish` from the scene. "Skip setup" calls the same `onFinish`.

### 4. Tests (`omwhisper-nativeTests/`)

Pure logic only (SwiftUI/orb/live-dictation is verified live, per project convention):

- `OnboardingStepTests` — `next` advances welcome→permissions→tryIt→done and stops; `isLast` true
  only for `.done`; `allCases` order matches the dots.
- `OnboardingWPMTests` — `wordsPerMinute`: normal case, `seconds <= 0 → 0`, sub-second rounding,
  never negative.

Full suite stays green (263 → ~267).

## Live verification (owed)

Automated tests cover the step machine + WPM. The real flow is verified live:

1. **First-run trigger** — fresh install (or DEBUG "Reset Onboarding") opens the Welcome window on
   launch; a normal second launch does not.
2. **Permissions** — the mic and speech system prompts appear on the permissions step; granting
   both shows ✓✓; denying still lets Continue through.
3. **Try it (the main proof)** — holding Fn (and separately ⌘⇧V) starts a real dictation, the
   overlay HUD shows bottom-center, spoken words appear in the onboarding field, and **nothing is
   pasted into any other app and nothing is written to history** (confirming `onboardingDemoActive`
   suppresses both). This doubles as a first-run smoke test of the core loop.
4. **Finale** — launch-at-login checkbox flips the login item; **Start dictating** closes the
   window and it never reappears.

## Out of scope (explicit)

- Backend/engine selection during onboarding — defaults stand (Apple engine, on-device).
- Accessibility prompt or explainer during onboarding — deferred to first real paste (unchanged).
- The prototype's "say *continue*" wake-word step — no such feature exists.
- The prototype's fake target-app playground and simulated WPM theater — replaced by the real demo.
- A production "Show Welcome again" entry point — strictly one-time; DEBUG reset only.
