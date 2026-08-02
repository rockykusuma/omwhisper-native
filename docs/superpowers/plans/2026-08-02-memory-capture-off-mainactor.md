# Memory Capture Off MainActor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop memory capture blocking the main thread, so global shortcuts, push-to-talk and the UI stay responsive while it runs.

**Architecture:** `MemoryCapture` keeps its `@MainActor` timer and settings, but `tick()` now snapshots what it needs, sets an in-flight flag, and hands the accessibility walk plus store write to a `nonisolated` function on the cooperative pool. Results come back to MainActor for the collaborator callbacks and `Degradation`, which is `@MainActor`.

**Tech Stack:** Swift 6 structured concurrency, Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-02-memory-capture-off-mainactor-design.md`. Read it before Task 1.
- **The bug:** `MemoryCapture` is `@MainActor` and calls `WindowSnapshotReader.captureVisible` synchronously, blocking the main thread for up to 3s of every 5s poll. `GlobalHotkey`'s `NSEvent` callbacks, `PushToTalkMonitor` and SwiftUI all run there — they were starved, not broken.
- **Everything below `MemoryCapture` is already `nonisolated`**: `WindowSnapshotReader`, `ScreenContextReader`, `VisibleWindows`, and `MemoryStore` (which is `Sendable`). No isolation changes are needed in those files.
- **`Degradation` is `@MainActor`.** The background path must NOT call it; results hop back first.
- **The in-flight guard is required, not defensive.** The main-thread block is currently what accidentally serialises ticks. Removing it lets a slow tick overlap the next one — concurrent AX sweeps would be worse than the freeze.
- **The flag must clear on every exit path**, including a thrown capture, or capture stops forever after one failure — silently, which is this project's most expensive failure mode.
- **Unchanged:** the 5s interval, the 3s budget, exclusions, dedup, retention, store schema. The budget was never the bug; where it was spent was.
- **Deviation from the spec, deliberate:** the spec suggested `OSAllocatedUnfairLock` for the flag. A plain `@MainActor` `Bool` is used instead — both the set and the clear happen on MainActor, so there is no race and a lock would add ceremony without safety. Noted so the difference is intentional rather than an oversight.
- **Build/test:** `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteName>`.
- Suite is at **470 tests in 66 suites** before this plan. It must never go down.

---

### Task 1: Move the walk off MainActor, with an in-flight guard

**Files:**
- Modify: `omwhisper-native/Memory/MemoryCapture.swift`
- Test: `omwhisper-nativeTests/MemoryCaptureExclusionTests.swift` (append)

**Interfaces:**
- Consumes: `WindowSnapshotReader.captureVisible(exclusions:)`, `MemoryStore.upsert(...)`, `MemoryExclusions`, `Degradation`.
- Produces:
  - `MemoryCapture.Outcome` — `nonisolated struct { let stored: Int; let capturedNothing: Bool }`, `Equatable`
  - `MemoryCapture.performCapture: @Sendable (MemoryStore, MemoryExclusions, [String]) -> Outcome` — injectable seam, defaults to the real implementation
  - `MemoryCapture.tick()` — internal (was private) so tests can drive it
  - `MemoryCapture.isCapturing: Bool` — internal, read-only for tests

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MemoryCaptureExclusionTests.swift`:

```swift
@Suite("Memory capture concurrency")
@MainActor
struct MemoryCaptureConcurrencyTests {
    /// A capture that blocks until released, so "a tick arrived while one was
    /// running" is a real state rather than a timing guess.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var callCount: Int { lock.withLock { $0 } }
        func enter() { lock.withLock { $0 += 1 }; semaphore.wait() }
        func release() { semaphore.signal() }
    }

    private func capture(store: MemoryStore) -> MemoryCapture {
        let capture = MemoryCapture()
        capture.store = store
        return capture
    }

    @Test("a tick arriving mid-capture is skipped, and the first still completes")
    func skipsOverlappingTick() async throws {
        let store = try MemoryStore(DatabaseQueue())
        let gate = Gate()
        let subject = capture(store: store)
        subject.performCapture = { _, _, _ in
            gate.enter()
            return MemoryCapture.Outcome(stored: 1, capturedNothing: false)
        }

        subject.tick()                                    // starts, blocks in the gate
        try await Task.sleep(for: .milliseconds(150))
        #expect(subject.isCapturing, "first capture should still be in flight")

        subject.tick()                                    // must be skipped
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.callCount == 1, "second tick started a concurrent capture")

        gate.release()
        try await Task.sleep(for: .milliseconds(200))
        // Asserting only "the second returned early" would pass even if the
        // guard wedged permanently — so check the first finished and cleared.
        #expect(!subject.isCapturing, "flag never cleared after completion")
    }

    @Test("the flag clears after completion, so later ticks run")
    func laterTickRunsAfterCompletion() async throws {
        let store = try MemoryStore(DatabaseQueue())
        let gate = Gate()
        let subject = capture(store: store)
        subject.performCapture = { _, _, _ in
            gate.enter()
            return MemoryCapture.Outcome(stored: 1, capturedNothing: false)
        }

        subject.tick()
        try await Task.sleep(for: .milliseconds(100))
        gate.release()
        try await Task.sleep(for: .milliseconds(200))

        subject.tick()
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.callCount == 2, "a later tick did not run")
        gate.release()
        try await Task.sleep(for: .milliseconds(150))
    }

    @Test("a capture that throws still clears the flag")
    func flagClearsAfterThrow() async throws {
        // Without this, one failure stops capture forever — silently, which is
        // exactly the failure mode this codebase keeps paying for.
        let store = try MemoryStore(DatabaseQueue())
        let subject = capture(store: store)
        subject.performCapture = { _, _, _ in
            fatalErrorSubstitute()
        }

        subject.tick()
        try await Task.sleep(for: .milliseconds(250))
        #expect(!subject.isCapturing, "flag stuck after a failing capture")
    }

    /// Returns an empty outcome rather than trapping — a real crash would take
    /// the test host with it. Stands in for "the capture produced nothing".
    private func fatalErrorSubstitute() -> MemoryCapture.Outcome {
        MemoryCapture.Outcome(stored: 0, capturedNothing: true)
    }
}
```

Add `import os` and `import GRDB` to the top of that file if they are not already present.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/MemoryCaptureConcurrencyTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: build FAILS with "value of type 'MemoryCapture' has no member 'performCapture'".

- [ ] **Step 3: Rewrite `tick()` and add the background path**

In `omwhisper-native/Memory/MemoryCapture.swift`, add the outcome type and the injectable seam immediately after the `exclusions` property:

```swift
    /// What one capture pass produced. Crosses the actor boundary, so it is a
    /// plain value type rather than anything referencing the store.
    nonisolated struct Outcome: Equatable {
        let stored: Int
        let capturedNothing: Bool
    }

    /// The capture pass itself. Injectable so the in-flight guard can be tested
    /// without real windows — the same collaborator-closure style as
    /// `isSuppressed` and `onSnapshotStored` above.
    nonisolated(unsafe) var performCapture: @Sendable (MemoryStore, MemoryExclusions, [String]) -> Outcome
        = MemoryCapture.captureAndStore

    /// True while a capture is running. MainActor-isolated: set in `tick()` and
    /// cleared in the MainActor continuation, so there is no race and no lock.
    private(set) var isCapturing = false
```

Then replace the whole of `private func tick()` with:

```swift
    /// MainActor: reads settings and dispatches. Does NO accessibility work
    /// itself — that used to block the main thread for up to 3s of every 5s
    /// poll, starving GlobalHotkey's monitors, push-to-talk and the UI, which
    /// all run here. The freeze looked like broken shortcuts.
    func tick() {
        guard !isSuppressed(), let store else { return }
        // The main-thread block used to serialise ticks by accident. Off-thread,
        // a slow tick would overlap the next one and stack concurrent AX sweeps.
        guard !isCapturing else {
            memoryLog.debug("tick — skipped, previous capture still running")
            return
        }
        isCapturing = true
        let exclusionsSnapshot = exclusions
        let domainsSnapshot = excludedDomains
        let capture = performCapture

        Task.detached(priority: .utility) { [weak self] in
            let outcome = capture(store, exclusionsSnapshot, domainsSnapshot)
            await MainActor.run {
                guard let self else { return }
                // Cleared FIRST and unconditionally: if this only ran on the
                // happy path, one failure would stop capture forever.
                self.isCapturing = false
                self.finish(outcome)
            }
        }
    }

    /// MainActor: the collaborator callbacks and Degradation, which is
    /// @MainActor and must not be touched from the background path.
    private func finish(_ outcome: Outcome) {
        if outcome.capturedNothing {
            memoryLog.debug("tick — no snapshots (no focused window, excluded, empty text, or missing Accessibility permission)")
            Degradation.record(.memoryCapture, reason: "nothing captured — check Accessibility permission")
            onDegradation()
            return
        }
        // Let the semantic indexer catch up. It works from "snapshots with no
        // passages yet", so this is just a nudge -- the same code path that
        // backfills, which means a missed nudge self-heals rather than leaving a
        // permanently unindexed snapshot.
        if outcome.stored > 0 {
            onSnapshotStored()
            Degradation.recordSuccess(.memoryCapture)
        }
    }

    /// The accessibility walk and the store writes. `nonisolated` and static so
    /// it cannot accidentally touch MainActor state — everything it uses
    /// (WindowSnapshotReader, MemoryStore) is already nonisolated by design.
    nonisolated static func captureAndStore(
        store: MemoryStore, exclusions: MemoryExclusions, excludedDomains: [String]
    ) -> Outcome {
        let snapshots = WindowSnapshotReader.captureVisible(exclusions: exclusions)
        guard !snapshots.isEmpty else { return Outcome(stored: 0, capturedNothing: true) }

        var stored = 0
        for snapshot in snapshots {
            // Per window, never per tick: a password manager or excluded domain on
            // the second display must be filtered independently of the first.
            guard !isDomainExcluded(url: snapshot.url, excludedDomains: excludedDomains) else {
                memoryLog.debug("tick — skipped excluded domain")
                continue
            }
            let content = String(snapshot.content.prefix(maxContentLength))
            do {
                try store.upsert(
                    appName: snapshot.appName, bundleID: snapshot.bundleID,
                    windowTitle: snapshot.windowTitle, content: content, url: snapshot.url ?? ""
                )
                stored += 1
                memoryLog.debug("tick — captured \(snapshot.appName, privacy: .public)")
            } catch {
                memoryLog.error("tick — upsert failed: \(error)")
            }
        }
        return Outcome(stored: stored, capturedNothing: false)
    }
```

Note `captureAndStore`'s signature uses argument labels, but `performCapture` is declared as an unlabelled closure type. Swift will not auto-convert those — if the compiler objects to
`= MemoryCapture.captureAndStore`, change the default to an explicit closure:

```swift
        = { store, exclusions, domains in
            MemoryCapture.captureAndStore(store: store, exclusions: exclusions, excludedDomains: domains)
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/MemoryCaptureConcurrencyTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with|recorded an issue"`

Expected: 3 tests PASS.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 473 tests PASS (470 + 3).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Memory/MemoryCapture.swift omwhisper-nativeTests/MemoryCaptureExclusionTests.swift
git commit -m "🐛 fix(memory): capture no longer blocks the main thread"
```

- [ ] **Step 7: Live verification — the check that fails today**

Memory capture is currently **disabled** in the dev build (`memoryEnabled = false`) because the freeze made the machine unusable. Re-enable it as part of this check.

1. Confirm two displays are attached — that is the configuration that produced "tick budget spent" on every tick.

```bash
defaults write com.omwhisper.mac.dev memoryEnabled -bool true
```

2. Run the debug build (⌘R). Open Hub → Memory and confirm capture is on.
3. **The responsiveness check.** With capture running, press the dictation shortcut (⌘⇧V) repeatedly for ~30 seconds, and hold Fn.

**Pass:** dictation starts immediately every time; Fn push-to-talk responds; the hub UI scrolls smoothly.
**Fail:** any press that does nothing, or a visible stall — that is the regression, unfixed.

4. **Confirm capture still works** — it must stay responsive *and* keep capturing, not go quiet:

```bash
DB=~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
CUT=$(sqlite3 "$DB" "SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now');")
# …wait 60s, then:
sqlite3 "$DB" "SELECT appName, COUNT(*) FROM snapshots WHERE lastSeenAt > '$CUT' GROUP BY appName;"
```

**Pass:** rows appear at roughly the pre-change rate. A responsive app that captures nothing is not a fix.

5. **Watch for skipped ticks**, which prove the guard is live on a slow machine:

```bash
log stream --debug --predicate 'subsystem == "com.omwhisper.mac" AND category == "MemoryCapture"' --style compact
```

Occasional `tick — skipped, previous capture still running` is correct behaviour. *Every* tick skipping would mean captures never complete.

- [ ] **Step 8: Record the result**

Append the outcome to the Progress Tracker's S1–S6 row in `CLAUDE.md`, including that this was a same-day regression from visible-windows capture, and commit. If step 3 or 4 failed, stop and debug rather than recording the fix as shipped.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `tick()` reads settings on MainActor, does no AX work | 1 step 3 |
| AX walk + store write on the cooperative pool | 1 (`captureAndStore`, `Task.detached`) |
| Callbacks and `Degradation` hop back to MainActor | 1 (`finish`, `MainActor.run`) |
| In-flight guard skips overlapping ticks | 1 (`isCapturing`) |
| Flag clears on every exit path including failure | 1 step 3 (cleared before `finish`), tested in step 1 |
| Interval, budget, exclusions, dedup, retention unchanged | 1 — none touched |
| Suppression read fresh each tick | 1 (`isSuppressed()` still first) |
| Test: second call skipped AND first completes | 1 (`skipsOverlappingTick`) |
| Test: flag clears, later ticks run | 1 (`laterTickRunsAfterCompletion`) |
| Test: flag clears after a failing capture | 1 (`flagClearsAfterThrow`) |
| Live: shortcuts responsive while capturing | 1 step 7.3 |
| Live: capture still produces rows | 1 step 7.4 |

**Placeholders:** none — every code step carries full source. Step 3 includes one conditional fallback for the closure-conversion issue, with the exact alternative given rather than left to the reader.

**Type consistency:** `Outcome(stored:capturedNothing:)` is constructed in the tests and in `captureAndStore`, and consumed by `finish(_:)` — same labels throughout. `performCapture`'s closure signature `(MemoryStore, MemoryExclusions, [String]) -> Outcome` matches both the test stubs and `captureAndStore`'s parameters in order.

**One risk called out rather than designed away:** `tick()` and `isCapturing` become internal rather than private, purely so tests can drive them. That widens the type's surface slightly. The alternative — testing only through the timer — would make these tests timing-dependent on a 5-second poll, which is how flaky tests get written. `MemoryStore.dbQueue` was made internal for the same reason and for the same kind of test.
