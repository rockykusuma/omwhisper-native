# Silent Fallback Trace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a feature that quietly did nothing discoverable — passively always, and unprompted once it has clearly stopped working.

**Architecture:** A small `Degradation` recorder keeps a per-feature consecutive-failure streak in `UserDefaults`, with the escalation decision as a pure function. Two call sites record: `AppState.polishedText(for:)` and `MemoryCapture.tick()`. Streaks surface passively on each feature's settings screen and in Debug Info, and escalate once per streak through the app's existing one-time-nudge pattern.

**Tech Stack:** Swift 6, SwiftUI, UserDefaults, Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-02-silent-fallback-trace-design.md`. Read it before Task 1.
- **Scope is exactly two features**: `polish` and `memoryCapture`. **Meeting Ask is deliberately excluded** — "That wasn't discussed" can be correct five times running, and a false alarm trains people to dismiss the real one. Meeting summaries and chronicles already raise visible errors.
- **Thresholds:** polish = **10** consecutive; memoryCapture = **120** consecutive (capture ticks every 5s, so ~10 minutes).
- **Configuration is NOT failure.** These must never increment: polish backend Disabled, no active style, cross-lingual-via-Sarvam, no text to polish; Memory paused or disabled, an excluded app/domain, private browsing, a window with genuinely no text. If configuration counted, the alert would fire for people who deliberately switched something off.
- **Streaks persist across relaunches.** Apple Intelligence failed across restarts for months; an in-memory counter would have missed the exact bug this exists to catch.
- **Escalation fires once per streak.** A `warned` flag suppresses repeats; a success clears streak and flag together.
- **The recorder must never break what it observes.** Storage failures are swallowed — a broken counter must not stop a paste.
- **No behaviour change to any fallback.** Every one still fails safe exactly as today.
- **`nonisolated`.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on; `Degradation` is called from `MemoryCapture` (@MainActor) and `AppState` (@MainActor), so it may stay MainActor-isolated — but its pure decision function must be callable from plain test functions, so mark that `nonisolated`.
- **Build/test:** `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteName>`.
- Suite is at **456 tests in 64 suites** before this plan. It must never go down.

---

### Task 1: The recorder

**Files:**
- Create: `omwhisper-native/Degradation.swift`
- Test: `omwhisper-nativeTests/DegradationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Degradation.Feature` — `enum: String { case polish, memoryCapture }`, with `threshold: Int` and `label: String`
  - `Degradation.shouldEscalate(streak: Int, threshold: Int, alreadyWarned: Bool) -> Bool` — **pure**, `nonisolated`
  - `Degradation.record(_ feature: Feature, reason: String)`
  - `Degradation.recordSuccess(_ feature: Feature)`
  - `Degradation.state(_ feature: Feature) -> (streak: Int, reason: String?)`
  - `Degradation.escalationMessage(_ feature: Feature) -> String?` — non-nil exactly when this call should raise the one-time alert; marks the feature warned as a side effect

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/DegradationTests.swift`:

```swift
//
//  DegradationTests.swift
//  omwhisper-nativeTests
//
//  The mechanism exists because Apple Intelligence never worked on an en-IN
//  Mac and polish silently pasted raw text for months. These tests pin the
//  behaviour that would have caught it.
//

import Testing
@testable import OmWhisper

struct DegradationTests {
    @Test("nine failures escalate nothing; the tenth escalates")
    func escalatesAtTheThresholdAndNotBefore() {
        // The test that fails if the mechanism always fires or never fires.
        // "Does it escalate?" alone passes in both broken directions.
        for streak in 1..<10 {
            #expect(!Degradation.shouldEscalate(streak: streak, threshold: 10, alreadyWarned: false),
                    "escalated early at \(streak)")
        }
        #expect(Degradation.shouldEscalate(streak: 10, threshold: 10, alreadyWarned: false))
    }

    @Test("escalation happens once, not on every later failure")
    func escalatesOnlyOnce() {
        #expect(!Degradation.shouldEscalate(streak: 11, threshold: 10, alreadyWarned: true))
        #expect(!Degradation.shouldEscalate(streak: 50, threshold: 10, alreadyWarned: true))
    }

    @Test("thresholds are per feature")
    func perFeatureThresholds() {
        #expect(Degradation.Feature.polish.threshold == 10)
        // Capture ticks every 5s, so 10 would be under a minute of ordinary
        // window-switching. 120 is roughly ten minutes of capturing nothing.
        #expect(Degradation.Feature.memoryCapture.threshold == 120)
        #expect(!Degradation.shouldEscalate(streak: 10, threshold: 120, alreadyWarned: false))
    }

    @Test("recording accumulates, and a success resets it")
    func recordAndReset() {
        Degradation.reset(.polish)
        Degradation.record(.polish, reason: "model unavailable")
        Degradation.record(.polish, reason: "model unavailable")
        #expect(Degradation.state(.polish).streak == 2)
        #expect(Degradation.state(.polish).reason == "model unavailable")

        Degradation.recordSuccess(.polish)
        #expect(Degradation.state(.polish).streak == 0)
    }

    @Test("a success re-arms escalation for a later streak")
    func successReArmsTheWarning() {
        Degradation.reset(.polish)
        for _ in 0..<10 { Degradation.record(.polish, reason: "timed out") }
        #expect(Degradation.escalationMessage(.polish) != nil, "first streak should escalate")
        #expect(Degradation.escalationMessage(.polish) == nil, "must not re-fire for the same streak")

        Degradation.recordSuccess(.polish)
        for _ in 0..<10 { Degradation.record(.polish, reason: "timed out") }
        #expect(Degradation.escalationMessage(.polish) != nil, "a later streak should escalate again")
        Degradation.reset(.polish)
    }

    @Test("the message names the feature and the reason")
    func messageIsActionable() {
        Degradation.reset(.polish)
        for _ in 0..<10 { Degradation.record(.polish, reason: "Apple Intelligence doesn't support en-IN") }
        let message = Degradation.escalationMessage(.polish)
        #expect(message?.contains("en-IN") == true, "the real cause must survive into the message")
        #expect(message?.contains("10") == true, "say how many times, so it reads as a pattern")
        Degradation.reset(.polish)
    }

    @Test("features are independent")
    func featuresDoNotShareCounters() {
        Degradation.reset(.polish)
        Degradation.reset(.memoryCapture)
        for _ in 0..<10 { Degradation.record(.polish, reason: "x") }
        #expect(Degradation.state(.memoryCapture).streak == 0)
        Degradation.reset(.polish)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/DegradationTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: build FAILS with "cannot find 'Degradation' in scope".

- [ ] **Step 3: Write the implementation**

Create `omwhisper-native/Degradation.swift`:

```swift
//
//  Degradation.swift
//  OmWhisper
//
//  Records that a feature ran and produced nothing useful, so a feature which
//  quietly stopped working becomes discoverable.
//
//  Exists because several features fail SAFE -- polish pastes the original
//  text, memory capture stores nothing -- which makes a broken feature
//  indistinguishable from a working one. Apple Intelligence never worked on an
//  en-IN Mac (not one of Foundation Models' 23 locales, while `availability`
//  still reports `.available`), so Smart Dictation, Polish Selected,
//  brain-dump and Reply Assist returned raw text for MONTHS with nothing
//  anywhere saying so.
//
//  Occasional fallback stays silent on purpose: a flaky network nagging on
//  every paste teaches people to ignore the alert, which is worse than no
//  alert. Persistent fallback means the feature is dead, and that is the case
//  worth interrupting for.
//

import Foundation

@MainActor
enum Degradation {
    enum Feature: String, CaseIterable {
        case polish
        case memoryCapture

        /// Consecutive failures before saying something. These differ because
        /// the cadences differ: ten dictations is a session, but capture ticks
        /// every 5 seconds so ten would be under a minute of window-switching.
        var threshold: Int {
            switch self {
            case .polish: 10
            case .memoryCapture: 120
            }
        }

        var label: String {
            switch self {
            case .polish: "Polish"
            case .memoryCapture: "Memory capture"
            }
        }

        var streakKey: String { "degradation.\(rawValue).streak" }
        var reasonKey: String { "degradation.\(rawValue).reason" }
        var warnedKey: String { "degradation.\(rawValue).warned" }
    }

    /// Pure: the whole escalation decision, so it is testable without storage.
    nonisolated static func shouldEscalate(streak: Int, threshold: Int, alreadyWarned: Bool) -> Bool {
        !alreadyWarned && streak >= threshold
    }

    /// One more consecutive failure. Best-effort: a storage problem must never
    /// stop the thing being observed -- this is telemetry, not the feature.
    static func record(_ feature: Feature, reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: feature.streakKey) + 1, forKey: feature.streakKey)
        defaults.set(reason, forKey: feature.reasonKey)
    }

    /// The feature worked. Clears the streak AND the warned flag, so a later
    /// streak can escalate again rather than staying permanently muted.
    static func recordSuccess(_ feature: Feature) {
        guard UserDefaults.standard.integer(forKey: feature.streakKey) > 0
                || UserDefaults.standard.bool(forKey: feature.warnedKey) else { return }
        reset(feature)
    }

    static func reset(_ feature: Feature) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: feature.streakKey)
        defaults.removeObject(forKey: feature.reasonKey)
        defaults.removeObject(forKey: feature.warnedKey)
    }

    static func state(_ feature: Feature) -> (streak: Int, reason: String?) {
        let defaults = UserDefaults.standard
        return (defaults.integer(forKey: feature.streakKey), defaults.string(forKey: feature.reasonKey))
    }

    /// Non-nil exactly when this call should raise the one-time alert. Marks
    /// the feature warned as a side effect, so callers cannot accidentally
    /// fire it twice for one streak.
    static func escalationMessage(_ feature: Feature) -> String? {
        let defaults = UserDefaults.standard
        let streak = defaults.integer(forKey: feature.streakKey)
        let warned = defaults.bool(forKey: feature.warnedKey)
        guard shouldEscalate(streak: streak, threshold: feature.threshold, alreadyWarned: warned)
        else { return nil }
        defaults.set(true, forKey: feature.warnedKey)
        let reason = defaults.string(forKey: feature.reasonKey) ?? "reason unknown"
        return "\(feature.label) hasn't run in your last \(streak) attempts. \(reason)"
    }

    /// One line per feature for Debug Info. Silent features are omitted, so a
    /// healthy install produces nothing rather than a wall of zeroes.
    static func debugSummary() -> [String] {
        Feature.allCases.compactMap { feature in
            let current = state(feature)
            guard current.streak > 0 else { return nil }
            return "\(feature.label): \(current.streak) consecutive — \(current.reason ?? "reason unknown")"
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/DegradationTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with|recorded an issue"`

Expected: 7 tests PASS. If the compiler complains that `Degradation` is `@MainActor` and the tests are not, mark the test functions `@MainActor` — do NOT drop the isolation from `Degradation`, which is called from `@MainActor` code.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Degradation.swift omwhisper-nativeTests/DegradationTests.swift
git commit -m "✨ feat: record when a feature falls back and produces nothing"
```

---

### Task 2: Record at the two call sites

**Files:**
- Modify: `omwhisper-native/AppState.swift` (`polishedText(for:)`)
- Modify: `omwhisper-native/Memory/MemoryCapture.swift` (`tick()`)
- Test: `omwhisper-nativeTests/DegradationTests.swift` (append)

**Interfaces:**
- Consumes: `Degradation.record(_:reason:)`, `.recordSuccess(_:)`, `.escalationMessage(_:)`, `.reset(_:)`.
- Produces: nothing for later tasks.

- [ ] **Step 1: Write the failing test for the configuration rule**

Append to `omwhisper-nativeTests/DegradationTests.swift`, inside `struct DegradationTests`, before its closing brace:

```swift
    @Test("configuration states are not failures")
    func configurationDoesNotCount() {
        // If Disabled counted, the alert would fire for people who deliberately
        // switched polish off — and within a week nobody would read it.
        Degradation.reset(.polish)
        for reason in Degradation.configurationReasons {
            Degradation.recordUnlessConfiguration(.polish, reason: reason)
        }
        #expect(Degradation.state(.polish).streak == 0,
                "a configuration reason incremented the streak")

        Degradation.recordUnlessConfiguration(.polish, reason: "backend timed out")
        #expect(Degradation.state(.polish).streak == 1)
        Degradation.reset(.polish)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/DegradationTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: build FAILS with "type 'Degradation' has no member 'configurationReasons'".

- [ ] **Step 3: Add the configuration guard to `Degradation`**

In `omwhisper-native/Degradation.swift`, add inside `enum Degradation`, after `record(_:reason:)`:

```swift
    /// Reasons that mean "the user turned this off", not "this is broken".
    /// Recording these would fire the alert at people who deliberately
    /// disabled something.
    static let configurationReasons = [
        "backend disabled", "no active style", "nothing to polish",
        "cross-lingual via Sarvam", "paused", "excluded",
    ]

    /// Records only genuine faults. Configuration states pass through silently
    /// and, like a success, they do not extend an existing streak either.
    static func recordUnlessConfiguration(_ feature: Feature, reason: String) {
        guard !configurationReasons.contains(reason) else { return }
        record(feature, reason: reason)
    }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/DegradationTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with|recorded an issue"`

Expected: 8 tests PASS.

- [ ] **Step 5: Record in `polishedText(for:)`**

In `omwhisper-native/AppState.swift`, replace the whole body of `polishedText(for:)` from its first line through its closing brace with:

```swift
    private func polishedText(for original: String) async -> String {
        // Sarvam already produced English — paste as-is; never run the
        // translate/polish prompt on it, and no polish backend is required.
        if crossLingualUsesSarvam { return original }
        // The one-time nudge fires only when System is selected but off — not for
        // Disabled or an unconfigured Ollama, which are deliberate "no polish" states.
        if polishBackend == .system, !SystemLLM.isAvailable() {
            Degradation.record(.polish, reason: SystemLLM.unavailableReason() ?? "on-device model unavailable")
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = systemUnavailableMessage("polish") + " Pasted raw text for now."
            }
            escalateDegradationIfNeeded(.polish)
            return original
        }
        guard let backend = activePolishBackend() else {
            Degradation.recordUnlessConfiguration(.polish, reason: "backend disabled")
            return original
        }
        let style: PolishStyle
        let target: String?
        if crossLingualEnabled {
            // original is the source-language transcript (backend present → we run
            // the LLM translate here) — or already English if Whisper's .translate
            // fallback ran, in which case a second polish pass is harmless cleanup.
            style = CrossLingual.style(spokenLanguage: spokenLanguageName, activeStyle: activePolishStyle)
            target = nil
        } else {
            guard let active = activePolishStyle else {
                Degradation.recordUnlessConfiguration(.polish, reason: "no active style")
                return original
            }
            style = active
            target = active.requiresTargetLanguage ? translateTargetLanguage : nil
        }
        do {
            let polished = try await backend.polish(original, style: style, targetLanguage: target)
            Degradation.recordSuccess(.polish)
            return polished
        } catch {
            log.error("polishedText — polish failed: \(error)")
            Degradation.record(.polish, reason: error.localizedDescription)
            escalateDegradationIfNeeded(.polish)
            return original
        }
    }

    /// Raises the one-time alert when a feature has clearly stopped working.
    /// `escalationMessage` marks it warned, so this cannot fire twice for one
    /// streak however often it is called.
    private func escalateDegradationIfNeeded(_ feature: Degradation.Feature) {
        guard let message = Degradation.escalationMessage(feature) else { return }
        errorMessage = message
    }
```

- [ ] **Step 6: Record in `MemoryCapture.tick()`**

In `omwhisper-native/Memory/MemoryCapture.swift`, replace the empty-snapshots guard and the success path. Replace:

```swift
        let snapshots = WindowSnapshotReader.captureVisible(exclusions: exclusions)
        guard !snapshots.isEmpty else {
            memoryLog.debug("tick — no snapshots (no focused window, excluded, empty text, or missing Accessibility permission)")
            return
        }
```

with:

```swift
        let snapshots = WindowSnapshotReader.captureVisible(exclusions: exclusions)
        guard !snapshots.isEmpty else {
            memoryLog.debug("tick — no snapshots (no focused window, excluded, empty text, or missing Accessibility permission)")
            // Capture returning nothing is the same silent shape as polish
            // pasting raw: a missing Accessibility grant produces no error at
            // all, just nils, so nothing ever said capture had stopped.
            Degradation.record(.memoryCapture, reason: "nothing captured — check Accessibility permission")
            onDegradation()
            return
        }
```

and immediately after the `if stored > 0 { onSnapshotStored() }` line at the end of `tick()`, add:

```swift
        if stored > 0 { Degradation.recordSuccess(.memoryCapture) }
```

Then add the collaborator hook beside the existing ones near the top of the class:

```swift
    /// Fired when a tick captured nothing, so AppState can escalate. A no-op by
    /// default, matching the other injected collaborators here.
    var onDegradation: () -> Void = {}
```

- [ ] **Step 7: Wire the memory hook in `AppState`**

In `omwhisper-native/AppState.swift`, in the `memoryEnabled` setter's `if newValue {` block, immediately after the existing `memoryCapture.onSnapshotStored = ...` line, add:

```swift
                memoryCapture.onDegradation = { [weak self] in
                    self?.escalateDegradationIfNeeded(.memoryCapture)
                }
```

- [ ] **Step 8: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 464 tests PASS (456 + Task 1's 7 + Task 2's 1).

- [ ] **Step 9: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/Memory/MemoryCapture.swift omwhisper-nativeTests/DegradationTests.swift
git commit -m "✨ feat: record polish and capture fallbacks, escalate once when persistent"
```

---

### Task 3: Passive surfaces

**Files:**
- Modify: `omwhisper-native/DebugInfo.swift`
- Modify: `omwhisper-native/UI/AISettingsView.swift`
- Modify: `omwhisper-native/UI/HubMemorySectionView.swift`

**Interfaces:**
- Consumes: `Degradation.debugSummary()`, `Degradation.state(_:)`, `Degradation.Feature`.
- Produces: nothing for later tasks.

No unit tests — Debug Info string assembly and SwiftUI layout are verified live in this project, matching `DebugInfo`'s own precedent (its wording bugs were found by dumping it from the real app, not by tests).

- [ ] **Step 1: Add a Debug Info section**

In `omwhisper-native/DebugInfo.swift`, inside `text(for:)`, immediately before the line that appends the recent log lines section, add:

```swift
        // Degraded features, if any. Omitted entirely when healthy — a wall of
        // zeroes would be noise in something people paste into issues.
        let degraded = Degradation.debugSummary()
        if !degraded.isEmpty {
            out += "\n\nDegraded:\n" + degraded.map { "  \($0)" }.joined(separator: "\n")
        }
```

- [ ] **Step 2: Show the polish streak in AI Polish settings**

In `omwhisper-native/UI/AISettingsView.swift`, immediately after the `if let reason = SystemLLM.unavailableReason() { … }` block inside the Backend `PorcelainSection`, add:

```swift
                // Answers "is polish actually running?" without waiting for a
                // streak to escalate — the question that had no answer for
                // months while Apple Intelligence silently did nothing.
                let polishState = Degradation.state(.polish)
                if polishState.streak > 0 {
                    Text("Polish has fallen back to your raw text \(polishState.streak) time\(polishState.streak == 1 ? "" : "s") in a row. \(polishState.reason ?? "")")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

- [ ] **Step 3: Show the capture streak in the Memory section**

In `omwhisper-native/UI/HubMemorySectionView.swift`, inside `settingsBar`'s `if state.memoryEnabled {` branch, immediately after the `Button("Exclusions…") { showExclusions = true }` modifier chain, add:

```swift
                let captureState = Degradation.state(.memoryCapture)
                if captureState.streak >= 12 {
                    // ~1 minute of ticks. Below that it's ordinary window
                    // switching, not a signal.
                    Text("Capturing nothing")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .help(captureState.reason ?? "")
                }
```

- [ ] **Step 4: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 464 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/DebugInfo.swift omwhisper-native/UI/AISettingsView.swift omwhisper-native/UI/HubMemorySectionView.swift
git commit -m "✨ feat: surface degraded features in settings and Debug Info"
```

- [ ] **Step 6: Live verification — the scenario that cost months**

This Mac is `en-IN`, which Foundation Models does not support, so **polish genuinely cannot run with the System backend**. That makes the real case reproducible rather than simulated.

1. Clear any existing state so the run starts from zero:

```bash
for k in streak reason warned; do
  defaults delete com.omwhisper.mac.dev "degradation.polish.$k" 2>/dev/null
done
defaults read com.omwhisper.mac.dev 2>/dev/null | grep degradation || echo "clean"
```

2. Run the debug build (⌘R). Set **AI Polish → System**.
3. Dictate **ten times**. (Short phrases are fine — what matters is that polish is attempted.)

**Pass:** the first nine produce no degradation alert; the tenth raises exactly one, naming the real cause — *"Apple Intelligence doesn't support your Mac's language (English (India))"* — not a generic failure.
**Fail:** an alert before ten, an alert on every dictation, or a generic message.

4. Dictate an **eleventh** time. **Pass:** no second alert. This is the check that catches nagging.
5. Confirm the passive surface: Hub → AI Polish shows the count and reason without any alert.
6. Confirm the reset: switch AI Polish to **Ollama** and dictate once — it succeeds, and the count on the AI Polish screen returns to nothing.
7. Confirm configuration never counts: set AI Polish to **Disabled**, dictate five times, and check the streak stayed at zero:

```bash
defaults read com.omwhisper.mac.dev degradation.polish.streak 2>/dev/null || echo "0 (correct)"
```

**Fail here would be the worst outcome** — it means the alert will fire at people who deliberately turned polish off.

- [ ] **Step 7: Record the result**

Append the outcome to the Progress Tracker in `CLAUDE.md` — including whether step 7 held — and commit. If any step failed, stop and debug rather than recording the feature as shipped.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Escalating, not passive or immediate | 1 (`shouldEscalate`), 2 (`escalateDegradationIfNeeded`) |
| Scope = polish + memoryCapture only | 1 (`Feature` enum has exactly two cases) |
| Meeting Ask excluded | not implemented — by design; no `Feature` case exists for it |
| Thresholds 10 / 120 | 1 (`threshold`), pinned by `perFeatureThresholds` |
| Configuration is not failure | 2 (`recordUnlessConfiguration`, `configurationReasons`) |
| Streaks persist across relaunches | 1 (`UserDefaults`, not memory) |
| Escalation fires once per streak | 1 (`warned` flag set inside `escalationMessage`) |
| Success clears streak AND flag | 1 (`recordSuccess` → `reset`) |
| Recorder never breaks the feature | 1 — `UserDefaults` calls cannot throw; no path returns early before the fallback's own `return original` |
| Passive surface: settings screens | 3 steps 2–3 |
| Passive surface: Debug Info | 3 step 1 |
| No fallback behaviour changes | 2 — every `return original` is preserved |
| Test that fails if the mechanism is a no-op | 1 (`escalatesAtTheThresholdAndNotBefore`) |
| Live check of the real scenario | 3 step 6 |

**Placeholders:** none — every code step carries full source.

**Type consistency:** `Degradation.Feature` is defined in Task 1 and referenced as `.polish` / `.memoryCapture` in Tasks 2 and 3. `escalateDegradationIfNeeded(_:)` is defined in Task 2 step 5 and called in Task 2 step 7. `state(_:)` returns `(streak: Int, reason: String?)` in Task 1 and is destructured with those labels in Task 3.

**One risk called out rather than designed away:** `Degradation` writes to `UserDefaults` on the polish path, which runs on every dictation. `UserDefaults` writes are cheap and asynchronous to disk, so this is not on the latency-critical paste path in any meaningful way — but if paste latency ever regresses, this is a thing that was added to it, and the sign-off criterion is 700 ms.
