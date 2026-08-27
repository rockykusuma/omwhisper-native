# Onboarding local-AI step — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a skippable onboarding step that offers the two on-device AI backends and, when Ollama has no models, says so accurately instead of asking whether a service the user never installed is running.

**Architecture:** One new pure type (`OllamaPresence`) turns three indistinguishable failures into four named states. A new `.aiPolish` onboarding step renders two cards from that state and from `SystemLLM.unavailableReason()`, writing only `AIFeature.dictationPolish`. The existing Settings Ollama section switches to the same type so both surfaces agree.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), SwiftUI + AppKit, Swift Testing, `URLSession`, `FileManager`, `NSWorkspace`.

**Spec:** `docs/superpowers/specs/2026-08-27-onboarding-local-ai-step-design.md`

## Global Constraints

- **Every new type must be marked `nonisolated`** if anything outside MainActor touches it. This project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated type is `@MainActor` and calling it from a plain (non-MainActor) test function fails to compile. This has bitten `ParakeetEngine`, `MCPServer`, `CloudEngine` and `MeetingSummarizer`.
- **No test may construct `AppState`.** Doing so opens the real history and memory stores and touches the real Keychain — the trap `KeychainTests` fell into, which silently deleted real API keys for days.
- **No `POST /api/pull`.** No downloader in any form. Both surfaces print `ollama pull qwen3.5` instead.
- **Cloud must not appear** anywhere in onboarding.
- **The step writes `AIFeature.dictationPolish` only.** Never the global `polishBackend`, never the other four features.
- **Onboarding is dark identity** — it ignores the appearance picker. Use `Color.om*` tokens (`omGlyphCore`, `omEmerald`, `omTeal`, `omDim`), never `Color.Porcelain.*`.
- **Recommended model copy is exactly `qwen3.5`, stated as `6.6 GB`.** Measured: `llama3.2:3b` makes Ask and summaries look broken; a 9.6 GB model froze a 16 GB Mac.
- Build: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build`
- Test: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test`
- Baseline before starting: **611 tests in 92 suites** passing.

---

### Task 1: `OllamaPresence` — four named states instead of one Bool

**Files:**
- Create: `omwhisper-native/Polish/OllamaPresence.swift`
- Test: `omwhisper-nativeTests/OllamaPresenceTests.swift`

**Interfaces:**
- Consumes: `Ollama.tagsURL(baseURL:)` and `Ollama.parseModelNames(_:)` — both existing internal statics on `nonisolated struct Ollama` in `omwhisper-native/Polish/Ollama.swift`.
- Produces: `OllamaState` (`.notInstalled | .installedNotRunning | .runningNoModels | .ready([String])`), `OllamaPresence.classify(appInstalled:reachable:models:) -> OllamaState`, `OllamaPresence.detect(baseURL:) async -> OllamaState`, `OllamaPresence.recommendedModel: String`, `OllamaPresence.recommendedModelSize: String`, `OllamaPresence.pullCommand: String`. Tasks 2 and 3 both use all of these.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/OllamaPresenceTests.swift`:

```swift
import Testing
@testable import OmWhisper

/// `Ollama.checkStatus` returns a Bool, which reports "not installed",
/// "installed but not running" and "wrong port" identically. Telling someone to
/// check whether a service is running when they never installed it is the same
/// wrong-diagnosis failure this project already recorded twice.
struct OllamaPresenceTests {
    @Test func unreachableWithTheAppOnDiskIsNotRunning() {
        #expect(OllamaPresence.classify(appInstalled: true, reachable: false, models: [])
                == .installedNotRunning)
    }

    @Test func unreachableWithNothingOnDiskIsNotInstalled() {
        #expect(OllamaPresence.classify(appInstalled: false, reachable: false, models: [])
                == .notInstalled)
    }

    @Test func reachableWithNoModelsIsRunningNoModels() {
        #expect(OllamaPresence.classify(appInstalled: true, reachable: true, models: [])
                == .runningNoModels)
    }

    @Test func reachableWithModelsIsReady() {
        #expect(OllamaPresence.classify(appInstalled: true, reachable: true, models: ["qwen3.5:latest"])
                == .ready(["qwen3.5:latest"]))
    }

    /// A running server proves installation whatever the filesystem says —
    /// Docker, a custom prefix, or a remote baseURL. Letting the disk check win
    /// would tell someone with a working Ollama to go install it.
    @Test func reachableWinsOverTheFilesystemCheck() {
        #expect(OllamaPresence.classify(appInstalled: false, reachable: true, models: ["m"])
                == .ready(["m"]))
        #expect(OllamaPresence.classify(appInstalled: false, reachable: true, models: [])
                == .runningNoModels)
    }

    /// `.ready([])` would render a model picker with nothing in it.
    @Test func readyIsNeverEmpty() {
        for installed in [true, false] {
            #expect(OllamaPresence.classify(appInstalled: installed, reachable: true, models: [])
                    != .ready([]))
        }
    }

    /// Two surfaces print this command. If they drift, one of them teaches the
    /// user to pull a model the other does not recommend.
    @Test func pullCommandNamesTheRecommendedModel() {
        #expect(OllamaPresence.pullCommand.contains(OllamaPresence.recommendedModel))
        #expect(OllamaPresence.pullCommand.hasPrefix("ollama pull "))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with"`

Expected: FAIL to compile with `cannot find 'OllamaPresence' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `omwhisper-native/Polish/OllamaPresence.swift`:

```swift
//
//  OllamaPresence.swift
//  OmWhisper
//
//  Four named states where `Ollama.checkStatus` had one Bool.
//
//  "Couldn't reach Ollama. Is it running?" is the right sentence for exactly
//  one of the three ways reachability fails, and the wrong one for the other
//  two. A user who never installed Ollama is told to check a service; a user
//  whose server is up with nothing pulled is told the same. A wrong diagnosis
//  costs more than none, because it sends the next hour to the wrong place.
//
//  The app is not sandboxed, so the filesystem answers what the port cannot.
//

import Foundation

nonisolated enum OllamaState: Equatable {
    case notInstalled
    case installedNotRunning
    case runningNoModels
    case ready([String])
}

nonisolated enum OllamaPresence {
    /// Measured on this project's own transcripts, not chosen by preference:
    /// `llama3.2:3b` answers "Nothing relevant." to questions the material
    /// plainly answers, and `gemma4` is 9.6 GB and froze a 16 GB Mac. qwen3.5
    /// is 9.7B in 6.6 GB and got speaker attribution right.
    static let recommendedModel = "qwen3.5"
    static let recommendedModelSize = "6.6 GB"
    static let pullCommand = "ollama pull qwen3.5"

    /// Proof Ollama is on this Mac even when nothing is listening. Checked in
    /// order; any hit is enough.
    static let installPaths = [
        "/Applications/Ollama.app",
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
    ]

    /// Pure: the whole classification, so it is testable without a network or a
    /// filesystem. `reachable` means /api/tags answered 2xx; `models` is what
    /// it listed.
    ///
    /// `reachable` is checked first on purpose — see the test.
    static func classify(appInstalled: Bool, reachable: Bool, models: [String]) -> OllamaState {
        guard reachable else { return appInstalled ? .installedNotRunning : .notInstalled }
        return models.isEmpty ? .runningNoModels : .ready(models)
    }

    static func appInstalled(fileManager: FileManager = .default) -> Bool {
        if installPaths.contains(where: { fileManager.fileExists(atPath: $0) }) { return true }
        return fileManager.fileExists(atPath: NSHomeDirectory() + "/.ollama")
    }

    /// ONE request, not two. `Ollama.listModels` cannot serve this alone: it
    /// returns `[]` both when the server is unreachable and when it is running
    /// with nothing pulled — the two rows that must be told apart.
    static func detect(baseURL: String) async -> OllamaState {
        guard let url = Ollama.tagsURL(baseURL: baseURL) else {
            return classify(appInstalled: appInstalled(), reachable: false, models: [])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else {
            return classify(appInstalled: appInstalled(), reachable: false, models: [])
        }
        return classify(appInstalled: true, reachable: true, models: Ollama.parseModelNames(data))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"`

Expected: PASS, **618 tests in 93 suites**.

- [ ] **Step 5: Prove the precedence test can fail**

Temporarily reorder `classify` so the disk check wins:

```swift
        if !appInstalled && !reachable { return .notInstalled }
        if !reachable { return .installedNotRunning }
        if !appInstalled { return .notInstalled }          // TEMP: wrong precedence
        return models.isEmpty ? .runningNoModels : .ready(models)
```

Run the tests. Expected: `reachableWinsOverTheFilesystemCheck` FAILS. Then revert to the committed implementation and confirm green again. A guard that cannot fail is not a guard.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Polish/OllamaPresence.swift omwhisper-nativeTests/OllamaPresenceTests.swift
git commit -m "✨ feat(ollama): four named states where checkStatus had one Bool"
```

---

### Task 2: The onboarding step

**Files:**
- Modify: `omwhisper-native/UI/OnboardingView.swift` (enum at line 12-18, container switch at 65-68, new step view before the styling helpers at line 284)
- Modify: `omwhisper-nativeTests/OnboardingLogicTests.swift:5-21`

**Interfaces:**
- Consumes: everything Task 1 produces; `AppState.setBackend(_:for:)`, `AppState.ollamaBaseURL`, `AIFeature.dictationPolish`, `FeatureBackend.system` / `.ollama(model:)`, `SystemLLM.unavailableReason() -> String?`, and the existing private `OnboardingButton` / `KickerText` helpers in the same file.
- Produces: `OnboardingStep.aiPolish`. Task 3 does not depend on this task.

- [ ] **Step 1: Write the failing test**

Replace the three step tests in `omwhisper-nativeTests/OnboardingLogicTests.swift` with:

```swift
    @Test func nextAdvancesThenStops() {
        #expect(OnboardingStep.welcome.next == .permissions)
        #expect(OnboardingStep.permissions.next == .tryIt)
        #expect(OnboardingStep.tryIt.next == .aiPolish)
        #expect(OnboardingStep.aiPolish.next == .done)
        #expect(OnboardingStep.done.next == .done)   // clamps at the last step
    }

    @Test func isLastOnlyForDone() {
        #expect(OnboardingStep.done.isLast)
        #expect(!OnboardingStep.welcome.isLast)
        #expect(!OnboardingStep.tryIt.isLast)
        #expect(!OnboardingStep.aiPolish.isLast)
    }

    @Test func allCasesInOrder() {
        #expect(OnboardingStep.allCases == [.welcome, .permissions, .tryIt, .aiPolish, .done])
    }
```

Leave the four `wordsPerMinute` tests in that file untouched.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with"`

Expected: FAIL to compile with `type 'OnboardingStep' has no member 'aiPolish'`.

- [ ] **Step 3: Add the enum case and route to it**

In `omwhisper-native/UI/OnboardingView.swift`, change line 13 from:

```swift
    case welcome, permissions, tryIt, done
```

to:

```swift
    case welcome, permissions, tryIt, aiPolish, done
```

Then change the container switch (lines 65-68) from:

```swift
        case .tryIt:       TryItStep { step = .done }
        case .done:        DoneStep(onFinish: finish)
```

to:

```swift
        case .tryIt:       TryItStep { step = .aiPolish }
        case .aiPolish:    AIPolishStep { step = .done }
        case .done:        DoneStep(onFinish: finish)
```

- [ ] **Step 4: Write the step view**

Insert immediately before `// MARK: - Local styling helpers (dark identity)` (currently line 282) in the same file:

```swift
/// Offers the two ON-DEVICE backends. Cloud is deliberately absent: it needs an
/// API key, costs money and sends text off the Mac, none of which belongs in a
/// first-run wizard.
///
/// Writes `dictationPolish` and nothing else. `FeatureBackend.ollama(model:)`
/// carries the model inline, so there is no second write to keep in sync, and
/// leaving the global `polishBackend` alone keeps the other four features at
/// `.useDefault` without needing a guard.
private struct AIPolishStep: View {
    @Environment(AppState.self) private var appState
    let onNext: () -> Void

    @State private var ollama: OllamaState?
    @State private var picked = ""

    var body: some View {
        VStack(spacing: 12) {
            KickerText("OPTIONAL")
            Text("Want your words cleaned up?")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            Text("Both of these run on this Mac. Nothing is sent anywhere.")
                .font(.system(size: 13))
                .foregroundStyle(Color.omGlyphCore.opacity(0.6))

            appleCard
            ollamaCard

            Button("Skip for now", action: onNext)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.omGlyphCore.opacity(0.65))
                .padding(.top, 2)
            Text("You can change this any time in Settings → AI Models.")
                .font(.system(size: 11))
                .foregroundStyle(Color.omGlyphCore.opacity(0.4))
        }
        // Re-runs whenever the user comes back to this step; Refresh below
        // re-runs it on demand after they pull a model in Terminal.
        .task { await refresh() }
    }

    private func refresh() async {
        ollama = await OllamaPresence.detect(baseURL: appState.ollamaBaseURL)
    }

    // MARK: Apple Intelligence

    @ViewBuilder private var appleCard: some View {
        OnboardingCard(title: "Apple Intelligence") {
            // unavailableReason() names the REAL cause, including the en-IN case
            // where availability reports .available and every generation throws.
            // Summarising it here would reintroduce the bug it was written for.
            if let reason = SystemLLM.unavailableReason() {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
            } else {
                Text("Built into macOS. No download.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                OnboardingButton("Use Apple Intelligence") {
                    appState.setBackend(.system, for: .dictationPolish)
                    onNext()
                }
            }
        }
    }

    // MARK: Ollama

    @ViewBuilder private var ollamaCard: some View {
        OnboardingCard(title: "Ollama") {
            switch ollama {
            case nil:
                Text("Checking…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))

            case .ready(let models):
                Picker("", selection: $picked) {
                    Text("Choose a model").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .tint(Color.omEmerald)
                OnboardingButton("Use Ollama") {
                    appState.setBackend(.ollama(model: picked), for: .dictationPolish)
                    onNext()
                }
                // .disabled propagates to the inner Button, but OnboardingButton
                // paints its own gradient capsule and will NOT dim — it would
                // look enabled while doing nothing. Fade it explicitly.
                .disabled(picked.isEmpty)
                .opacity(picked.isEmpty ? 0.45 : 1)

            case .runningNoModels:
                Text("Ollama is running, but has no models yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                commandRow
                refreshButton

            case .installedNotRunning:
                Text("Ollama is installed but not running.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                HStack(spacing: 10) {
                    linkButton("Open Ollama") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
                    }
                    refreshButton
                }

            case .notInstalled:
                Text("Ollama isn't installed. It's a free local model runner.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                HStack(spacing: 10) {
                    linkButton("Get Ollama") {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                    }
                    refreshButton
                }
                commandRow
            }
        }
    }

    private var commandRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(OllamaPresence.pullCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.85))
                linkButton("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(OllamaPresence.pullCommand, forType: .string)
                }
            }
            // The size is stated because recommending a model on answer quality
            // without checking whether the hardware can hold it is a mistake
            // this project has already made once.
            Text("\(OllamaPresence.recommendedModelSize) download · needs at least 16 GB of memory")
                .font(.system(size: 11))
                .foregroundStyle(Color.omGlyphCore.opacity(0.4))
        }
    }

    private var refreshButton: some View {
        linkButton("Refresh") { Task { await refresh() } }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.omEmerald)
    }
}

/// A bordered panel on the dark onboarding ground. Local to onboarding on
/// purpose — `omCard()` is a Porcelain component and follows the appearance
/// picker, which every onboarding step ignores.
private struct OnboardingCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.omGlyphCore)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.omGlyphCore.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.omGlyphCore.opacity(0.12)))
        .frame(maxWidth: 380)
    }
}
```

- [ ] **Step 5: Run tests and build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`

Expected: PASS, **618 tests in 93 suites** (Task 2 adds no tests; it updates three).

If the build fails with `cannot find 'KickerText'`, confirm it is still `private struct KickerText` in the same file — every helper used here is file-private and must stay in `OnboardingView.swift`.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/UI/OnboardingView.swift omwhisper-nativeTests/OnboardingLogicTests.swift
git commit -m "✨ feat(onboarding): offer the two on-device backends as a skippable step"
```

---

### Task 3: Settings tells the same four states apart

**Files:**
- Modify: `omwhisper-native/UI/AISettingsView.swift:23-25` (state vars), `:75-103` (the Ollama section), `:231-238` (`testOllama`)

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces: nothing other tasks depend on.

Today that section renders `ollamaReachable: Bool?` and prints **"Couldn't reach Ollama. Is it running?"** for all three failure rows. It already has a "No models installed" line, so this task is narrower than it looks: the work is replacing the Bool with `OllamaState`, splitting the one wrong sentence into three right ones, and naming the model instead of `<model>`.

- [ ] **Step 1: Replace the state vars**

Change lines 23-25 from:

```swift
    @State private var ollamaReachable: Bool?
    @State private var ollamaModels: [String] = []
    @State private var ollamaChecking = false
```

to:

```swift
    @State private var ollamaState: OllamaState?
    @State private var ollamaChecking = false
```

- [ ] **Step 2: Rewrite `testOllama`**

Change lines 231-238 from the two-request version to:

```swift
    private func testOllama(_ baseURL: String) {
        ollamaChecking = true
        Task {
            ollamaState = await OllamaPresence.detect(baseURL: baseURL)
            ollamaChecking = false
        }
    }
```

- [ ] **Step 3: Rewrite the Ollama section body**

Replace lines 75-103 (the whole `PorcelainSection(eyebrow: "Ollama") { ... }`) with:

```swift
                PorcelainSection(eyebrow: "Ollama") {
                    TextField("Base URL", text: $state.ollamaBaseURL).porcelainField()
                    HStack {
                        Button(ollamaChecking ? "Checking…" : "Test Connection") { testOllama(state.ollamaBaseURL) }
                            .disabled(ollamaChecking)
                        // One sentence per state. The old code printed
                        // "Couldn't reach Ollama. Is it running?" for all three
                        // failures, including to people who had never installed it.
                        switch ollamaState {
                        case nil:
                            EmptyView()
                        case .ready(let models):
                            Text("Connected — \(models.count) model\(models.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(Color.Porcelain.dim)
                        case .runningNoModels:
                            Text("Connected — no models installed yet")
                                .font(.caption).foregroundStyle(Color.Porcelain.dim)
                        case .installedNotRunning:
                            Text("Ollama is installed but not running.")
                                .font(.caption).foregroundStyle(.red)
                        case .notInstalled:
                            Text("Ollama isn't installed on this Mac.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    if case .ready(let models) = ollamaState {
                        Picker("Model", selection: $state.ollamaModel) {
                            Text("Select a model").tag("")
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        .tint(Color.Porcelain.emerald)
                        .foregroundStyle(Color.Porcelain.ink)
                    } else if ollamaState == .runningNoModels || ollamaState == .notInstalled {
                        HStack(spacing: 8) {
                            Text(OllamaPresence.pullCommand)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.Porcelain.ink)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(OllamaPresence.pullCommand, forType: .string)
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.emerald)
                        }
                        Text("\(OllamaPresence.recommendedModelSize) download · needs at least 16 GB of memory")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    } else if !state.ollamaModel.isEmpty {
                        Text("Model: \(state.ollamaModel)")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    }
                    Text("Runs entirely on your Mac via Ollama. Nothing leaves this device.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                }
```

- [ ] **Step 4: Build and test**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`

Expected: PASS, **618 tests in 93 suites**.

If the compiler reports `ollamaModels` not found, a call site was missed — grep for it: `grep -n ollamaModels omwhisper-native/UI/AISettingsView.swift` must return nothing.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/AISettingsView.swift
git commit -m "🐛 fix(settings): stop telling people to start Ollama when it isn't installed"
```

---

## Live verification (owed — no test above can replace it)

Run after Task 3, on the dev build (`OmWhisper-Dev`). Each names a result that could come back negative.

1. **Quit Ollama** → the onboarding card reads *installed but not running*, not *isn't installed*. **Control:** move `/Applications/Ollama.app` aside (and confirm `/opt/homebrew/bin/ollama` is absent or moved too) and confirm it then reads *isn't installed*. Without the control, one correct-looking string proves nothing about the classification.
2. **Ollama running with every model removed** → the pull command appears. Run `ollama pull qwen3.5` in Terminal, press **Refresh** → the picker appears without relaunching the app.
3. **Choose Ollama** → quit the app, then `defaults read com.omwhisper.mac.dev aiBackend.dictationPolish` reads `ollama:<model>` **and** `defaults read com.omwhisper.mac.dev aiBackend.meetings` reports *does not exist*. Read it only after quitting: cfprefsd serves another process stale values, which already produced one false pass in this project.
4. **On this en-IN Mac**, the Apple Intelligence card shows the language sentence, not a working button.
5. **Skip** → `aiBackend.dictationPolish` still reports *does not exist*.

Replay onboarding with the `#if DEBUG` **Reset Onboarding…** menu item.
