# Chronicles via Ollama Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let chronicles be written by Ollama, so a Mac whose locale Foundation Models doesn't support can still generate them.

**Architecture:** `Chronicler.generate` gains a `chunkLimit` parameter (Ollama gets 12,000 characters, `SystemLLM` keeps 1,800). `AppState.chronicleBackends()` returns candidates in preference order, mirroring the existing `meetingSummaryBackends()`. `ChronicleScheduler` stops holding a `PolishBackend` captured at wiring time and instead calls a closure, so the backend is chosen when the timer fires.

**Tech Stack:** Swift 6, Swift Testing, `os.Logger`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-01-chronicles-ollama-design.md`. Read it before Task 1.
- **Cloud is NEVER a chronicle backend**, whatever `polishBackend` is set to. Enforced in code — `chronicleBackends()` has no `.cloud` case at all. Memory is local-only.
- **Mirror `meetingSummaryBackends()` (`AppState.swift:685-694`) exactly** — same ordering (Ollama first when selected and a model is set, then `SystemLLM` when available), same "first candidate that produces a result wins" loop. Do not invent a second scheme.
- **Chunk limits:** `SystemLLM` = `Chronicler.chunkCharLimit` (1,800). Ollama = **12,000**, matching `MeetingSummarizer.ollamaChunkLimit`.
- **Never say "Apple Intelligence is off" when it is on.** Messages come from `AppState.systemUnavailableMessage(_:)`, which is built on `SystemLLM.unavailableReason()`. The three outcomes — no candidates / all candidates failed / no snapshots — must stay distinguishable.
- **`nonisolated`.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on. `Chronicler` is already `nonisolated`; anything new it touches must be too.
- **Do not unit-test backend ordering.** Constructing `AppState` opens the real history/memory stores — the same trap that had `KeychainTests` deleting real API keys. `meetingSummaryBackends()` is untested for the same reason. Verified live instead.
- **Build/test:** `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteName>`.
- Suite is at **437 tests in 58 suites** before this plan. It must never go down.

---

### Task 1: `Chronicler.generate` honours a chunk limit

**Files:**
- Modify: `omwhisper-native/Memory/Chronicler.swift`
- Test: `omwhisper-nativeTests/ChroniclerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Chronicler.generate(day:store:polish:chunkLimit:)` where `chunkLimit: Int = chunkCharLimit`.

- [ ] **Step 1: Write the failing test**

Append to `omwhisper-nativeTests/ChroniclerTests.swift`, at the very end of the file (after the existing `private struct StubPolishBackend`):

```swift
/// Counts polish() calls so a chunk-limit change is measurable. A class with a
/// lock rather than a struct: PolishBackend is Sendable and polish() is
/// non-mutating, so there is nowhere to put a counter otherwise. Matches
/// AudioCapture's established lock-not-actor-isolation pattern.
private final class CountingPolishBackend: PolishBackend, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var callCount: Int { lock.withLock { $0 } }

    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        lock.withLock { $0 += 1 }
        return style.id == Chronicler.chunkSummaryStyle.id ? "- did some work" : "STUB CHRONICLE"
    }
}

struct ChronicleChunkLimitTests {
    /// One snapshot per row, each comfortably under the per-snapshot cap, but
    /// enough of them that 1,800-char chunking needs several passes.
    private func seed(_ store: MemoryStore, count: Int) throws {
        for i in 0..<count {
            try store.upsert(
                appName: "App\(i)", bundleID: "com.example.app\(i)",
                windowTitle: "Window \(i)",
                content: String(repeating: "alpha beta gamma delta ", count: 20) + "row\(i)",
                url: ""
            )
        }
    }

    @Test func biggerChunkLimitMeansFewerModelCalls() async throws {
        let day = Chronicler.dayString()

        let smallStore = try MemoryStore(inMemory: true)
        try seed(smallStore, count: 12)
        let small = CountingPolishBackend()
        _ = try await Chronicler.generate(day: day, store: smallStore, polish: small,
                                          chunkLimit: Chronicler.chunkCharLimit)

        let bigStore = try MemoryStore(inMemory: true)
        try seed(bigStore, count: 12)
        let big = CountingPolishBackend()
        _ = try await Chronicler.generate(day: day, store: bigStore, polish: big,
                                          chunkLimit: 12_000)

        // The assertion that fails if chunkLimit is accepted and ignored.
        // "it still produced a chronicle" would pass either way.
        #expect(big.callCount < small.callCount,
                "12k limit made \(big.callCount) calls, 1.8k made \(small.callCount)")
        #expect(big.callCount >= 1)
    }

    @Test func defaultLimitIsUnchanged() async throws {
        // Pins that omitting the parameter still behaves as it did before.
        let day = Chronicler.dayString()
        let explicitStore = try MemoryStore(inMemory: true)
        try seed(explicitStore, count: 12)
        let explicit = CountingPolishBackend()
        _ = try await Chronicler.generate(day: day, store: explicitStore, polish: explicit,
                                          chunkLimit: Chronicler.chunkCharLimit)

        let defaultStore = try MemoryStore(inMemory: true)
        try seed(defaultStore, count: 12)
        let byDefault = CountingPolishBackend()
        _ = try await Chronicler.generate(day: day, store: defaultStore, polish: byDefault)

        #expect(byDefault.callCount == explicit.callCount)
    }
}
```

Add `import os` to the top of `ChroniclerTests.swift` if it is not already there (needed for `OSAllocatedUnfairLock`).

**Before running:** check how `ChroniclerTests`' existing tests construct a `MemoryStore`. If there is no `MemoryStore(inMemory:)` initializer, use whatever the existing tests use (a temp-directory store) and mirror it in `seed`'s two call sites. Do not invent an initializer.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ChronicleChunkLimitTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: build FAILS with "extra argument 'chunkLimit' in call".

- [ ] **Step 3: Add the parameter**

In `omwhisper-native/Memory/Chronicler.swift`, change the `generate` signature and use `chunkLimit` in place of both constants inside the body:

```swift
    static func generate(
        day: String, store: MemoryStore, polish: PolishBackend,
        chunkLimit: Int = chunkCharLimit
    ) async throws -> ChronicleResult {
        let snapshots = try store.snapshotsForDay(day)
        guard !snapshots.isEmpty else {
            throw ChroniclerError.noSnapshots
        }
        let blocks = snapshots.map(formatBlock)
        let chunks = chunk(blocks, limit: chunkLimit)

        var chunkSummaries: [String] = []
        for group in chunks {
            let text = String(group.joined(separator: "\n\n").prefix(chunkLimit))
            let summary = try await polish.polish(text, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
        }
```

and in the collapse loop plus the reduce line below it, replace every `reduceCharLimit` with `chunkLimit`:

```swift
        while chunkSummaries.joined(separator: "\n").count > chunkLimit && chunkSummaries.count > 1 {
            var collapsed: [String] = []
            for group in chunk(chunkSummaries, limit: chunkLimit) {
                let text = String(group.joined(separator: "\n\n").prefix(chunkLimit))
                collapsed.append(try await polish.polish(text, style: chunkSummaryStyle, targetLanguage: nil))
            }
            if collapsed.count >= chunkSummaries.count { break }
            chunkSummaries = collapsed
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(chunkLimit))
```

Leave `reduceCharLimit`'s declaration in place — it is still the documented default's twin and removing it is churn. Add a note above the constants:

```swift
    /// Both default to Foundation Models' safe envelope. `generate(chunkLimit:)`
    /// overrides them together -- Ollama takes 12,000 (MeetingSummarizer's own
    /// ollamaChunkLimit), which collapses a busy day in far fewer passes and so
    /// loses less to repeated summarising.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ChronicleChunkLimitTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: 2 tests PASS.

- [ ] **Step 5: Run the whole Chronicler suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ChroniclerTests 2>&1 | grep -E "^.*error: |Test run with|recorded an issue"`

Expected: PASS. The existing collapse-loop regression test (the one that traces the day's last block into the final reduce input) is the guard against reintroducing the truncation bug — it must still pass.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Memory/Chronicler.swift omwhisper-nativeTests/ChroniclerTests.swift
git commit -m "✨ feat(memory): Chronicler.generate takes a chunk limit"
```

---

### Task 2: Choose a chronicle backend, and say why when there isn't one

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `Chronicler.generate(day:store:polish:chunkLimit:)`, `AppState.systemUnavailableMessage(_:)`, `Chronicler.ChroniclerError.backendUnavailable(String)`.
- Produces:
  - `AppState.chronicleBackends() -> [(polish: PolishBackend, chunkLimit: Int)]`
  - `AppState.generateChronicle(day: String) async throws -> Chronicler.ChronicleResult`
  - `AppState.regenerateChronicle(day:)` keeps its existing signature and now delegates.

- [ ] **Step 1: Replace `regenerateChronicle` and add the candidate list**

In `omwhisper-native/AppState.swift`, replace the whole `regenerateChronicle(day:)` function with:

```swift
    /// Chronicle backends in preference order, mirroring meetingSummaryBackends().
    /// Cloud is deliberately absent and must stay absent: memory is the most
    /// sensitive store in this app and never leaves the device, whatever the
    /// polish backend is set to.
    private func chronicleBackends() -> [(polish: PolishBackend, chunkLimit: Int)] {
        var candidates: [(polish: PolishBackend, chunkLimit: Int)] = []
        if polishBackend == .ollama, !ollamaModel.isEmpty {
            candidates.append((Ollama(baseURL: ollamaBaseURL, model: ollamaModel),
                               Chronicler.ollamaChunkLimit))
        }
        if SystemLLM.isAvailable() {
            candidates.append((systemLLM, Chronicler.chunkCharLimit))
        }
        return candidates
    }

    /// First candidate that writes a chronicle wins. The three failure modes are
    /// deliberately distinguishable: no backend at all, every backend failed, and
    /// nothing captured that day are different problems with different fixes.
    func generateChronicle(day: String) async throws -> Chronicler.ChronicleResult {
        guard let memoryStore else { throw Chronicler.ChroniclerError.noSnapshots }
        let candidates = chronicleBackends()
        guard !candidates.isEmpty else {
            throw Chronicler.ChroniclerError.backendUnavailable(
                systemUnavailableMessage("write chronicles")
            )
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                return try await Chronicler.generate(
                    day: day, store: memoryStore, polish: candidate.polish,
                    chunkLimit: candidate.chunkLimit
                )
            } catch let error as Chronicler.ChroniclerError {
                // No snapshots is about the day, not the backend -- trying a
                // second backend cannot help and would hide the real reason.
                throw error
            } catch {
                lastError = error
            }
        }
        throw Chronicler.ChroniclerError.backendUnavailable(
            "Couldn't write a chronicle — the on-device model failed. \(lastError?.localizedDescription ?? "")"
                .trimmingCharacters(in: .whitespaces)
        )
    }

    func regenerateChronicle(day: String) async throws -> Chronicler.ChronicleResult {
        try await generateChronicle(day: day)
    }
```

- [ ] **Step 2: Add the Ollama chunk limit constant**

In `omwhisper-native/Memory/Chronicler.swift`, beside the existing limits:

```swift
    /// Ollama's context is far larger than Foundation Models', so a day collapses
    /// in fewer passes. Same value as MeetingSummarizer.ollamaChunkLimit -- these
    /// two are the same trade-off and should not drift apart.
    static let ollamaChunkLimit = 12_000
```

- [ ] **Step 3: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 439 tests PASS (437 + Task 1's 2).

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/Memory/Chronicler.swift
git commit -m "✨ feat(memory): chronicles pick Ollama or SystemLLM, never Cloud"
```

---

### Task 3: The scheduler must choose its backend when it fires

This is the load-bearing task. `ChronicleScheduler` currently holds a `PolishBackend` assigned once, when Memory was enabled — so a user who later switches to Ollama still gets the `systemLLM` it captured, and the nightly chronicle keeps failing.

**Files:**
- Modify: `omwhisper-native/Memory/ChronicleScheduler.swift`
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `AppState.generateChronicle(day:)`.
- Produces: `ChronicleScheduler.generate: (String) async throws -> Void`, replacing `ChronicleScheduler.polish`.

- [ ] **Step 1: Replace the scheduler's backend with a closure**

In `omwhisper-native/Memory/ChronicleScheduler.swift`, replace the `polish` property and `generateIfNeeded()`:

```swift
    var store: MemoryStore?
    /// Supplied by AppState, which picks a backend at CALL time. This used to be
    /// a `PolishBackend` assigned once when Memory was enabled -- so switching
    /// the polish backend afterwards changed nothing and the nightly chronicle
    /// kept failing against the backend captured at wiring time.
    var generate: ((String) async throws -> Void)?
    var isSuppressed: () -> Bool = { false }
```

and:

```swift
    private func generateIfNeeded() async {
        guard !isSuppressed(), let store, let generate else { return }
        let yesterday = Chronicler.dayString(daysAgo: 1)
        guard (try? store.getChronicle(day: yesterday)) == nil else { return }
        do {
            try await generate(yesterday)
        } catch {
            chronicleLog.error("generateIfNeeded — failed for \(yesterday): \(error)")
        }
    }
```

Also update the file's header comment, which currently says the scheduler "needs a PolishBackend":

```swift
//  Deliberately separate from Chronicler (pure logic) and MemoryCapture (raw
//  capture/prune) -- this owns the daily trigger only; which backend writes the
//  chronicle is AppState's decision, made when the timer fires.
```

- [ ] **Step 2: Rewire it in `AppState`**

In `omwhisper-native/AppState.swift`, in the `memoryEnabled` setter's `if newValue {` block, replace the two lines assigning `chronicleScheduler.polish` and `chronicleScheduler.isSuppressed`:

```swift
                chronicleScheduler.store = memoryStore
                chronicleScheduler.generate = { [weak self] day in
                    _ = try await self?.generateChronicle(day: day)
                }
                // Suppressed only when NO backend can write one. This used to be
                // `polishBackend != .system`, which disabled the nightly chronicle
                // for every Ollama user even though Ollama can write it.
                chronicleScheduler.isSuppressed = { [weak self] in
                    self?.chronicleBackends().isEmpty ?? true
                }
                chronicleScheduler.start()
```

`chronicleBackends()` is `private` from Task 2; that is fine — this closure is inside `AppState`.

- [ ] **Step 3: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 439 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/Memory/ChronicleScheduler.swift omwhisper-native/AppState.swift
git commit -m "🐛 fix(memory): scheduler picks its chronicle backend when it fires"
```

- [ ] **Step 5: Live verification — a check that fails today**

This machine's locale is `en_IN`, which Foundation Models does not support, so `SystemLLM.isAvailable()` is `false` and **chronicles cannot be generated at all before this change**. That makes the check genuinely falsifiable.

1. Confirm Ollama is running and a model is pulled:

```bash
curl -s http://localhost:11434/api/tags | head -c 400
```

If this returns nothing, Ollama is not running — start it and pull a model before continuing. Do not skip to "it errored, so the feature works".

2. Run the debug build (⌘R). In Hub → AI Polish, select **Ollama** and pick the pulled model. Confirm Test Connection succeeds.
3. Hub → Memory → Chronicles → **Generate today**.

**Pass:** a real chronicle appears, written from actual captured snapshots.
**Fail:** the previous alert ("An unsupported language or locale was used") — that means the Ollama candidate was never tried.

4. Now switch the AI backend to **System** and press Generate today again.

**Pass:** an alert naming the real cause — "Apple Intelligence doesn't support your Mac's language (English (India)). Select Ollama in Settings › AI to write chronicles." **Not** "Apple Intelligence is off".

5. Confirm Cloud is never used: switch the AI backend to **Cloud** (a key need not be saved) and press Generate today.

**Pass:** it does *not* attempt a cloud call — the message names the on-device situation. Memory must never egress. If a chronicle is produced here, that is a privacy defect, not a success.

- [ ] **Step 6: Record the result**

Append the outcome to the Progress Tracker's S1–S6 row in `CLAUDE.md` and commit. If step 3 or step 5 failed, stop and debug rather than recording the feature as shipped.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Ollama when selected + model set; SystemLLM otherwise and as retry | 2 |
| Cloud never a chronicle backend | 2 (no `.cloud` case), 3 step 5 (live proof) |
| Chunk limit travels with the backend (1,800 / 12,000) | 1 (parameter), 2 (constant + wiring) |
| `Chronicler.generate` gains `chunkLimit`, used for chunk **and** reduce | 1 step 3 |
| `chronicleBackends()` mirrors `meetingSummaryBackends()` | 2 |
| `regenerateChronicle` iterates candidates | 2 |
| Scheduler picks backend at fire time, not wiring time | 3 |
| `isSuppressed` becomes "no usable backend" | 3 step 2 |
| Three distinct failure messages | 2 (all three paths) |
| Test that fails if `chunkLimit` is ignored | 1 step 1 |
| Collapse-loop regression test still passes at both limits | 1 step 5 |
| Backend ordering deliberately not unit-tested | Global Constraints |

**Placeholders:** none — every code step carries full source. Task 1 step 1 contains one explicit instruction to check the existing `MemoryStore` construction idiom rather than invent an initializer; that is a verification instruction, not a gap.

**Type consistency:** `chronicleBackends()` returns `[(polish: PolishBackend, chunkLimit: Int)]` in Task 2 and is called with `.isEmpty` in Task 3. `Chronicler.ollamaChunkLimit` is declared in Task 2 step 2 and used in Task 2 step 1 — **note the ordering**: step 1 will not compile until step 2 is applied, which is why step 3 is the first build. `ChronicleScheduler.generate` replaces `.polish` in Task 3 and is assigned in the same task, so no window exists where `AppState` references a removed property.

**One risk called out rather than designed away:** `generateChronicle` rethrows `ChroniclerError` immediately instead of trying the next candidate. That is correct for `.noSnapshots` (a second backend cannot conjure snapshots) but it also means a `.backendUnavailable` thrown from inside `Chronicler` would short-circuit. `Chronicler` never throws that case itself today — only `AppState` constructs it — so the behaviour is right; if `Chronicler` ever starts throwing it, this loop needs revisiting.
