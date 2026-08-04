# Long-Form Backend Preference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Meetings, chronicles and brain-dump prefer Ollama's large context regardless of the dictation backend setting, and each stored summary records which backend wrote it.

**Architecture:** A pure `LongFormBackends.order(ollamaConfigured:systemAvailable:)` decides the preference order; `AppState` maps that order to backend instances and chunk limits. Two near-identical `AppState` functions collapse into one that calls it. Provenance is a new nullable column on `meetings` and `chronicles`, written at generation time and shown as a caption.

**Tech Stack:** Swift 6, GRDB (migrations, `DatabaseMigrator`), SwiftUI, Swift Testing.

## Global Constraints

- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: anything meant to run off the main thread needs an explicit `nonisolated` marker. A missing marker is a real build error, not a warning.
- Build and test with `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test`.
- Suite is at **488 tests in 70 suites** before this work. Every task ends green.
- **`AppState` cannot be constructed in a test** — its initialiser opens the real history and memory stores. Every assertion here runs against pure functions or a real in-memory `DatabaseQueue`, never `AppState`.
- Xcode groups are file-system-synchronized: creating a `.swift` file on disk is enough. Never hand-edit `project.pbxproj`.
- SourceKit in this project reports false "cannot find X in scope" errors. Only a real `xcodebuild` result counts.
- **Cloud must never appear on the long-form path.** Recordings and chronicles never reach a cloud provider; this is enforced by `LongFormBackends` never producing a cloud case, not by a setting.
- Chunk-limit constants are unchanged: `1_800` for SystemLLM, `12_000` for Ollama.

---

### Task 1: The pure preference decision

**Files:**
- Create: `omwhisper-native/Polish/LongFormBackends.swift`
- Test: `omwhisper-nativeTests/LongFormBackendsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LongFormBackends.Kind` (`nonisolated enum { case ollama, system }`, `Equatable`) and `LongFormBackends.order(ollamaConfigured: Bool, systemAvailable: Bool) -> [LongFormBackends.Kind]`.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/LongFormBackendsTests.swift`:

```swift
import Testing
@testable import OmWhisper

@Suite("Long-form backend preference")
struct LongFormBackendsTests {
    @Test("Ollama comes first when both are usable")
    func ollamaPreferredOverSystem() {
        // The whole point of the change. A test that only checked "the list is
        // non-empty" would pass with the order reversed, which is the bug.
        #expect(LongFormBackends.order(ollamaConfigured: true, systemAvailable: true)
                == [.ollama, .system])
    }

    @Test("each backend alone is used alone")
    func singleCandidates() {
        #expect(LongFormBackends.order(ollamaConfigured: true, systemAvailable: false) == [.ollama])
        #expect(LongFormBackends.order(ollamaConfigured: false, systemAvailable: true) == [.system])
    }

    @Test("neither available yields no candidates")
    func noCandidates() {
        // Callers distinguish "no backend at all" from "every backend failed",
        // so an empty list must stay empty rather than defaulting to something.
        #expect(LongFormBackends.order(ollamaConfigured: false, systemAvailable: false).isEmpty)
    }

    @Test("cloud can never be a long-form candidate")
    func noCloudCase() {
        // Recordings and chronicles must never egress. That is guaranteed by
        // Kind having no cloud case rather than by a check, so this asserts the
        // enum itself — it fails the moment someone adds one.
        #expect(LongFormBackends.Kind.allCases == [.ollama, .system])
    }
}
```

**Deliberately not written:** a test that "the order does not depend on
`polishBackend`". `order()` takes no such parameter, so a test could only call
the same function twice with the same arguments — a check that cannot fail. The
independence is structural, and the `noCloudCase` test above is the one property
of that shape which *can* be violated by a future edit.

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head -5`
Expected: `cannot find 'LongFormBackends' in scope`.

- [ ] **Step 3: Create `LongFormBackends.swift`**

```swift
//
//  LongFormBackends.swift
//  OmWhisper
//
//  Which local backend should do work with LARGE inputs -- meeting summaries,
//  chronicles, brain-dump structuring -- as opposed to polishing a sentence of
//  dictation.
//
//  Deliberately NOT a function of AppState.polishBackend. That setting says
//  what should polish your dictation, where latency dominates: measured on this
//  Mac, SystemLLM answers in ~2.1s while Ollama qwen3.5 takes 36.4s from cold,
//  and Ollama evicts after ~5 minutes idle, so a first dictation after any gap
//  blows the 30s dictation timeout and pastes raw text. Long-form work has the
//  opposite shape: nobody is waiting on a keystroke, and what matters is how
//  much fits in one call -- 12,000 characters against 1,800 turns an hour-long
//  call into ~6 passes instead of ~40, and every extra compression pass loses
//  detail.
//
//  Both candidates run on-device, so preferring the better-fitting one carries
//  no privacy consequence. Cloud is absent BY CONSTRUCTION rather than by a
//  check: recordings and chronicles never reach a cloud provider.
//
//  Pure and free of AppState on purpose -- constructing AppState in a test opens
//  the real history and memory stores.
//

import Foundation

nonisolated enum LongFormBackends {
    /// CaseIterable so a test can assert cloud never joins this list.
    enum Kind: Equatable, CaseIterable {
        case ollama
        case system
    }

    /// Preference order, best fit first. Empty when nothing is usable: callers
    /// distinguish "no backend at all" from "every backend failed", so this
    /// must not invent a fallback.
    ///
    /// - Parameters:
    ///   - ollamaConfigured: an Ollama model name is set (`!ollamaModel.isEmpty`).
    ///   - systemAvailable: `SystemLLM.isAvailable()`, which since 2026-08-01
    ///     checks language support as well as availability.
    static func order(ollamaConfigured: Bool, systemAvailable: Bool) -> [Kind] {
        var order: [Kind] = []
        if ollamaConfigured { order.append(.ollama) }
        if systemAvailable { order.append(.system) }
        return order
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 492 tests in 71 suites.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Polish/LongFormBackends.swift omwhisper-nativeTests/LongFormBackendsTests.swift
git commit -m "✨ feat(polish): pure preference order for long-form backends

Ollama first, then SystemLLM. Takes no polishBackend parameter, so the
independence from the dictation setting is structural rather than a rule
someone has to remember. Cloud cannot appear: there is no case for it."
```

---

### Task 2: Route meetings and chronicles through it

**Files:**
- Modify: `omwhisper-native/AppState.swift:789-800` (`meetingSummaryBackends`) and `:1092-1103` (`chronicleBackends`)

**Interfaces:**
- Consumes: `LongFormBackends.order(ollamaConfigured:systemAvailable:) -> [LongFormBackends.Kind]` from Task 1.
- Produces: `AppState.longFormBackends(ollamaChunkLimit: Int, systemChunkLimit: Int) -> [(kind: LongFormBackends.Kind, polish: PolishBackend, chunkLimit: Int)]`.

The two existing functions are the same code with different constants. They collapse into one, and the substantive change is that neither consults `polishBackend` any more.

- [ ] **Step 1: Replace both functions with one**

Delete `meetingSummaryBackends()` (lines 789-800) and `chronicleBackends()` (lines 1092-1103) entirely, and add this once, next to `activePolishBackend()`:

```swift
    /// Backends for work with large inputs, in preference order -- see
    /// LongFormBackends for why this ignores `polishBackend`.
    ///
    /// Ollama gets `longFormTimeout` (300s), not the 30s dictation timeout:
    /// nobody is waiting on a keystroke here, and a cold model takes ~36s to
    /// load. Cloud is never constructed, so recordings and chronicles cannot
    /// egress whatever the polish setting says.
    ///
    /// `kind` rides along so callers can name whichever candidate won, without
    /// having to type-check a PolishBackend existential.
    private func longFormBackends(ollamaChunkLimit: Int, systemChunkLimit: Int)
        -> [(kind: LongFormBackends.Kind, polish: PolishBackend, chunkLimit: Int)] {
        LongFormBackends.order(ollamaConfigured: !ollamaModel.isEmpty,
                               systemAvailable: SystemLLM.isAvailable())
            .map { kind in
                switch kind {
                case .ollama:
                    return (kind,
                            Ollama(baseURL: ollamaBaseURL, model: ollamaModel,
                                   timeout: Ollama.longFormTimeout),
                            ollamaChunkLimit)
                case .system:
                    return (kind, systemLLM, systemChunkLimit)
                }
            }
    }
```

`kind` is included from the start rather than added in Task 5, so the call sites
are touched once instead of twice. Existing uses destructure the tuple by name,
so `candidate.polish` and `candidate.chunkLimit` keep working unchanged.

- [ ] **Step 2: Repoint the meeting call sites**

`meetingSummaryBackends()` is called at lines 804, 827, 852, 878 and 904. Replace every occurrence of `meetingSummaryBackends()` with:

```swift
longFormBackends(ollamaChunkLimit: MeetingSummarizer.ollamaChunkLimit,
                 systemChunkLimit: MeetingSummarizer.chunkCharLimit)
```

- [ ] **Step 3: Repoint the chronicle call sites**

`chronicleBackends()` is called at lines 986 and 1110. Replace every occurrence with:

```swift
longFormBackends(ollamaChunkLimit: Chronicler.ollamaChunkLimit,
                 systemChunkLimit: Chronicler.chunkCharLimit)
```

- [ ] **Step 4: Build and run the suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 492 tests. No new tests — Task 1 covers the decision, and the mapping is a `switch` with no branches worth asserting that don't need `AppState`.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "🐛 fix(polish): long-form work no longer follows the dictation backend

meetingSummaryBackends() and chronicleBackends() were the same function
with different constants, both gated on polishBackend == .ollama. So
selecting System left an hour-long call compressed through ~40 passes
instead of ~6, and selecting Ollama left dictation polish silently
pasting raw text after any idle period -- a cold model takes 36.4s
against a 30s timeout.

One function now, and it asks LongFormBackends instead of the setting."
```

---

### Task 3: Brain-dump joins the long-form path

**Files:**
- Modify: `omwhisper-native/Polish/BrainDumpStructurer.swift:39-40` (add `chunkLimit:`)
- Modify: `omwhisper-native/AppState.swift:2223` (the `activePolishBackend()` call site)
- Test: `omwhisper-nativeTests/BrainDumpStructurerTests.swift`

**Interfaces:**
- Consumes: `AppState.longFormBackends(ollamaChunkLimit:systemChunkLimit:)` from Task 2.
- Produces: `BrainDumpStructurer.structure(transcript:shape:context:polish:chunkLimit:)`, and `BrainDumpStructurer.ollamaChunkLimit = 12_000`.

Brain-dump has the exact defect being fixed — a long ramble through a cold Ollama exceeds the 30s dictation timeout — and it never got the `chunkLimit` parameter its siblings have, so it would chunk at 1,800 even on Ollama.

- [ ] **Step 1: Write the failing test**

Add to `omwhisper-nativeTests/BrainDumpStructurerTests.swift`:

```swift
    @Test("a bigger chunk limit means strictly fewer model calls")
    func largerChunkLimitMakesFewerCalls() async throws {
        // Accepting the parameter and ignoring it would still produce output and
        // pass a "did it structure something" check. Counting calls is what
        // fails if the limit is dropped on the floor. Same assertion shape as
        // Chronicler's chunk-limit test.
        let transcript = (1...200)
            .map { "Sentence number \($0) about something I need to remember later." }
            .joined(separator: " ")
        let shape = BrainDumpShapes.builtIn.first!

        let small = CountingBackend()
        _ = try await BrainDumpStructurer.structure(
            transcript: transcript, shape: shape, context: nil,
            polish: small, chunkLimit: 1_800)

        let large = CountingBackend()
        _ = try await BrainDumpStructurer.structure(
            transcript: transcript, shape: shape, context: nil,
            polish: large, chunkLimit: 12_000)

        #expect(large.calls < small.calls,
                "12k limit made \(large.calls) calls, 1.8k made \(small.calls)")
    }
```

And add this helper at the top of the same file, inside the suite:

```swift
    /// Counts calls and echoes its input, so chunking behaviour is observable
    /// without a real model.
    private final class CountingBackend: PolishBackend, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var calls: Int { lock.withLock { $0 } }
        func polish(_ text: String, style: PolishStyle, targetLanguage: String) async throws -> String {
            lock.withLock { $0 += 1 }
            return text
        }
    }
```

Add `import os` to the file if it is not already there.

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head -5`
Expected: an extra-argument error on `chunkLimit:`.

If `PolishBackend.polish` has a different signature than the helper above, match the real one — check `omwhisper-native/Polish/PolishBackend.swift` and copy it exactly.

- [ ] **Step 3: Parameterise `BrainDumpStructurer`**

In `omwhisper-native/Polish/BrainDumpStructurer.swift`, add the constant beside the existing `chunkCharLimit`:

```swift
    /// Ollama's envelope, matching MeetingSummarizer and Chronicler. A long
    /// ramble is one or two calls here instead of a dozen.
    static let ollamaChunkLimit = 12_000
```

Change the signature to take the limit, defaulting to today's value so no other
caller changes:

```swift
    static func structure(transcript: String, shape: PolishStyle,
                          context: String?, polish: PolishBackend,
                          chunkLimit: Int = chunkCharLimit) async throws -> String {
```

`chunk(_:limit:)` at line 20 already takes a limit and defaults it. The single
call inside `structure` is line 44, `let chunks = chunk(trimmed)` — pass the
parameter through:

```swift
        let chunks = chunk(trimmed, limit: chunkLimit)
```

That is the only place the constant is used implicitly, so nothing else changes.

- [ ] **Step 4: Route the call site through the long-form list**

In `omwhisper-native/AppState.swift`, replace the `guard let backend = activePolishBackend()` block at line 2223 and the `do`/`catch` that follows it with:

```swift
        let candidates = longFormBackends(ollamaChunkLimit: BrainDumpStructurer.ollamaChunkLimit,
                                          systemChunkLimit: BrainDumpStructurer.chunkCharLimit)
        guard !candidates.isEmpty, let shape = activeBrainDumpShape else { return original }
        var parts: [String] = []
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName { parts.append("Target app: \(app)") }
        if !sessionScreenTerms.isEmpty { parts.append("On-screen terms: \(sessionScreenTerms.prefix(20).joined(separator: ", "))") }
        let context = parts.isEmpty ? nil : parts.joined(separator: ". ")
        // Falls through the list rather than straight to raw text: Ollama being
        // down should cost the bigger envelope, not the structuring entirely.
        for candidate in candidates {
            do {
                return try await BrainDumpStructurer.structure(
                    transcript: original, shape: shape, context: context,
                    polish: candidate.polish, chunkLimit: candidate.chunkLimit)
            } catch {
                log.error("brainDumpStructured — \(String(describing: type(of: candidate.polish))) failed: \(error)")
            }
        }
        return original
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 493 tests.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Polish/BrainDumpStructurer.swift omwhisper-native/AppState.swift \
        omwhisper-nativeTests/BrainDumpStructurerTests.swift
git commit -m "🐛 fix(braindump): structuring is long-form work, not dictation

A long ramble through a cold Ollama exceeded the 30s dictation timeout
and pasted raw text. It also never got the chunkLimit parameter its
siblings have, so it chunked at 1,800 even where 12,000 fits.

Now walks the same candidate list as meetings and chronicles, so Ollama
being down costs the bigger envelope rather than the structuring."
```

---

### Task 4: Store which backend wrote a summary

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingStore.swift:18-31` (`Meeting` fields), `:113-136` (migrations), `:155` (`setTranscriptAndSummary`), `:166-172` (`setSummary`)
- Modify: `omwhisper-native/Memory/MemoryStore.swift:26-33` (`MemoryChronicle`), `:82-89` (migrations), `:298-302` (`upsertChronicle`)
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`, `omwhisper-nativeTests/MemoryStoreTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Meeting.summaryBackend: String?`, `MemoryChronicle.backend: String?`, `MeetingStore.setTranscriptAndSummary(id:transcript:summary:summaryBackend:)`, `MeetingStore.setSummary(id:_:backend:)`, `MemoryStore.upsertChronicle(day:summary:snapshotCount:backend:)`.

**Which method actually writes a generated summary:** `setTranscriptAndSummary`
(called from `AppState.swift:838` and `:864`), **not** `setSummary` —
`setSummary` is only the manual-edit path from
`HubMeetingsSectionView.swift:512`. Both need the parameter, for opposite
reasons: generation records the backend, hand-editing clears it.

Both columns are **nullable**: rows written before this change have no value and must keep loading and rendering.

- [ ] **Step 1: Write the failing tests**

Add to `omwhisper-nativeTests/MeetingStoreTests.swift`:

```swift
    @Test("the summary backend round-trips, and older rows survive without one")
    func summaryBackendRoundTrips() throws {
        let store = try MeetingStore(DatabaseQueue())
        let id = try store.insert(Meeting(
            startedAt: "2026-08-05T10:00:00Z", appName: "Teams",
            directory: "/tmp/x", durationSeconds: 60, createdAt: "2026-08-05T10:01:00Z"))

        // A row with no backend recorded — the state every pre-existing meeting
        // is in — must load rather than throw.
        #expect(try store.fetchPage(limit: 10, offset: 0).first?.summaryBackend == nil)

        // Generation path.
        try store.setTranscriptAndSummary(id: id, transcript: "Alice: hello.",
                                          summary: "## Summary\n\nIt happened.",
                                          summaryBackend: "Ollama (qwen3.5:latest)")
        let saved = try store.fetchPage(limit: 10, offset: 0).first
        #expect(saved?.summaryBackend == "Ollama (qwen3.5:latest)")
        #expect(saved?.summary?.contains("It happened") == true)

        // Hand-editing clears it: an edited summary is no longer the model's
        // output, so attributing it to the model would be a lie.
        try store.setSummary(id: id, "## Summary\n\nI rewrote this myself.")
        #expect(try store.fetchPage(limit: 10, offset: 0).first?.summaryBackend == nil)
    }
```

Add to `omwhisper-nativeTests/MemoryStoreTests.swift`:

```swift
    @Test("the chronicle backend round-trips, and older rows survive without one")
    func chronicleBackendRoundTrips() throws {
        let store = try MemoryStore(DatabaseQueue())
        try store.upsertChronicle(day: "2026-08-04", summary: "A day.",
                                  snapshotCount: 12, backend: nil)
        #expect(try store.getChronicle(day: "2026-08-04")?.backend == nil)

        try store.upsertChronicle(day: "2026-08-05", summary: "Another day.",
                                  snapshotCount: 40, backend: "Apple Intelligence")
        #expect(try store.getChronicle(day: "2026-08-05")?.backend == "Apple Intelligence")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head -5`
Expected: `value of type 'Meeting' has no member 'summaryBackend'` and an extra-argument error on `backend:`.

- [ ] **Step 3: Add the meeting column and migration**

In `omwhisper-native/Meetings/MeetingStore.swift`, add to the `Meeting` struct beside `speakerNames`:

```swift
    /// Which backend wrote `summary`, e.g. "Ollama (qwen3.5:latest)". Nil for
    /// rows written before provenance existed, and for meetings with no summary.
    var summaryBackend: String? = nil
```

Add a third migration after `"meetingIdentity"` — a plain `ALTER`, with no FTS
work, because the backend name is not something anyone searches for:

```swift
        migrator.registerMigration("summaryProvenance") { db in
            try db.alter(table: Meeting.databaseTableName) { t in
                t.add(column: "summaryBackend", .text)
            }
        }
```

Change both write methods. `setTranscriptAndSummary` (line 155) is the
generation path and takes the backend:

```swift
    func setTranscriptAndSummary(id: Int64, transcript: String?, summary: String?,
                                 summaryBackend: String? = nil) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.transcript = transcript
            m.summary = summary
            m.summaryBackend = summaryBackend
            try m.update(db)
        }
    }
```

Keep the rest of that method's existing body — read it first and change only the
assignment block; the code above shows the shape, not necessarily every line it
already contains.

`setSummary` (line 166) is the manual-edit path and **clears** it:

```swift
    /// Clears `summaryBackend`: this is the hand-edit path, and an edited
    /// summary is no longer attributable to the model that drafted it.
    func setSummary(id: Int64, _ summary: String?) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.summary = summary
            m.summaryBackend = nil
            try m.update(db)
        }
    }
```

- [ ] **Step 4: Add the chronicle column and migration**

In `omwhisper-native/Memory/MemoryStore.swift`, add to `MemoryChronicle`:

```swift
    /// Which backend wrote `summary`. Nil for rows written before provenance.
    var backend: String? = nil
```

Add a migration after `"createChronicles"` (place it after the last existing
migration registration so ordering is append-only):

```swift
        migrator.registerMigration("chronicleProvenance") { db in
            try db.alter(table: MemoryChronicle.databaseTableName) { t in
                t.add(column: "backend", .text)
            }
        }
```

And change `upsertChronicle`:

```swift
    func upsertChronicle(day: String, summary: String, snapshotCount: Int,
                         backend: String?) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let row = MemoryChronicle(day: day, summary: summary, snapshotCount: snapshotCount,
                                  createdAt: now, backend: backend)
        try dbQueue.write { db in try row.save(db) }
    }
```

- [ ] **Step 5: Thread the backend name through `Chronicler`**

**`Chronicler` writes the chronicle row itself** — `Chronicler.swift:247` calls
`store.upsertChronicle(...)`, so `AppState` never touches it. The name therefore
has to be passed *in*, not returned. In `omwhisper-native/Memory/Chronicler.swift`,
add a parameter to `generate` (line 193), after `chunkLimit`:

```swift
    static func generate(
        day: String, store: MemoryStore, polish: PolishBackend,
        chunkLimit: Int = chunkCharLimit,
        backendName: String? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> ChronicleResult {
```

and pass it at line 247:

```swift
        try store.upsertChronicle(day: day, summary: trimmed,
                                  snapshotCount: snapshots.count, backend: backendName)
```

Defaulted to `nil` so existing callers and tests compile untouched; Task 5
supplies the real value from `AppState`.

- [ ] **Step 6: Build and fix anything else the signature changes break**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head`

`setTranscriptAndSummary` and `Chronicler.generate` both gained defaulted
parameters, so existing call sites should still compile. Fix anything that does
not.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 495 tests.

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-native/Memory/MemoryStore.swift \
        omwhisper-native/Memory/Chronicler.swift \
        omwhisper-nativeTests/MeetingStoreTests.swift omwhisper-nativeTests/MemoryStoreTests.swift
git commit -m "✨ feat(store): record which backend wrote a summary

Nullable columns on meetings and chronicles, added by plain ALTER
migrations. Nullable because every existing row predates them and must
keep loading; the tests assert that directly rather than only checking
the happy path.

No FTS change: a backend name is not something anyone searches for."
```

---

### Task 5: Write and show the provenance

**Files:**
- Modify: `omwhisper-native/AppState.swift` (`generateMeetingSummary` around :803, `generateChronicle` around :1108)
- Modify: `omwhisper-native/UI/MemoryChroniclesView.swift:184`
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift:431` (`summaryCard`)
- Test: `omwhisper-nativeTests/LongFormBackendsTests.swift`

**Interfaces:**
- Consumes: `Meeting.summaryBackend`, `MemoryChronicle.backend`, `MeetingStore.setSummary(id:_:backend:)`, `MemoryStore.upsertChronicle(day:summary:snapshotCount:backend:)` from Task 4; `longFormBackends(...)` from Task 2.
- Produces: `LongFormBackends.displayName(for: LongFormBackends.Kind, ollamaModel: String) -> String`.

- [ ] **Step 1: Write the failing test**

Add to `omwhisper-nativeTests/LongFormBackendsTests.swift`:

```swift
    @Test("the display name names the model, not just the backend")
    func displayNameIncludesModel() {
        // "Ollama" alone does not distinguish a 3B model from a 9B one, and that
        // distinction is the entire reason a summary might read badly.
        #expect(LongFormBackends.displayName(for: .ollama, ollamaModel: "qwen3.5:latest")
                == "Ollama (qwen3.5:latest)")
        #expect(LongFormBackends.displayName(for: .system, ollamaModel: "qwen3.5:latest")
                == "Apple Intelligence")
        // An empty model should never render as "Ollama ()".
        #expect(LongFormBackends.displayName(for: .ollama, ollamaModel: "") == "Ollama")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head -3`
Expected: `type 'LongFormBackends' has no member 'displayName'`.

- [ ] **Step 3: Add `displayName`**

In `omwhisper-native/Polish/LongFormBackends.swift`:

```swift
    /// What to show the user for a backend that produced a summary. The model
    /// name is included deliberately: a poor summary labelled "Ollama
    /// (llama3.2:latest)" tells you what to change, where "Ollama" alone does
    /// not -- a 3B model was measured answering "Nothing relevant." to
    /// questions the transcript plainly answered.
    static func displayName(for kind: Kind, ollamaModel: String) -> String {
        switch kind {
        case .ollama: return ollamaModel.isEmpty ? "Ollama" : "Ollama (\(ollamaModel))"
        case .system: return "Apple Intelligence"
        }
    }
```

- [ ] **Step 4: Record it when a meeting summary is generated**

In `generateMeetingSummary` (around line 803), change the loop so the winning
candidate's name is returned with the summary:

```swift
    /// First candidate that produces a summary, with the name of whichever one
    /// did; nil when all fail or none exist.
    private func generateMeetingSummary(transcript: String,
                                        template: PolishStyle) async -> (summary: String, backend: String)? {
        for candidate in longFormBackends(ollamaChunkLimit: MeetingSummarizer.ollamaChunkLimit,
                                          systemChunkLimit: MeetingSummarizer.chunkCharLimit) {
            if let summary = try? await MeetingSummarizer.generate(
                transcript: transcript, polish: candidate.polish,
                template: template, chunkLimit: candidate.chunkLimit) {
                return (summary, LongFormBackends.displayName(for: candidate.kind,
                                                              ollamaModel: ollamaModel))
            }
        }
        return nil
    }
```

Its two callers are `AppState.swift:828` (transcribe-and-summarize) and `:860`
(regenerate). Both then call `setTranscriptAndSummary` at `:838` and `:864` —
pass the backend through at each:

```swift
        try store.setTranscriptAndSummary(id: id, transcript: transcript,
                                          summary: summary?.summary,
                                          summaryBackend: summary?.backend)
```

At line 828 `summary` is the optional tuple, so `summary?.summary` and
`summary?.backend` both fall to nil when no backend produced one. At line 860
the `guard let summary` already unwrapped it, so use `summary.summary` and
`summary.backend` there.

The hand-edit path at `HubMeetingsSectionView.swift:512` calls `setSummary`,
which clears the backend on its own — leave that call site unchanged.

- [ ] **Step 5: Record it when a chronicle is generated**

`generateChronicle` (around line 1108) walks its own candidate list. Pass the
winning candidate's name into `Chronicler.generate`, which owns the row write:

```swift
        for candidate in candidates {
            do {
                return try await Chronicler.generate(
                    day: day, store: memoryStore, polish: candidate.polish,
                    chunkLimit: candidate.chunkLimit,
                    backendName: LongFormBackends.displayName(for: candidate.kind,
                                                              ollamaModel: ollamaModel),
                    onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("generateChronicle — candidate failed: \(error)")
            }
        }
```

Match the existing loop's structure rather than replacing it wholesale — read
the current body first and add only `backendName:`. **`CancellationError` must
keep propagating rather than falling through to the next candidate**: cancelling
is a choice, not a failure, and swallowing it here would silently retry on the
other backend.

- [ ] **Step 6: Show it on the chronicle**

In `omwhisper-native/UI/MemoryChroniclesView.swift`, line 184 currently reads:

```swift
                Text("\(chronicle.snapshotCount) snapshot\(chronicle.snapshotCount == 1 ? "" : "s")  ·  Written \(Self.writtenAt(chronicle.createdAt))  ·  on this Mac")
```

Replace it with a version that omits the clause entirely when there is no
backend, rather than rendering an empty one:

```swift
                Text(Self.chronicleCaption(chronicle))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Porcelain.dim)
```

And add, beside `writtenAt`:

```swift
    /// Rows written before provenance existed have no backend; the clause is
    /// dropped rather than shown empty.
    static func chronicleCaption(_ chronicle: MemoryChronicle) -> String {
        var parts = ["\(chronicle.snapshotCount) snapshot\(chronicle.snapshotCount == 1 ? "" : "s")",
                     "Written \(writtenAt(chronicle.createdAt))"]
        if let backend = chronicle.backend, !backend.isEmpty { parts.append("by \(backend)") }
        parts.append("on this Mac")
        return parts.joined(separator: "  ·  ")
    }
```

- [ ] **Step 7: Show it on the meeting summary**

In `omwhisper-native/UI/HubMeetingsSectionView.swift`, inside `summaryCard(_:)`
(line 431), add a caption below the rendered summary, shown only when the
meeting has a backend recorded and is not being edited:

```swift
            if !editingSummary, let backend = meeting.summaryBackend, !backend.isEmpty {
                Text("Written by \(backend) · on this Mac")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Porcelain.dim)
            }
```

- [ ] **Step 8: Run the tests**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 496 tests.

- [ ] **Step 9: Commit**

```bash
git add omwhisper-native/Polish/LongFormBackends.swift omwhisper-native/AppState.swift \
        omwhisper-native/UI/MemoryChroniclesView.swift omwhisper-native/UI/HubMeetingsSectionView.swift \
        omwhisper-nativeTests/LongFormBackendsTests.swift
git commit -m "✨ feat(polish): summaries say which backend wrote them

The model name is part of it on purpose. Preferring Ollama is only better
if the Ollama model is good, and the app cannot judge that -- a 3B model
was measured answering 'Nothing relevant.' to questions the transcript
plainly answered. A summary labelled 'Ollama (llama3.2:latest)' tells you
what to change; 'Ollama' alone does not, and no label at all leaves a bad
summary mysterious.

The clause is dropped for rows with no backend rather than rendered
empty."
```

---

## Live verification

Each of these can come back negative.

1. **AI Polish set to System, Ollama running with qwen3.5.** Transcribe & Summarize a meeting → the summary appears and its caption reads **"Written by Ollama (qwen3.5:latest)"**. Before this change it would have been written by Apple Intelligence.
2. **Same setting, dictation.** Dictate a sentence → polish completes in a couple of seconds. This is the half that must NOT change: dictation still uses your chosen backend.
3. **Stop Ollama** (`pkill ollama`), regenerate the same summary → it succeeds and the caption reads **"Written by Apple Intelligence"**. This is the fallback, and without it the preference is untested in the direction that matters.
4. **Generate today's chronicle** → the header reads `N snapshots · Written … · by Ollama (qwen3.5:latest) · on this Mac`.
5. **An old meeting and an old chronicle** — ones summarised before this change — still open and render, with no "Written by" line and no empty clause.
6. **Brain-dump** (⌘⇧D) a long ramble with Ollama running → it structures rather than pasting raw. With Ollama stopped it still structures, via Apple Intelligence.
7. **Edit a summary by hand** → the "Written by" line disappears, because an edited summary is no longer the model's output.

## Out of scope

A per-feature backend picker · any quality heuristic for choosing between models · changing timeout or chunk-limit constants · cloud backends on the long-form path · the dictation, Smart Dictation, Polish Selected or Reply Assist paths.
