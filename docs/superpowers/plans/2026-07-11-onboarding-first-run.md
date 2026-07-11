# Onboarding / First-Run Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A first-run flow that front-loads mic/speech permissions, proves the product with one real live dictation (no paste), teaches ⌘⇧V + Fn, then never shows again.

**Architecture:** A new dark-identity `Window("Welcome")` scene shown once on first launch (gated by `hasCompletedOnboarding`). Four steps: Welcome → Permissions → real live-dictation demo → done. The demo reuses the existing capture→transcribe→overlay pipeline; a new `onboardingDemoActive` flag makes `stopDictation` skip paste + history, and the onboarding field mirrors the already-`@Observable` `finalizedTranscript`/`volatileTranscript`.

**Tech Stack:** Swift 6 (MainActor-by-default), SwiftUI, AppKit (`NSApplicationDelegate`), Swift Testing.

## Global Constraints

- **Dark identity only.** Onboarding uses the hard-dark `om*` tokens and `OmOrbView(palette: .dark)` (the default), pinned via `.porcelainWindow(colorScheme: .dark)`. It ignores the appearance picker. (CLAUDE.md scope rule: dark identity = overlay HUD + onboarding only.)
- **`Color(hex:)` is `private` to `OmColors.swift`** — do NOT use it in new files. Use only the named `Color.om*` tokens (`omBackground`, `omEmerald`, `omTeal`, `omMint`, `omGlyphCore`, `omError`) plus stdlib `Color` (`.black`/`.white` opacities).
- **`@Observable`-over-UserDefaults pattern:** any UserDefaults-backed property that a control binds to must wrap its get in `access(keyPath:)` and its set in `withMutation(keyPath:)` (see `mcpAccessEnabled` in `AppState.swift`).
- **Test-safety:** first-run window auto-open must stay behind the existing `guard !isRunningUnderTests` in `applicationDidFinishLaunching`.
- **Do not hand-edit `project.pbxproj`.** Groups are file-system-synchronized — new `.swift` files are picked up automatically.
- **Leave untouched** (pre-existing uncommitted local changes): `docs/OVERLAY_SPEC.md`, `omwhisper-native.xcodeproj/project.pbxproj`, `docs/COMPETITOR_FLUIDVOICE.md`.

---

### Task 1: Pure onboarding logic + tests

The step machine and WPM calc are pure, `nonisolated`, and unit-tested (TDD). This task creates `OnboardingView.swift` containing ONLY these two symbols (the SwiftUI views come in Task 3) so the tests compile against real code.

**Files:**
- Create: `omwhisper-native/UI/OnboardingView.swift`
- Test: `omwhisper-nativeTests/OnboardingLogicTests.swift`

**Interfaces:**
- Produces: `nonisolated enum OnboardingStep: Int, CaseIterable { case welcome, permissions, tryIt, done }` with `var next: OnboardingStep` and `var isLast: Bool`; and `nonisolated func wordsPerMinute(wordCount: Int, seconds: Double) -> Int`.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/OnboardingLogicTests.swift`:

```swift
import Testing
@testable import OmWhisper

struct OnboardingStepTests {
    @Test func nextAdvancesThenStops() {
        #expect(OnboardingStep.welcome.next == .permissions)
        #expect(OnboardingStep.permissions.next == .tryIt)
        #expect(OnboardingStep.tryIt.next == .done)
        #expect(OnboardingStep.done.next == .done)   // clamps at the last step
    }

    @Test func isLastOnlyForDone() {
        #expect(OnboardingStep.done.isLast)
        #expect(!OnboardingStep.welcome.isLast)
        #expect(!OnboardingStep.tryIt.isLast)
    }

    @Test func allCasesInOrder() {
        #expect(OnboardingStep.allCases == [.welcome, .permissions, .tryIt, .done])
    }
}

struct OnboardingWPMTests {
    @Test func normalCase() {
        // 30 words in 30 seconds = 60 wpm
        #expect(wordsPerMinute(wordCount: 30, seconds: 30) == 60)
    }

    @Test func zeroOrNegativeSecondsIsZero() {
        #expect(wordsPerMinute(wordCount: 12, seconds: 0) == 0)
        #expect(wordsPerMinute(wordCount: 12, seconds: -5) == 0)
    }

    @Test func rounds() {
        // 10 words in 7 seconds = 85.7 -> 86
        #expect(wordsPerMinute(wordCount: 10, seconds: 7) == 86)
    }

    @Test func neverNegative() {
        #expect(wordsPerMinute(wordCount: 0, seconds: 10) == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -30`
Expected: FAIL — "cannot find 'OnboardingStep' in scope" / "cannot find 'wordsPerMinute' in scope".

- [ ] **Step 3: Create `OnboardingView.swift` with only the pure logic**

Create `omwhisper-native/UI/OnboardingView.swift`:

```swift
//
//  OnboardingView.swift
//  OmWhisper
//
//  First-run flow. Dark identity only (see CLAUDE.md scope rule). The "Try it"
//  step runs a REAL dictation session with onboardingDemoActive set, so nothing
//  is pasted or written to history — the field just mirrors the live transcript.
//

import SwiftUI

nonisolated enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, tryIt, done

    /// Advances to the following step; clamps at `.done`.
    var next: OnboardingStep { OnboardingStep(rawValue: rawValue + 1) ?? self }
    var isLast: Bool { self == .done }
}

/// Words-per-minute for the try-it readout. Pure so it's unit-testable.
nonisolated func wordsPerMinute(wordCount: Int, seconds: Double) -> Int {
    guard seconds > 0 else { return 0 }
    return max(0, Int((Double(wordCount) / (seconds / 60)).rounded()))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: PASS — full suite green (263 → 271, +8 onboarding tests).

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/OnboardingView.swift omwhisper-nativeTests/OnboardingLogicTests.swift
git commit -m "feat(onboarding): step machine + WPM pure logic (Task 1)"
```

---

### Task 2: AppState surface

Add the completion flag, the demo flag, the permissions wrapper, and guard `stopDictation`'s paste + history blocks. No new unit test — this is session-path/settings wiring, verified live and by the suite staying green (matches this project's established convention for `AppState` core-loop changes).

**Files:**
- Modify: `omwhisper-native/AppState.swift` (SettingsKeys enum; new properties near the other Live-session/settings props; `stopDictation`; permissions section)

**Interfaces:**
- Consumes: existing `requestMicrophonePermission()` / `requestSpeechPermission()` (`nonisolated private`), `stopDictation`'s two `if phase == .pasting` blocks, `finalizedTranscript`/`volatileTranscript`.
- Produces (used by Tasks 3 & 4): `var onboardingDemoActive: Bool`, `func requestDictationPermissions() async -> (mic: Bool, speech: Bool)`, `var hasCompletedOnboarding: Bool`.

- [ ] **Step 1: Add the SettingsKey**

In `AppState.swift`, in `nonisolated enum SettingsKeys`, after `static let hasImportedLegacyHistory = "hasImportedLegacyHistory"`:

```swift
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
```

- [ ] **Step 2: Add the demo flag near the Live-session properties**

In `AppState.swift`, in the `// MARK: Live session` block, after `var errorMessage: String?`:

```swift
    /// True only while the onboarding "Try it" step is on screen. Makes
    /// stopDictation() skip the paste/clipboard + history-record blocks, so the
    /// real dictation pipeline runs (overlay, sounds, live transcript) but the
    /// demo never pastes into another app or pollutes history. Set by OnboardingView.
    var onboardingDemoActive = false
```

- [ ] **Step 3: Add the completion flag (UserDefaults-backed) near the other settings**

In `AppState.swift`, alongside the other settings properties (e.g. after `mcpAccessEnabled`), add:

```swift
    /// First-run gate. False until onboarding is finished or skipped; then the
    /// Welcome window never auto-opens again. access/withMutation so a DEBUG
    /// "Reset Onboarding" re-open (and any bound control) sees the change.
    var hasCompletedOnboarding: Bool {
        get {
            access(keyPath: \.hasCompletedOnboarding)
            return UserDefaults.standard.object(forKey: SettingsKeys.hasCompletedOnboarding) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.hasCompletedOnboarding) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.hasCompletedOnboarding)
            }
        }
    }
```

- [ ] **Step 4: Add the permissions wrapper**

In `AppState.swift`, in the `// MARK: Permissions` section (after `requestSpeechPermission()`), add a public wrapper:

```swift
    /// Public entry point for onboarding's permissions step. Requests mic then
    /// speech and returns both results for the ✓/denied display. Once granted,
    /// startDictation()'s own requests return immediately (no second prompt).
    func requestDictationPermissions() async -> (mic: Bool, speech: Bool) {
        let mic = await requestMicrophonePermission()
        let speech = await requestSpeechPermission()
        return (mic, speech)
    }
```

- [ ] **Step 5: Guard the paste + history blocks in `stopDictation`**

In `AppState.swift`, in `stopDictation()`, add `!onboardingDemoActive` to both `phase == .pasting` conditions. Change:

```swift
        if phase == .pasting, pasteAfterStop {
```
to:
```swift
        if phase == .pasting, pasteAfterStop, !onboardingDemoActive {
```

and change:

```swift
        // Recorded independent of pasteAfterStop — history isn't tied to auto-paste,
        // only to "did this session actually produce real text" (phase == .pasting).
        if phase == .pasting {
```
to:
```swift
        // Recorded independent of pasteAfterStop — history isn't tied to auto-paste,
        // only to "did this session actually produce real text" (phase == .pasting).
        // Skipped during onboarding's demo — the try-it run must not pollute history.
        if phase == .pasting, !onboardingDemoActive {
```

- [ ] **Step 6: Build + run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, suite green (271). (If SourceKit flagged anything mid-edit, trust `xcodebuild`, not the editor.)

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "feat(onboarding): AppState surface — demo flag, permissions wrapper, completion gate (Task 2)"
```

---

### Task 3: OnboardingView — the four-step SwiftUI flow

Fill in `OnboardingView.swift` (created in Task 1) with the container, four step views, and the local styling helpers. Verified live (SwiftUI/orb, per project convention) — no new unit test.

**Files:**
- Modify: `omwhisper-native/UI/OnboardingView.swift` (append the views below the pure logic)

**Interfaces:**
- Consumes: `OnboardingStep` (Task 1), `wordsPerMinute` (Task 1), `AppState.onboardingDemoActive` / `requestDictationPermissions()` / `hasCompletedOnboarding` / `finalizedTranscript` / `volatileTranscript` / `dictation` / `toggleDictation()` / `launchAtLogin` (Task 2), `OmOrbView(appState:)`, `porcelainWindow(colorScheme:)`, `Color.om*` tokens.
- Produces (used by Task 4): `struct OnboardingView: View` (constructed with only `.environment(appState)`; closes itself via `@Environment(\.dismissWindow)` keyed `"onboarding"`).

- [ ] **Step 1: Append the container + step views + helpers to `OnboardingView.swift`**

Append below the `wordsPerMinute` function:

```swift
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            Color.omBackground.ignoresSafeArea()

            currentStep
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(48)

            VStack {
                HStack {
                    Spacer()
                    Button("Skip setup") { finish() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.omGlyphCore.opacity(0.4))
                        .padding(20)
                }
                Spacer()
                HStack(spacing: 9) {
                    ForEach(OnboardingStep.allCases, id: \.self) { s in
                        Circle()
                            .fill(s.rawValue <= step.rawValue ? Color.omEmerald : Color.omGlyphCore.opacity(0.15))
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .frame(width: 840, height: 620)
        .porcelainWindow(colorScheme: .dark)
    }

    @ViewBuilder private var currentStep: some View {
        switch step {
        case .welcome:     WelcomeStep { step = .permissions }
        case .permissions: PermissionsStep { step = .tryIt }
        case .tryIt:       TryItStep { step = .done }
        case .done:        DoneStep(onFinish: finish)
        }
    }

    private func finish() {
        appState.hasCompletedOnboarding = true
        dismissWindow(id: "onboarding")
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @Environment(AppState.self) private var appState
    let onBegin: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            OmOrbView(appState: appState)
                .frame(width: 190, height: 190)
                .padding(.bottom, 6)
            Text("OmWhisper")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            Text("Speak. It types.")
                .font(.system(size: 16))
                .foregroundStyle(Color.omGlyphCore.opacity(0.55))
            Label("Your voice never leaves this Mac.", systemImage: "laptopcomputer")
                .font(.system(size: 14))
                .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                .padding(.top, 10)
            OnboardingButton("Begin", action: onBegin).padding(.top, 22)
        }
    }
}

private struct PermissionsStep: View {
    @Environment(AppState.self) private var appState
    let onContinue: () -> Void
    @State private var result: (mic: Bool, speech: Bool)?
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 14) {
            KickerText("Sense 1 of 2 · Hearing")
            Text("Let it hear you")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            Text("One permission now. Audio is transcribed on this Mac and discarded — nothing stored, nothing sent.")
                .font(.system(size: 15))
                .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            if let result {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow("Microphone", granted: result.mic)
                    permissionRow("Speech Recognition", granted: result.speech)
                }
                .padding(.top, 6)
                if !result.mic || !result.speech {
                    Text("The magic needs ears — you can enable these later in System Settings › Privacy & Security.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.omMint.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                }
                OnboardingButton("Continue", action: onContinue).padding(.top, 12)
            } else {
                OnboardingButton(requesting ? "Requesting…" : "Grant microphone & speech") {
                    requesting = true
                    Task {
                        result = await appState.requestDictationPermissions()
                        requesting = false
                    }
                }
                .disabled(requesting)
                .padding(.top, 12)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? Color.omEmerald : Color.omError)
            Text(name).foregroundStyle(Color.omGlyphCore)
        }
        .font(.system(size: 14))
    }
}

private struct TryItStep: View {
    @Environment(AppState.self) private var appState
    let onNext: () -> Void
    @State private var sessionStart: Date?
    @State private var elapsed: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            KickerText("This is the overlay you'll see every day")
            VStack(spacing: 8) {
                Text("Hold to talk, then release")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.omGlyphCore)
                HStack(spacing: 6) {
                    Text("Hold").foregroundStyle(Color.omGlyphCore.opacity(0.6))
                    KeyCap("Fn")
                    Text("(Globe) — or").foregroundStyle(Color.omGlyphCore.opacity(0.6))
                    KeyCap("⌘⇧V")
                    Text("— and speak").foregroundStyle(Color.omGlyphCore.opacity(0.6))
                }
                .font(.system(size: 14))
            }

            transcriptField

            let text = appState.finalizedTranscript
            if appState.dictation == .idle, !text.isEmpty {
                let wpm = wordsPerMinute(
                    wordCount: text.split(whereSeparator: \.isWhitespace).count,
                    seconds: elapsed
                )
                Text("\(wpm) words / min")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.omMint)
                OnboardingButton("Feels fast →", action: onNext)
            } else {
                Button(appState.dictation == .recording ? "Stop" : "Start") {
                    appState.toggleDictation()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.omMint)
                .padding(.top, 4)
            }
        }
        .onAppear { appState.onboardingDemoActive = true }
        .onDisappear { appState.onboardingDemoActive = false }
        .onChange(of: appState.dictation) { _, newValue in
            switch newValue {
            case .recording:
                sessionStart = Date()
            case .idle:
                if let start = sessionStart {
                    elapsed = Date().timeIntervalSince(start)
                    sessionStart = nil
                }
            default:
                break
            }
        }
    }

    private var transcriptField: some View {
        let display = (appState.finalizedTranscript + " " + appState.volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Text(display.isEmpty ? "Your words will appear here…" : display)
            .font(.system(size: 16))
            .foregroundStyle(display.isEmpty ? Color.omGlyphCore.opacity(0.3) : Color.omGlyphCore)
            .frame(width: 500, height: 90, alignment: .topLeading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.omEmerald.opacity(0.25)))
    }
}

private struct DoneStep: View {
    @Environment(AppState.self) private var appState
    let onFinish: () -> Void

    var body: some View {
        @Bindable var state = appState
        return VStack(spacing: 14) {
            OmOrbView(appState: appState)
                .frame(width: 150, height: 150)
            Text("It lives in your menu bar now")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            HStack(spacing: 24) {
                hotkey(["⌘", "⇧", "V"], caption: "toggle dictation")
                hotkey(["Fn"], caption: "hold to talk")
            }
            .padding(.top, 8)
            Toggle("Launch OmWhisper when I log in", isOn: $state.launchAtLogin)
                .toggleStyle(.checkbox)
                .tint(Color.omEmerald)
                .foregroundStyle(Color.omGlyphCore)
                .padding(.top, 8)
            OnboardingButton("Start dictating", action: onFinish).padding(.top, 12)
        }
    }

    private func hotkey(_ keys: [String], caption: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { KeyCap($0) }
            }
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Color.omGlyphCore.opacity(0.5))
        }
    }
}

// MARK: - Local styling helpers (dark identity)

private struct OnboardingButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(white: 0.03))
                .padding(.vertical, 13)
                .padding(.horizontal, 34)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [Color.omEmerald, Color.omTeal],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color.omMint)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.omEmerald.opacity(0.3)))
    }
}

private struct KickerText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .medium))
            .tracking(2)
            .foregroundStyle(Color.omEmerald.opacity(0.9))
    }
}
```

- [ ] **Step 2: Build + run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, suite green (271). (SourceKit may cry "unable to type-check in reasonable time" on the nested `ZStack`/`VStack` — trust the real build.)

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/OnboardingView.swift
git commit -m "feat(onboarding): four-step SwiftUI flow (Task 3)"
```

---

### Task 4: Scene + first-run trigger + DEBUG reset

Wire the `Window("Welcome")` scene, open it once on first launch, and add a `#if DEBUG` "Reset Onboarding…" menu item for repeat testing. Verified live + suite stays green — no new unit test (AppKit scene/menu wiring, matching this project's convention).

**Files:**
- Modify: `omwhisper-native/OmWhisperApp.swift` (`makeScene()`; `AppDelegate` action storage; `applicationDidFinishLaunching`; `menuNeedsUpdate` DEBUG block; a DEBUG `@objc` handler)

**Interfaces:**
- Consumes: `OnboardingView` (Task 3), `AppState.hasCompletedOnboarding` (Task 2), the existing `openHubAction` storage pattern, `isRunningUnderTests` guard.

- [ ] **Step 1: Add the scene + store its open action**

In `OmWhisperApp.swift`, in `makeScene()`, add the open-action assignment inside the existing `let _ = { ... }()` block (NOT DEBUG-gated), after `delegate.openHubAction = openWindow`:

```swift
            delegate.openOnboardingAction = openWindow
```

Then add the scene after the `Window("OmWhisper", id: "hub")` scene (before the `#if DEBUG` Design Gallery scene):

```swift
        Window("Welcome", id: "onboarding") {
            OnboardingView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
```

- [ ] **Step 2: Add the action-storage property on `AppDelegate`**

In `OmWhisperApp.swift`, next to `var openHubAction: OpenWindowAction?`:

```swift
    var openOnboardingAction: OpenWindowAction?
```

- [ ] **Step 3: Trigger first-run open in `applicationDidFinishLaunching`**

In `OmWhisperApp.swift`, at the end of `applicationDidFinishLaunching(_:)` (after `observeDictationState()`, still inside the `guard !isRunningUnderTests` scope):

```swift
        // First run: show the Welcome window once. Dispatched to the next runloop
        // tick so makeScene() has stored openOnboardingAction (same store-on-delegate
        // bridge as openHubAction). LSUIElement app → activate so it comes forward.
        if !appState.hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.openOnboardingAction?(id: "onboarding")
            }
        }
```

- [ ] **Step 4: Add the DEBUG "Reset Onboarding…" menu item + handler**

In `menuNeedsUpdate(_:)`, inside the existing `#if DEBUG` block (after the "Design Gallery…" item):

```swift
        addItem(to: menu, title: "Reset Onboarding…", action: #selector(resetOnboarding))
```

And add the handler alongside the other DEBUG `@objc` handlers (e.g. after `runMemorySelfTest`), inside the existing `#if DEBUG ... #endif`:

```swift
    @objc private func resetOnboarding() {
        appState.hasCompletedOnboarding = false
        NSApp.activate(ignoringOtherApps: true)
        openOnboardingAction?(id: "onboarding")
    }
```

- [ ] **Step 5: Build + run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, suite green (271).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/OmWhisperApp.swift
git commit -m "feat(onboarding): Welcome scene, first-run trigger, DEBUG reset (Task 4)"
```

---

## Live verification (owed — run after Task 4, on real hardware)

Automated tests cover the step machine + WPM. The real flow needs a live run:

1. **First-run trigger** — DEBUG "Reset Onboarding…" (or wiping `hasCompletedOnboarding`) opens the Welcome window on next launch; a normal relaunch (flag set) does not.
2. **Permissions** — the mic and speech system prompts appear on the permissions step; granting both shows ✓✓; denying still lets Continue through.
3. **Try it (the main proof)** — holding Fn (and separately ⌘⇧V) starts a real dictation, the overlay HUD shows bottom-center, spoken words appear in the onboarding field, and **nothing is pasted into any other app and nothing is written to history** (confirms `onboardingDemoActive` suppresses both). Doubles as a first-run smoke test of the core loop.
4. **Finale** — the launch-at-login checkbox flips the login item; **Start dictating** closes the window and it never reappears.

## Self-Review notes

- **Spec coverage:** all four steps, the three AppState additions, the scene/trigger, DEBUG reset, and dark-identity constraint are each mapped to a task. The spec's `onFinish` closure is realized more simply — the view owns `appState` + `dismissWindow` and closes itself in `finish()`, so no closure is threaded from the scene (same behavior, less plumbing).
- **Type consistency:** `OnboardingStep`/`wordsPerMinute` (Task 1) used verbatim in Task 3; `onboardingDemoActive`/`requestDictationPermissions()`/`hasCompletedOnboarding` (Task 2) used verbatim in Tasks 3–4; `openOnboardingAction` stored (Task 4 Step 2) and used (Steps 1, 3, 4).
- **No placeholders:** every code step shows complete code; test counts assume the current 263 baseline (+8 → 271).
