# Chronicle Input Reduction + Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a day of ~1,400 snapshots chronicle in a handful of model calls instead of ~60, and make the run visible and stoppable.

**Architecture:** A new pure `Chronicler.select` keeps the most substantial snapshot per (15-minute bucket, app) and hands only those to the existing pipeline — chunking, the collapse loop and storage are untouched. `generate` gains a progress callback and cancellation checks; `AppState` owns the running `Task` so both the button and the nightly scheduler report progress and can be stopped.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-02-chronicle-input-reduction-design.md`. Read it before Task 1.
- **Measured baseline (2026-08-01):** 1,429 snapshots · 17 apps · 117 windows · 26 fifteen-minute buckets · Orca+Arc = 80%. Expected after selection: **~100–150 blocks**.
- **Defaults:** `bucketMinutes = 15`, `cap = 400`, keep-longest-`content` within a group.
- **Chronological order is preserved** — a chronicle describes a day in sequence.
- **Window titles survive even where bodies do not.** The kept block lists other titles seen in its (bucket, app) group; titles are the highest-signal content per character.
- **Cancelling writes nothing.** A partial chronicle is worse than none. Cancelling is not an error and must not surface one.
- **Do not change** backend selection, chunk limits, the collapse loop, timeouts, storage, the daily schedule, or the local-day boundary.
- **`nonisolated`.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on; `Chronicler` is already `nonisolated` and anything it touches must be too.
- **Timestamps are ISO8601 UTC strings** (`lastSeenAt`), e.g. `2026-08-01T09:07:31Z`. Bucketing must parse them, not slice strings.
- **Build/test:** `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteName>`.
- Suite is at **446 tests in 62 suites** before this plan. It must never go down.

---

### Task 1: The pure selection

**Files:**
- Modify: `omwhisper-native/Memory/Chronicler.swift`
- Test: `omwhisper-nativeTests/ChroniclerTests.swift`

**Interfaces:**
- Consumes: `MemorySnapshot` (fields: `id`, `appName`, `bundleID`, `windowTitle`, `content`, `url`, `contentHash`, `capturedAt`, `lastSeenAt`).
- Produces:
  - `Chronicler.select(_ snapshots: [MemorySnapshot], bucketMinutes: Int = 15, cap: Int = 400) -> [Selected]`
  - `Chronicler.Selected` — `nonisolated struct` with `snapshot: MemorySnapshot` and `otherTitles: [String]`, `Equatable`
  - `Chronicler.defaultBucketMinutes = 15`, `Chronicler.defaultCap = 400`

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/ChroniclerTests.swift`, at the end of the file:

```swift
@Suite("Chronicler selection")
struct ChronicleSelectionTests {
    private func snap(
        _ id: Int64, app: String, title: String = "w", content: String = "body",
        at iso: String
    ) -> MemorySnapshot {
        MemorySnapshot(
            id: id, appName: app, bundleID: "com.example.\(app)", windowTitle: title,
            content: content, url: "", contentHash: "h\(id)", capturedAt: iso, lastSeenAt: iso)
    }

    @Test("two snapshots of one app in one bucket collapse to one")
    func collapsesWithinBucket() {
        let picked = Chronicler.select([
            snap(1, app: "Arc", content: "short", at: "2026-08-01T09:01:00Z"),
            snap(2, app: "Arc", content: "much longer body here", at: "2026-08-01T09:07:00Z"),
        ])
        #expect(picked.count == 1)
        // Longest content wins -- the most substantial capture, not an arbitrary one.
        #expect(picked.first?.snapshot.id == 2)
    }

    @Test("two apps in the same bucket both survive")
    func keepsEachAppInABucket() {
        let picked = Chronicler.select([
            snap(1, app: "Arc", at: "2026-08-01T09:01:00Z"),
            snap(2, app: "Code", at: "2026-08-01T09:02:00Z"),
        ])
        #expect(picked.count == 2)
        #expect(Set(picked.map(\.snapshot.appName)) == ["Arc", "Code"])
    }

    @Test("a bucket boundary splits the same app")
    func splitsAcrossBucketBoundary() {
        let picked = Chronicler.select([
            snap(1, app: "Arc", at: "2026-08-01T09:14:59Z"),
            snap(2, app: "Arc", at: "2026-08-01T09:15:01Z"),
        ])
        #expect(picked.count == 2)
    }

    @Test("output stays in chronological order")
    func preservesChronology() {
        let picked = Chronicler.select([
            snap(3, app: "Code", at: "2026-08-01T11:00:00Z"),
            snap(1, app: "Arc", at: "2026-08-01T09:00:00Z"),
            snap(2, app: "Orca", at: "2026-08-01T10:00:00Z"),
        ])
        #expect(picked.map(\.snapshot.id) == [1, 2, 3])
    }

    @Test("other window titles in a group survive even though their bodies don't")
    func keepsOtherTitles() {
        let picked = Chronicler.select([
            snap(1, app: "Code", title: "Chronicler.swift", content: "aaa", at: "2026-08-01T09:01:00Z"),
            snap(2, app: "Code", title: "AppState.swift", content: "a much longer body", at: "2026-08-01T09:02:00Z"),
            snap(3, app: "Code", title: "Ollama.swift", content: "bb", at: "2026-08-01T09:03:00Z"),
        ])
        #expect(picked.count == 1)
        #expect(picked.first?.snapshot.windowTitle == "AppState.swift")
        #expect(Set(picked.first?.otherTitles ?? []) == ["Chronicler.swift", "Ollama.swift"])
    }

    @Test("empty input returns empty")
    func emptyInput() {
        #expect(Chronicler.select([]).isEmpty)
    }

    @Test("a real day's volume reduces to a bounded count")
    func reducesARealDay() {
        // The measured shape of 2026-08-01: 1,429 snapshots, 17 apps, 26 buckets.
        // This is the test that fails if select() is a no-op -- asserting only
        // that it "returns something" would pass either way.
        var day: [MemorySnapshot] = []
        var id: Int64 = 0
        for bucket in 0..<26 {
            for appIndex in 0..<17 {
                for repeatIndex in 0..<4 {
                    id += 1
                    let minute = bucket * 15 + (repeatIndex % 15)
                    let iso = String(format: "2026-08-01T%02d:%02d:00Z", 6 + minute / 60, minute % 60)
                    day.append(snap(id, app: "App\(appIndex)", title: "w\(repeatIndex)",
                                    content: String(repeating: "x", count: 100 + repeatIndex), at: iso))
                }
            }
        }
        #expect(day.count == 26 * 17 * 4)
        let picked = Chronicler.select(day)
        #expect(picked.count < day.count / 3, "selected \(picked.count) of \(day.count)")
        #expect(picked.count >= 17, "must keep at least one entry per app")
    }

    @Test("the cap is enforced and drops from across the day, not just the tail")
    func capSpreadsAcrossTheDay() {
        var day: [MemorySnapshot] = []
        for i in 0..<300 {
            let iso = String(format: "2026-08-01T%02d:%02d:00Z", 0 + i / 60, i % 60)
            day.append(snap(Int64(i), app: "App\(i)", at: iso))
        }
        let picked = Chronicler.select(day, cap: 50)
        #expect(picked.count == 50)
        // A tail-truncating cap would keep only the earliest hour.
        let lastKept = picked.last?.snapshot.lastSeenAt ?? ""
        #expect(lastKept > "2026-08-01T03:00:00Z", "cap dropped the whole later day: \(lastKept)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ChronicleSelectionTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: build FAILS with "type 'Chronicler' has no member 'select'".

- [ ] **Step 3: Write the implementation**

In `omwhisper-native/Memory/Chronicler.swift`, add after the `ollamaChunkLimit` declaration:

```swift
    static let defaultBucketMinutes = 15
    static let defaultCap = 400

    /// One representative capture, plus the other window titles seen alongside
    /// it. Titles are the highest-signal content per character in a snapshot
    /// (file names, page titles), so they survive even when their bodies don't.
    nonisolated struct Selected: Equatable {
        let snapshot: MemorySnapshot
        let otherTitles: [String]
    }

    /// Pure: the day's snapshots -> the subset worth sending to a model.
    ///
    /// Measured on the real store 2026-08-01: 1,429 snapshots describe 117
    /// windows across 26 fifteen-minute buckets, and two apps account for 80%
    /// of them. Feeding all of it cost ~60 sequential model calls for one
    /// paragraph -- and the collapse loop then threw most of it away anyway.
    /// Reducing here does that discarding cheaply, and keeps the day's SHAPE
    /// (which apps, in what order) which is what a chronicle is for.
    static func select(
        _ snapshots: [MemorySnapshot],
        bucketMinutes: Int = defaultBucketMinutes,
        cap: Int = defaultCap
    ) -> [Selected] {
        guard !snapshots.isEmpty else { return [] }
        let parser = ISO8601DateFormatter()

        // Group by (bucket, app). A snapshot whose timestamp won't parse gets
        // its own bucket rather than being dropped -- losing a capture is worse
        // than keeping a redundant one.
        var groups: [String: [MemorySnapshot]] = [:]
        var groupOrder: [String] = []
        for snapshot in snapshots {
            let key: String
            if let date = parser.date(from: snapshot.lastSeenAt) {
                let bucket = Int(date.timeIntervalSince1970) / (bucketMinutes * 60)
                key = "\(bucket)|\(snapshot.appName)"
            } else {
                key = "unparsed|\(snapshot.lastSeenAt)|\(snapshot.appName)"
            }
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(snapshot)
        }

        var picked: [Selected] = []
        for key in groupOrder {
            guard let members = groups[key], let best = members.max(by: { $0.content.count < $1.content.count })
            else { continue }
            let others = members
                .filter { $0.id != best.id && !$0.windowTitle.isEmpty && $0.windowTitle != best.windowTitle }
                .map(\.windowTitle)
            // Deduped, order-stable: several captures of one window are one title.
            var seen: Set<String> = []
            let otherTitles = others.filter { seen.insert($0).inserted }
            picked.append(Selected(snapshot: best, otherTitles: otherTitles))
        }

        picked.sort { $0.snapshot.lastSeenAt < $1.snapshot.lastSeenAt }
        guard picked.count > cap else { return picked }

        // Even stride, not a prefix: truncating would drop the whole later day.
        let stride = Double(picked.count) / Double(cap)
        return (0..<cap).map { picked[min(picked.count - 1, Int(Double($0) * stride))] }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ChronicleSelectionTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with|recorded an issue"`

Expected: 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/Chronicler.swift omwhisper-nativeTests/ChroniclerTests.swift
git commit -m "✨ feat(memory): pure snapshot selection for chronicles"
```

---

### Task 2: Wire selection into generation, with progress and cancellation

**Files:**
- Modify: `omwhisper-native/Memory/Chronicler.swift`
- Test: `omwhisper-nativeTests/ChroniclerTests.swift`

**Interfaces:**
- Consumes: `Chronicler.select(_:bucketMinutes:cap:)`, `Chronicler.Selected`.
- Produces:
  - `Chronicler.formatBlock(_ selected: Selected) -> String` (new overload; the existing `formatBlock(_ snapshot: MemorySnapshot)` stays for its tests)
  - `Chronicler.generate(day:store:polish:chunkLimit:onProgress:)` where `onProgress: ((Int, Int) -> Void)? = nil`

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/ChroniclerTests.swift`:

```swift
@Suite("Chronicler progress")
struct ChronicleProgressTests {
    @Test("the block names the other windows from its group")
    func blockIncludesOtherTitles() {
        let snapshot = MemorySnapshot(
            id: 1, appName: "Code", bundleID: "com.example.code", windowTitle: "AppState.swift",
            content: "editing", url: "", contentHash: "h", capturedAt: "2026-08-01T09:00:00Z",
            lastSeenAt: "2026-08-01T09:00:00Z")
        let block = Chronicler.formatBlock(
            Chronicler.Selected(snapshot: snapshot, otherTitles: ["Ollama.swift", "Chronicler.swift"]))
        #expect(block.contains("AppState.swift"))
        #expect(block.contains("Ollama.swift"))
        #expect(block.contains("Chronicler.swift"))
        #expect(block.contains("editing"))
    }

    @Test("progress is monotonic and ends at the total")
    func reportsProgress() async throws {
        let store = try MemoryStore(DatabaseQueue())
        for i in 0..<40 {
            try store.upsert(appName: "App\(i % 4)", bundleID: "com.example.a\(i % 4)",
                             windowTitle: "w\(i)",
                             content: String(repeating: "alpha beta gamma ", count: 30) + "\(i)",
                             url: "")
        }
        let reports = OSAllocatedUnfairLock(initialState: [(Int, Int)]())
        _ = try await Chronicler.generate(
            day: Chronicler.dayString(), store: store, polish: StubPolish(),
            chunkLimit: 400,
            onProgress: { done, total in reports.withLock { $0.append((done, total)) } })

        let seen = reports.withLock { $0 }
        #expect(!seen.isEmpty, "no progress was reported")
        #expect(seen.allSatisfy { $0.1 > 0 }, "total must be known when reporting")
        let dones = seen.map(\.0)
        #expect(dones == dones.sorted(), "progress went backwards: \(dones)")
        #expect(dones.last == seen.last?.1, "final progress should equal the total")
    }
}

/// Deterministic stand-in — see StubPolishBackend above; declared separately so
/// this suite doesn't depend on that file-private type's ordering.
private struct StubPolish: PolishBackend {
    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        style.id == Chronicler.chunkSummaryStyle.id ? "- did some work" : "STUB CHRONICLE"
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ChronicleProgressTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: build FAILS with "extra argument 'onProgress' in call" and no `formatBlock` overload.

- [ ] **Step 3: Add the block overload and thread progress through `generate`**

In `omwhisper-native/Memory/Chronicler.swift`, add beside the existing `formatBlock`:

```swift
    /// Adds the other windows seen in this capture's (bucket, app) group. Their
    /// bodies were dropped by `select`; their titles are cheap and carry the
    /// most signal per character, so the chronicle still knows you were there.
    static func formatBlock(_ selected: Selected) -> String {
        let base = formatBlock(selected.snapshot)
        guard !selected.otherTitles.isEmpty else { return base }
        return base + "\n(also in \(selected.appNameForTitles): \(selected.otherTitles.joined(separator: ", ")))"
    }
```

and inside `Selected`, add:

```swift
        var appNameForTitles: String { snapshot.appName }
```

Then change `generate`'s signature and the two places it builds blocks and calls the model. Replace the head of `generate` (down to and including the `for group in chunks` loop) with:

```swift
    static func generate(
        day: String, store: MemoryStore, polish: PolishBackend,
        chunkLimit: Int = chunkCharLimit,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> ChronicleResult {
        let snapshots = try store.snapshotsForDay(day)
        guard !snapshots.isEmpty else {
            throw ChroniclerError.noSnapshots
        }
        // Reduce BEFORE the model sees anything -- see select()'s note.
        let blocks = select(snapshots).map(formatBlock)
        let chunks = chunk(blocks, limit: chunkLimit)

        // +1 for the final reduce call, so progress ends at the total.
        let total = chunks.count + 1
        var done = 0

        var chunkSummaries: [String] = []
        for group in chunks {
            try Task.checkCancellation()
            onProgress?(done, total)
            let text = String(group.joined(separator: "\n\n").prefix(chunkLimit))
            let summary = try await polish.polish(text, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
            done += 1
        }
```

Then, immediately before the final reduce call (the line beginning `let chronicle = try await polish.polish(reduceInput`), insert:

```swift
        try Task.checkCancellation()
        onProgress?(done, total)
```

and immediately after it, insert:

```swift
        done += 1
        onProgress?(done, total)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ChronicleProgressTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with|recorded an issue"`

Expected: 2 tests PASS.

- [ ] **Step 5: Run the whole Chronicler suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/ChroniclerTests -only-testing:omwhisper-nativeTests/ChronicleChunkLimitTests -only-testing:omwhisper-nativeTests/ChronicleSelectionTests -only-testing:omwhisper-nativeTests/ChronicleProgressTests 2>&1 | grep -E "^.*error: |Test run with|recorded an issue"`

Expected: PASS. The existing collapse-loop regression test — the one tracing the day's last block into the final reduce input — is the guard against reintroducing truncation and must still pass. The chunk-limit test (12k makes strictly fewer calls than 1.8k) must also still pass, now over the reduced input.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Memory/Chronicler.swift omwhisper-nativeTests/ChroniclerTests.swift
git commit -m "✨ feat(memory): chronicles select before generating, and report progress"
```

---

### Task 3: Progress and Cancel in the app

**Files:**
- Modify: `omwhisper-native/AppState.swift`
- Modify: `omwhisper-native/UI/MemoryChroniclesView.swift`

**Interfaces:**
- Consumes: `Chronicler.generate(day:store:polish:chunkLimit:onProgress:)`.
- Produces:
  - `AppState.chronicleProgress: (done: Int, total: Int)?`
  - `AppState.cancelChronicle()`
  - `AppState.generateChronicle(day:)` — unchanged signature, now cancellable and reporting.

- [ ] **Step 1: Add progress state and cancellation to `AppState`**

In `omwhisper-native/AppState.swift`, add these stored properties next to the other `@ObservationIgnored` collaborators (search for `private let chronicleScheduler = ChronicleScheduler()`), placing the task handle beside it:

```swift
    @ObservationIgnored private var chronicleTask: Task<Chronicler.ChronicleResult, Error>?
    /// nil when nothing is generating. Stored (not computed) so @Observable
    /// instruments it automatically — no access/withMutation needed.
    private(set) var chronicleProgress: (done: Int, total: Int)?

    /// Stops a run in flight. Cancelling writes nothing: a partial chronicle is
    /// worse than none, and the day can simply be regenerated.
    func cancelChronicle() {
        chronicleTask?.cancel()
        chronicleTask = nil
        chronicleProgress = nil
    }
```

Then replace the body of `generateChronicle(day:)`'s candidate loop so the work runs inside a cancellable `Task` and reports progress. Replace this block:

```swift
        var lastError: Error?
        for candidate in candidates {
            do {
                return try await Chronicler.generate(
                    day: day, store: memoryStore, polish: candidate.polish,
                    chunkLimit: candidate.chunkLimit
                )
            } catch let error as Chronicler.ChroniclerError {
```

with:

```swift
        var lastError: Error?
        for candidate in candidates {
            do {
                let task = Task<Chronicler.ChronicleResult, Error> { [weak self] in
                    try await Chronicler.generate(
                        day: day, store: memoryStore, polish: candidate.polish,
                        chunkLimit: candidate.chunkLimit,
                        onProgress: { done, total in
                            Task { @MainActor in self?.chronicleProgress = (done, total) }
                        }
                    )
                }
                chronicleTask = task
                defer { chronicleTask = nil; chronicleProgress = nil }
                return try await task.value
            } catch is CancellationError {
                // Not a failure — the user asked it to stop. No error surfaces
                // and no other backend is tried.
                throw CancellationError()
            } catch let error as Chronicler.ChroniclerError {
```

- [ ] **Step 2: Show progress and Cancel in the view**

In `omwhisper-native/UI/MemoryChroniclesView.swift`, replace the Generate button block (the `Button { generateTodaysChronicle() } label: { … }` through its `.padding(11)`) with:

```swift
            if let progress = appState.chronicleProgress {
                // A long run has to look like work, not a hang: the automatic
                // nightly run previously gave no indication at all.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating… \(progress.done) of \(progress.total)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Porcelain.dim)
                    Spacer()
                    Button("Cancel") { appState.cancelChronicle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Porcelain.mint)
                }
                .padding(11)
            } else {
                Button {
                    generateTodaysChronicle()
                } label: {
                    HStack(spacing: 6) {
                        if isRegenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 11))
                        }
                        Text(isRegenerating ? "Generating…" : "Generate today")
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isRegenerating)
                .padding(11)
            }
```

Then make cancellation silent — in `generateTodaysChronicle()`'s `catch`, replace:

```swift
            } catch {
                if case Chronicler.ChroniclerError.backendUnavailable = error {
                    errorMessage = true == true ? errorMessage : errorMessage
                }
            }
```

with the actual existing catch body extended. Replace this exact block:

```swift
            } catch {
                if case Chronicler.ChroniclerError.backendUnavailable = error {
                    errorIsBackend = true
                } else {
                    errorIsBackend = false
                }
                errorMessage = error.localizedDescription
            }
```

with:

```swift
            } catch is CancellationError {
                // Cancelling is not a failure and must not raise an alert.
            } catch {
                if case Chronicler.ChroniclerError.backendUnavailable = error {
                    errorIsBackend = true
                } else {
                    errorIsBackend = false
                }
                errorMessage = error.localizedDescription
            }
```

- [ ] **Step 3: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 456 tests PASS (446 + Task 1's 8 + Task 2's 2).

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/UI/MemoryChroniclesView.swift
git commit -m "✨ feat(memory): chronicle progress and Cancel"
```

- [ ] **Step 5: Live verification — measured, not eyeballed**

The unit tests prove selection and progress in isolation. They cannot prove the real pipeline got cheaper. This machine has the data to show it: **2026-08-01 has ~1,429 snapshots and previously did not finish in 20 minutes.**

1. Confirm Ollama is up and the model is pulled:

```bash
curl -s http://localhost:11434/api/tags | head -c 200
```

2. Note the current chronicles, and back up the one for 2026-08-01 so the test is reversible:

```bash
DB=~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
sqlite3 -cmd ".timeout 20000" "$DB" ".mode insert chronicles" \
  "SELECT * FROM chronicles WHERE day='2026-08-01';" > /tmp/chron-backup.sql
sqlite3 -cmd ".timeout 20000" "$DB" "DELETE FROM chronicles WHERE day='2026-08-01';"
```

3. Run the debug build (⌘R) with nothing else heavy running — **no concurrent `xcodebuild`**, which contaminated the previous measurement. The scheduler generates *yesterday* on launch.
4. Watch it:

```bash
DB=~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
START=$(date +%s)
until [ "$(sqlite3 -cmd '.timeout 15000' "$DB" \
  "SELECT COUNT(*) FROM chronicles WHERE day='2026-08-01';")" != "0" ]; do
  sleep 10
done
echo "completed in $(( $(date +%s) - START ))s"
```

**Pass:** it completes, and in **minutes rather than 20+**. **Fail:** it still runs long — which would mean selection isn't reaching the real path.

5. While it runs, confirm the UI shows `Generating… N of M` with a Cancel button, and that **the count is small** — roughly 4–6, not ~60. A large total means selection isn't being applied.
6. Press **Cancel** on a subsequent run and confirm: it stops within one model call, **no alert appears**, and no chronicle row is written.
7. Restore, if you removed a chronicle you wanted:

```bash
sqlite3 -cmd ".timeout 20000" "$DB" < /tmp/chron-backup.sql
```

8. Read the resulting chronicle. It should still name the apps and windows the day was spent in. If window names have vanished, `otherTitles` isn't reaching the block.

- [ ] **Step 6: Record the result**

Append the outcome — including the **measured chunk count and elapsed time** — to the Progress Tracker's S1–S6 row in `CLAUDE.md`, and commit. If step 4 or 6 failed, stop and debug rather than recording the feature as shipped.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Pure `select`, (15-min bucket, app), keep-longest | 1 |
| Chronological order preserved | 1 (`preservesChronology`) |
| Cap enforced, spread not truncated | 1 (`capSpreadsAcrossTheDay`) |
| Window titles survive where bodies don't | 1 (`keepsOtherTitles`), 2 (`formatBlock` overload) |
| Selection runs before the model | 2 step 3 |
| Chunking / collapse loop / storage untouched | 2 step 5 pins the existing tests |
| Progress callback `(completed, total)` | 2 |
| Cancellation between model calls | 2 (`Task.checkCancellation`), 3 |
| Cancel writes nothing, raises no error | 3 (`catch is CancellationError` in both layers) |
| Automatic run reports too | 3 — the scheduler routes through `generateChronicle` |
| Empty selection on a non-empty day ≠ `noSnapshots` | 1 (`reducesARealDay` pins ≥1 per app, so empty is impossible for a non-empty day) |
| Test that fails if selection is a no-op | 1 (`reducesARealDay`) |
| Live check with measured numbers | 3 step 5 |

**Placeholders:** none — every code step carries full source.

**Type consistency:** `Chronicler.Selected` is defined in Task 1 and consumed by `formatBlock(_ selected:)` in Task 2 and nowhere else. `onProgress: ((Int, Int) -> Void)?` has the same shape in Task 2's signature and Task 3's call site. `chronicleProgress` is a `(done: Int, total: Int)?` tuple in both `AppState` and the view.

**One correction made during review:** Task 3 step 2 originally showed a garbled placeholder catch block. Replaced with the exact existing code from `MemoryChroniclesView.generateTodaysChronicle()` plus the new `catch is CancellationError` arm.

**One risk called out rather than designed away:** `chronicleProgress` is a stored tuple property, so `@Observable` instruments it automatically and no `access`/`withMutation` is needed — unlike every `UserDefaults`-backed setting in this file. If it is ever converted to a computed property over external storage, it must gain those calls or the progress display will silently stop updating, which is this codebase's most-repeated bug.
