# S5.1 — Chronicles + Search/Today/Timeline UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add daily chronicle generation (map-reduce summarization of a day's
captured memory snapshots via `PolishBackend`) and a new "Memory" browse/search
window (Snapshots tab + Chronicles tab), both gated entirely by the existing
`memoryEnabled` flag from S1 — no new master toggle.

**Architecture:** `chronicles` table + CRUD added to the existing `MemoryStore`
(same `memory.db`). A new `Chronicler` enum holds pure digest-chunking logic
plus the async map-reduce `generate()` call, staying inside the ≤2,000-char
per-call ceiling already proven safe for `SystemLLM`'s 5s timeout (S4). A new
`ChronicleScheduler` (Timer wrapper, mirrors `MemoryCapture`'s shape) triggers
generation once a day, owned by `AppState` and wired into the existing
`memoryEnabled` setter. Two new SwiftUI views (`MemoryView`/`MemorySnapshotsView`
mirroring `HistoryView`'s proven shape, `MemoryChroniclesView` for day-list +
detail) surface everything in a new `Window("Memory", id: "memory")` scene.

**Tech Stack:** Swift 6, GRDB (existing dependency), SwiftUI, `FoundationModels`
via the existing `SystemLLM`/`PolishBackend`.

## Global Constraints

- No new Settings toggle. Chronicle generation and the browse UI are gated
  entirely by the existing `memoryEnabled` flag (default `false`).
- Chronicle generation additionally requires `polishBackend == .system` and
  `SystemLLM.isAvailable()` — checked fresh each tick via an `isSuppressed`
  closure (same contract as `MemoryCapture`/`MeetingWatcher`/`ReplyAssistMonitor`).
- Every individual `PolishBackend.polish()` call made by `Chronicler` must
  stay ≤2,000 chars of input text (`chunkCharLimit = 1_800`,
  `reduceCharLimit = 1_800`) — this is the ceiling S4 already proved safe for
  `SystemLLM`'s hardcoded 5s timeout. Do not add a timeout parameter to
  `PolishBackend`/`SystemLLM` — reuse the protocol exactly as it exists today.
- Chronicles live in `memory.db` (the existing `MemoryStore`/`DatabaseQueue`),
  never a new database file.
- `ChronicleScheduler`'s daily tick only generates a day that has no existing
  chronicle yet (idempotent). Manual "Regenerate" in the UI always overwrites.
- Two new internal `PolishStyle`s (chunk-summarizer, chronicle-writer) use
  fixed UUIDs and `isBuiltIn: true`, and must NOT be added to
  `PolishStyles.builtIns` — they are never shown in the AI tab's picker,
  same pattern as S4's hidden reply-draft style.
- No XCUITest — this project has no UI test target (removed project-wide).
  SwiftUI views are verified by building + live verification only, matching
  every other view in this codebase (`HistoryView`, `SettingsView`, etc.).

---

### Task 1: MemoryChronicle record + MemoryStore chronicle/pagination methods

**Files:**
- Modify: `omwhisper-native/Memory/MemoryStore.swift`
- Test: `omwhisper-nativeTests/MemoryStoreTests.swift`

**Interfaces:**
- Produces: `struct MemoryChronicle: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable` (fields: `day: String`, `summary: String`, `snapshotCount: Int`, `createdAt: String`); `MemoryStore.fetchPage(offset:limit:) throws -> [MemorySnapshot]`; `MemoryStore.delete(id:) throws`; `MemoryStore.deleteAll() throws`; `MemoryStore.storageInfo() throws -> (count: Int, bytes: Int64)`; `MemoryStore.upsertChronicle(day:summary:snapshotCount:) throws`; `MemoryStore.getChronicle(day:) throws -> MemoryChronicle?`; `MemoryStore.listChronicles(limit:) throws -> [MemoryChronicle]`; `MemoryStore.snapshotsForDay(_:) throws -> [MemorySnapshot]`.
- Consumes: existing `MemorySnapshot`, existing `dbQueue` (internal, already exposed for test access).

- [ ] **Step 1: Write failing tests for the new MemoryStore methods**

Append to `omwhisper-nativeTests/MemoryStoreTests.swift`, inside the
`MemoryStoreTests` struct (after the existing `pruneRemovesOldRows` test,
before the closing `}`):

```swift
    @Test("fetchPage returns most-recently-seen snapshots first, respecting offset/limit")
    func fetchPagePaginatesByRecency() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "A", content: "first", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "B", content: "second", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "C", content: "third", url: "")
        let page1 = try store.fetchPage(offset: 0, limit: 2)
        #expect(page1.map(\.windowTitle) == ["C", "B"])
        let page2 = try store.fetchPage(offset: 2, limit: 2)
        #expect(page2.map(\.windowTitle) == ["A"])
    }

    @Test("delete removes a single row, deleteAll removes everything")
    func deleteAndDeleteAll() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "A", content: "first", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "B", content: "second", url: "")
        let rows = try store.fetchPage(offset: 0, limit: 10)
        guard let idToDelete = rows.first(where: { $0.windowTitle == "A" })?.id else {
            Issue.record("expected row A to have an id")
            return
        }
        try store.delete(id: idToDelete)
        #expect(try store.fetchPage(offset: 0, limit: 10).map(\.windowTitle) == ["B"])
        try store.deleteAll()
        #expect(try store.fetchPage(offset: 0, limit: 10).isEmpty)
    }

    @Test("storageInfo reports a non-zero count after inserts")
    func storageInfoReportsCount() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "A", content: "first", url: "")
        let info = try store.storageInfo()
        #expect(info.count == 1)
        #expect(info.bytes >= 0)
    }

    @Test("upsertChronicle then getChronicle round-trips")
    func chronicleRoundTrips() throws {
        let store = try makeStore()
        try store.upsertChronicle(day: "2026-07-08", summary: "Worked on the memory feature.", snapshotCount: 12)
        let chronicle = try store.getChronicle(day: "2026-07-08")
        #expect(chronicle?.day == "2026-07-08")
        #expect(chronicle?.summary == "Worked on the memory feature.")
        #expect(chronicle?.snapshotCount == 12)
    }

    @Test("upsertChronicle for an existing day overwrites, not duplicates")
    func chronicleUpsertOverwrites() throws {
        let store = try makeStore()
        try store.upsertChronicle(day: "2026-07-08", summary: "First draft.", snapshotCount: 5)
        try store.upsertChronicle(day: "2026-07-08", summary: "Regenerated.", snapshotCount: 9)
        let chronicle = try store.getChronicle(day: "2026-07-08")
        #expect(chronicle?.summary == "Regenerated.")
        #expect(chronicle?.snapshotCount == 9)
        #expect(try store.listChronicles(limit: 10).count == 1)
    }

    @Test("getChronicle returns nil for a day with no chronicle")
    func chronicleMissingReturnsNil() throws {
        let store = try makeStore()
        #expect(try store.getChronicle(day: "2026-01-01") == nil)
    }

    @Test("listChronicles orders newest day first")
    func listChroniclesOrdersByDayDescending() throws {
        let store = try makeStore()
        try store.upsertChronicle(day: "2026-07-06", summary: "Day 1.", snapshotCount: 1)
        try store.upsertChronicle(day: "2026-07-08", summary: "Day 3.", snapshotCount: 1)
        try store.upsertChronicle(day: "2026-07-07", summary: "Day 2.", snapshotCount: 1)
        let days = try store.listChronicles(limit: 10).map(\.day)
        #expect(days == ["2026-07-08", "2026-07-07", "2026-07-06"])
    }

    @Test("snapshotsForDay returns only that day's snapshots, oldest first")
    func snapshotsForDayFiltersByDate() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Today", content: "today content", url: "")
        let today = ISO8601DateFormatter().string(from: Date())
        let yesterday = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        try store.dbQueue.write { db in
            try MemorySnapshot.filter(Column("windowTitle") == "Today")
                .updateAll(db, Column("capturedAt").set(to: yesterday), Column("lastSeenAt").set(to: yesterday))
        }
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "TodayReal", content: "real today", url: "")
        let todayDay = String(today.prefix(10))
        let results = try store.snapshotsForDay(todayDay)
        #expect(results.map(\.windowTitle) == ["TodayReal"])
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test -only-testing:omwhisper-nativeTests/MemoryStoreTests`
Expected: FAIL — compile errors, since `fetchPage`/`delete`/`deleteAll`/`storageInfo`/`upsertChronicle`/`getChronicle`/`listChronicles`/`snapshotsForDay`/`MemoryChronicle` don't exist yet on `MemoryStore`.

- [ ] **Step 3: Add MemoryChronicle and the chronicles table migration**

In `omwhisper-native/Memory/MemoryStore.swift`, add this struct right after
the `import GRDB` line and before `nonisolated final class MemoryStore`:

```swift
nonisolated struct MemoryChronicle: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "chronicles"
    var id: String { day }
    var day: String
    var summary: String
    var snapshotCount: Int
    var createdAt: String
}
```

Inside `MemoryStore.init(_:)`, right after the existing
`migrator.registerMigration("createSnapshots") { ... }` block (after its
closing `}`) and before `try migrator.migrate(dbQueue)`, add a second
migration:

```swift
        migrator.registerMigration("createChronicles") { db in
            try db.create(table: MemoryChronicle.databaseTableName) { t in
                t.column("day", .text).notNull().primaryKey()
                t.column("summary", .text).notNull()
                t.column("snapshotCount", .integer).notNull()
                t.column("createdAt", .text).notNull()
            }
        }
```

- [ ] **Step 4: Add the pagination/delete/storageInfo methods to MemoryStore**

In `omwhisper-native/Memory/MemoryStore.swift`, add these methods to
`MemoryStore`, right after the existing `search(_:limit:)` method and before
`prune(olderThanDays:)`:

```swift
    func fetchPage(offset: Int, limit: Int) throws -> [MemorySnapshot] {
        try dbQueue.read { db in
            try MemorySnapshot
                .order(Column("lastSeenAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func delete(id: Int64) throws {
        try dbQueue.write { db in _ = try MemorySnapshot.deleteOne(db, key: id) }
    }

    func deleteAll() throws {
        try dbQueue.write { db in _ = try MemorySnapshot.deleteAll(db) }
    }

    func storageInfo() throws -> (count: Int, bytes: Int64) {
        try dbQueue.read { db in
            let count = try MemorySnapshot.fetchCount(db)
            let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return (count, pageCount * pageSize)
        }
    }
```

- [ ] **Step 5: Add the chronicle CRUD methods to MemoryStore**

In `omwhisper-native/Memory/MemoryStore.swift`, add these methods at the end
of `MemoryStore`, right before the class's closing `}`:

```swift

    func upsertChronicle(day: String, summary: String, snapshotCount: Int) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let row = MemoryChronicle(day: day, summary: summary, snapshotCount: snapshotCount, createdAt: now)
        try dbQueue.write { db in try row.save(db) }
    }

    func getChronicle(day: String) throws -> MemoryChronicle? {
        try dbQueue.read { db in try MemoryChronicle.fetchOne(db, key: day) }
    }

    func listChronicles(limit: Int = 60) throws -> [MemoryChronicle] {
        try dbQueue.read { db in
            try MemoryChronicle
                .order(Column("day").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func snapshotsForDay(_ day: String) throws -> [MemorySnapshot] {
        try dbQueue.read { db in
            try MemorySnapshot.fetchAll(db, sql: """
                SELECT * FROM snapshots
                WHERE date(lastSeenAt) = ? OR date(capturedAt) = ?
                ORDER BY lastSeenAt ASC
                """, arguments: [day, day])
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test -only-testing:omwhisper-nativeTests/MemoryStoreTests`
Expected: PASS — all `MemoryStoreTests` tests green, including the 8 new ones.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Memory/MemoryStore.swift omwhisper-nativeTests/MemoryStoreTests.swift
git commit -m "✨ feat(memory): add MemoryChronicle + chronicle/pagination methods to MemoryStore"
```

---

### Task 2: Chronicler (pure chunking logic + map-reduce generate())

**Files:**
- Create: `omwhisper-native/Memory/Chronicler.swift`
- Test: `omwhisper-nativeTests/ChroniclerTests.swift`

**Interfaces:**
- Consumes: `MemorySnapshot` (fields `appName`, `windowTitle`, `url`, `content`, `lastSeenAt`) and `MemoryStore.snapshotsForDay(_:)`/`upsertChronicle(day:summary:snapshotCount:)` from Task 1; `PolishBackend` protocol and `PolishStyle` from `Polish/PolishBackend.swift` (existing).
- Produces: `Chronicler.chunk(_:limit:) -> [[String]]`; `Chronicler.formatBlock(_:) -> String`; `Chronicler.dayString(daysAgo:) -> String`; `Chronicler.generate(day:store:polish:) async throws -> Chronicler.ChronicleResult` (fields `day: String`, `summary: String`, `snapshotCount: Int`); `Chronicler.ChroniclerError.noSnapshots`; `Chronicler.chunkSummaryStyle`/`Chronicler.chronicleWriteStyle: PolishStyle` (used by Task 3).

- [ ] **Step 1: Write failing tests for the pure functions**

Create `omwhisper-nativeTests/ChroniclerTests.swift`:

```swift
import Testing
import Foundation
@testable import OmWhisper

@Suite("Chronicler")
struct ChroniclerTests {

    // MARK: - formatBlock

    @Test("formatBlock clips content to perSnapshotLimit and includes metadata")
    func formatBlockClipsContent() {
        let snapshot = MemorySnapshot(
            id: 1, appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "AppState.swift",
            content: String(repeating: "x", count: Chronicler.perSnapshotLimit + 500),
            url: "", contentHash: "h", capturedAt: "2026-07-08T09:00:00Z", lastSeenAt: "2026-07-08T09:00:00Z"
        )
        let block = Chronicler.formatBlock(snapshot)
        #expect(block.contains("Xcode"))
        #expect(block.contains("AppState.swift"))
        #expect(block.count <= Chronicler.perSnapshotLimit + 100)  // metadata prefix + clipped content
    }

    @Test("formatBlock omits the url segment when url is empty")
    func formatBlockOmitsEmptyURL() {
        let snapshot = MemorySnapshot(
            id: 1, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled",
            content: "hello", url: "", contentHash: "h", capturedAt: "2026-07-08T09:00:00Z", lastSeenAt: "2026-07-08T09:00:00Z"
        )
        #expect(!Chronicler.formatBlock(snapshot).contains("<>"))
    }

    @Test("formatBlock includes the url segment when present")
    func formatBlockIncludesURL() {
        let snapshot = MemorySnapshot(
            id: 1, appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Example",
            content: "hello", url: "https://example.com", contentHash: "h",
            capturedAt: "2026-07-08T09:00:00Z", lastSeenAt: "2026-07-08T09:00:00Z"
        )
        #expect(Chronicler.formatBlock(snapshot).contains("<https://example.com>"))
    }

    // MARK: - chunk

    @Test("chunk of an empty array is empty")
    func chunkEmptyIsEmpty() {
        #expect(Chronicler.chunk([]).isEmpty)
    }

    @Test("chunk packs several small blocks into one group under the limit")
    func chunkPacksSmallBlocks() {
        let blocks = Array(repeating: "short block", count: 5)  // 5 * ~11 chars, well under limit
        let groups = Chronicler.chunk(blocks, limit: 1_800)
        #expect(groups.count == 1)
        #expect(groups[0].count == 5)
    }

    @Test("chunk splits into a new group once the limit would be exceeded")
    func chunkSplitsAtLimit() {
        let blockA = String(repeating: "a", count: 60)
        let blockB = String(repeating: "b", count: 60)
        let groups = Chronicler.chunk([blockA, blockB], limit: 100)
        #expect(groups.count == 2)
        #expect(groups[0] == [blockA])
        #expect(groups[1] == [blockB])
    }

    @Test("chunk gives a single oversized block its own group rather than dropping or splitting it")
    func chunkOversizedBlockGetsOwnGroup() {
        let huge = String(repeating: "x", count: 5_000)
        let small = "tiny"
        let groups = Chronicler.chunk([huge, small], limit: 1_800)
        #expect(groups.count == 2)
        #expect(groups[0] == [huge])
        #expect(groups[1] == [small])
    }

    // MARK: - dayString

    @Test("dayString(daysAgo: 0) matches today's local calendar date")
    func dayStringToday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        #expect(Chronicler.dayString() == formatter.string(from: Date()))
    }

    @Test("dayString(daysAgo: 1) is one calendar day before dayString(daysAgo: 0)")
    func dayStringYesterday() {
        let today = Chronicler.dayString(daysAgo: 0)
        let yesterday = Chronicler.dayString(daysAgo: 1)
        #expect(yesterday < today)
    }

    // MARK: - generate

    @Test("generate throws noSnapshots for a day with nothing captured")
    func generateThrowsWhenNoSnapshots() async throws {
        let store = try MemoryStore(DatabaseQueue())
        do {
            _ = try await Chronicler.generate(day: "2026-01-01", store: store, polish: StubPolishBackend())
            Issue.record("expected ChroniclerError.noSnapshots to be thrown")
        } catch Chronicler.ChroniclerError.noSnapshots {
            // expected
        }
    }

    @Test("generate stores a chronicle built from the stub backend's output")
    func generateStoresChronicle() async throws {
        let store = try MemoryStore(DatabaseQueue())
        try store.upsert(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "AppState.swift", content: "editing code", url: "")
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let result = try await Chronicler.generate(day: day, store: store, polish: StubPolishBackend())
        #expect(result.day == day)
        #expect(result.snapshotCount == 1)
        #expect(result.summary == "STUB CHRONICLE")
        #expect(try store.getChronicle(day: day)?.summary == "STUB CHRONICLE")
    }
}

/// Deterministic stand-in for the real LLM call — returns a fixed chunk
/// summary for the map step and a fixed final chronicle for the reduce step,
/// so generate()'s orchestration (not SystemLLM's real network/on-device
/// behavior, already covered by its own live usage elsewhere) is what's
/// under test here.
private struct StubPolishBackend: PolishBackend {
    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        style.id == Chronicler.chunkSummaryStyle.id ? "- did some work" : "STUB CHRONICLE"
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test -only-testing:omwhisper-nativeTests/ChroniclerTests`
Expected: FAIL — compile errors, `Chronicler` doesn't exist yet.

- [ ] **Step 3: Implement Chronicler.swift**

Create `omwhisper-native/Memory/Chronicler.swift`:

```swift
//
//  Chronicler.swift
//  OmWhisper
//
//  Map-reduce daily summarization: this app has exactly one PolishBackend
//  (SystemLLM, on-device Foundation Models) whose polish() call has a
//  hardcoded 5s timeout already found (S4) to need inputs capped around
//  2,000 chars. A whole day's snapshots regularly exceed that, so instead of
//  smriti's single ~120,000-char digest call, this chunks the day into
//  ≤1,800-char groups, summarizes each chunk (map), then writes the final
//  chronicle from the concatenated chunk summaries (reduce) -- every
//  individual polish() call stays inside the already-proven-safe zone, no
//  changes to PolishBackend/SystemLLM.
//

import Foundation

nonisolated enum Chronicler {
    struct ChronicleResult {
        let day: String
        let summary: String
        let snapshotCount: Int
    }

    enum ChroniclerError: Error, LocalizedError, Equatable {
        case noSnapshots
        var errorDescription: String? { "No captured activity for that day." }
    }

    static let perSnapshotLimit = 500
    static let chunkCharLimit = 1_800
    static let reduceCharLimit = 1_800

    /// Fixed-UUID internal styles -- never shown in the AI tab's picker (not
    /// added to PolishStyles.builtIns), same pattern as S4's hidden
    /// reply-draft style.
    static let chunkSummaryStyle = PolishStyle(
        id: UUID(uuidString: "6C8A1C1E-0000-4A00-8000-000000000001")!,
        name: "Memory Chunk Summary",
        prompt: """
            Summarize this log of app/window activity into 2-4 terse bullet \
            points of what was worked on. No preamble, just bullets.
            """,
        isBuiltIn: true
    )
    static let chronicleWriteStyle = PolishStyle(
        id: UUID(uuidString: "6C8A1C1E-0000-4A00-8000-000000000002")!,
        name: "Memory Chronicle",
        prompt: """
            You are writing a private daily chronicle from bullet-point \
            activity summaries captured from the user's Mac screen \
            throughout the day. Write a concise markdown chronicle with \
            these sections:
            ## Summary — 2-3 sentences on what the day was about.
            ## Work & projects — what was worked on, per project/task, \
            merging repeated mentions of the same thing.
            ## Notable — anything worth remembering later: decisions, \
            errors, things ordered/booked, articles read.
            Rules: be specific, no filler, no speculation beyond what the \
            bullets show. The reader is the user themselves — write in \
            second person ("you worked on...").
            """,
        isBuiltIn: true
    )

    /// Pure: one digest line for a snapshot, content clipped to perSnapshotLimit.
    static func formatBlock(_ snapshot: MemorySnapshot) -> String {
        let content = snapshot.content
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(perSnapshotLimit)
        let location = snapshot.url.isEmpty ? "" : " <\(snapshot.url)>"
        return "[\(snapshot.lastSeenAt)] \(snapshot.appName) — \(snapshot.windowTitle)\(location)\n\(content)"
    }

    /// Pure: greedily packs blocks into groups whose combined length (with a
    /// blank-line separator between blocks) stays under `limit`. A single
    /// block longer than `limit` becomes its own oversized group rather than
    /// being split mid-block or dropped.
    static func chunk(_ blocks: [String], limit: Int = chunkCharLimit) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var currentLength = 0
        for block in blocks {
            let addedLength = block.count + (current.isEmpty ? 0 : 2)
            if !current.isEmpty && currentLength + addedLength > limit {
                groups.append(current)
                current = [block]
                currentLength = block.count
            } else {
                current.append(block)
                currentLength += addedLength
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Effectful: full generation for one day. Throws ChroniclerError.noSnapshots
    /// if there are no snapshots for that day; propagates the first polish()
    /// failure. Overwrites any existing chronicle for the same day.
    static func generate(day: String, store: MemoryStore, polish: PolishBackend) async throws -> ChronicleResult {
        let snapshots = try store.snapshotsForDay(day)
        guard !snapshots.isEmpty else {
            throw ChroniclerError.noSnapshots
        }
        let blocks = snapshots.map(formatBlock)
        let chunks = chunk(blocks)

        var chunkSummaries: [String] = []
        for group in chunks {
            let text = String(group.joined(separator: "\n\n").prefix(chunkCharLimit))
            let summary = try await polish.polish(text, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(reduceCharLimit))
        let chronicle = try await polish.polish(reduceInput, style: chronicleWriteStyle, targetLanguage: nil)
        let trimmed = chronicle.trimmingCharacters(in: .whitespacesAndNewlines)

        try store.upsertChronicle(day: day, summary: trimmed, snapshotCount: snapshots.count)
        return ChronicleResult(day: day, summary: trimmed, snapshotCount: snapshots.count)
    }

    /// Local calendar date string, matching smriti's dayString(daysAgo:).
    static func dayString(daysAgo: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test -only-testing:omwhisper-nativeTests/ChroniclerTests`
Expected: PASS — all 11 `ChroniclerTests` tests green.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/Chronicler.swift omwhisper-nativeTests/ChroniclerTests.swift
git commit -m "✨ feat(memory): add Chronicler (map-reduce daily summarization)"
```

---

### Task 3: ChronicleScheduler (daily Timer trigger)

**Files:**
- Create: `omwhisper-native/Memory/ChronicleScheduler.swift`

**Interfaces:**
- Consumes: `Chronicler.dayString(daysAgo:)`, `Chronicler.generate(day:store:polish:)` from Task 2; `MemoryStore`; `PolishBackend`.
- Produces: `@MainActor final class ChronicleScheduler` with `var store: MemoryStore?`, `var polish: PolishBackend?`, `var isSuppressed: () -> Bool`, `func start()`, `func stop()` (consumed by Task 4's `AppState` wiring).

No unit tests for this task: `ChronicleScheduler` is a thin Timer wrapper with
no pure logic to extract beyond what Task 2 already tests (`Chronicler.generate`'s
behavior) — the same reasoning `MemoryCapture`'s own poll/prune Timer isn't
unit-tested (only its pure `isDomainExcluded` helper is, in
`MemoryCaptureExclusionTests`). Verified by live testing in Task 6.

- [ ] **Step 1: Implement ChronicleScheduler.swift**

Create `omwhisper-native/Memory/ChronicleScheduler.swift`:

```swift
//
//  ChronicleScheduler.swift
//  OmWhisper
//
//  Timer-driven daily trigger for Chronicler.generate(), mirroring
//  MemoryCapture's own pollTimer/pruneTimer + fire-once-at-start() shape.
//  Deliberately separate from Chronicler (pure logic) and MemoryCapture (raw
//  capture/prune) -- this needs a PolishBackend, a different dependency than
//  either of those.
//
//  @MainActor: a lightweight daily poll, not a real-time path -- matches
//  MemoryCapture's isolation.
//

import Foundation
import os

private let chronicleLog = Logger(subsystem: "com.omwhisper.mac", category: "ChronicleScheduler")

@MainActor
final class ChronicleScheduler {
    private static let interval: TimeInterval = 86_400

    var store: MemoryStore?
    var polish: PolishBackend?
    var isSuppressed: () -> Bool = { false }

    private var timer: Timer?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.generateIfNeeded() }
        }
        Task { @MainActor in await generateIfNeeded() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func generateIfNeeded() async {
        guard !isSuppressed(), let store, let polish else { return }
        let yesterday = Chronicler.dayString(daysAgo: 1)
        guard (try? store.getChronicle(day: yesterday)) == nil else { return }
        do {
            _ = try await Chronicler.generate(day: yesterday, store: store, polish: polish)
        } catch {
            chronicleLog.error("generateIfNeeded — failed for \(yesterday): \(error)")
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build`
Expected: BUILD SUCCEEDED (this file has no callers yet — Task 4 wires it in
— so success here just confirms it type-checks standalone).

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Memory/ChronicleScheduler.swift
git commit -m "✨ feat(memory): add ChronicleScheduler (daily Timer trigger)"
```

---

### Task 4: AppState wiring

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `ChronicleScheduler` from Task 3; existing `memoryStore`, `systemLLM`, `polishBackend`, `memoryEnabled` setter.
- Produces: `AppState` now starts/stops a `ChronicleScheduler` alongside `MemoryCapture` whenever `memoryEnabled` toggles (consumed by Task 6's live verification; no new public interface for later tasks).

No unit tests for this task — `AppState` itself has no direct unit test file
in this project (verified via the full test suite staying green plus live
verification, matching every prior `AppState` wiring task in this codebase:
S1 Task 5, S4 Task 6).

- [ ] **Step 1: Add the chronicleScheduler property**

In `omwhisper-native/AppState.swift`, right after the existing line (around
line 362):

```swift
    @ObservationIgnored private let memoryCapture = MemoryCapture()
```

add:

```swift
    @ObservationIgnored private let chronicleScheduler = ChronicleScheduler()
```

- [ ] **Step 2: Wire chronicleScheduler into the memoryEnabled setter**

In `omwhisper-native/AppState.swift`, the existing `memoryEnabled` setter
currently reads (around line 281):

```swift
        set {
            withMutation(keyPath: \.memoryEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryEnabled)
            }
            if newValue {
                memoryCapture.store = memoryStore
                memoryCapture.isSuppressed = { [weak self] in self?.memoryPaused ?? false }
                memoryCapture.captureIntervalSeconds = 5
                memoryCapture.retentionDays = memoryRetentionDays
                memoryCapture.start()
            } else {
                memoryCapture.stop()
            }
        }
```

Replace it with:

```swift
        set {
            withMutation(keyPath: \.memoryEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryEnabled)
            }
            if newValue {
                memoryCapture.store = memoryStore
                memoryCapture.isSuppressed = { [weak self] in self?.memoryPaused ?? false }
                memoryCapture.captureIntervalSeconds = 5
                memoryCapture.retentionDays = memoryRetentionDays
                memoryCapture.start()
                chronicleScheduler.store = memoryStore
                chronicleScheduler.polish = systemLLM
                chronicleScheduler.isSuppressed = { [weak self] in
                    self?.polishBackend != .system || !SystemLLM.isAvailable()
                }
                chronicleScheduler.start()
            } else {
                memoryCapture.stop()
                chronicleScheduler.stop()
            }
        }
```

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: BUILD SUCCEEDED, all existing tests still pass (no regressions —
this task adds no new tests of its own).

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(memory): wire ChronicleScheduler into AppState's memoryEnabled setter"
```

---

### Task 5: MemoryView + MemorySnapshotsView + MemoryChroniclesView + window/menu wiring

Combined into one task rather than split across two: `MemoryView` directly
references `MemoryChroniclesView` in its `switch tab` body, so splitting
them would leave the project non-building between tasks — violating "each
task ends with an independently testable deliverable." One task, several
files, one build/test/commit at the end.

**Files:**
- Create: `omwhisper-native/UI/MemoryView.swift`
- Create: `omwhisper-native/UI/MemoryChroniclesView.swift`
- Modify: `omwhisper-native/OmWhisperApp.swift`
- Modify: `omwhisper-native/UI/MemorySettingsView.swift`
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `AppState.memoryStore` (from S1); `MemoryStore.fetchPage(offset:limit:)`/`search(_:limit:)`/`delete(id:)`/`deleteAll()`/`storageInfo()`/`listChronicles(limit:)` (from Task 1); `MemorySnapshot`, `MemoryChronicle`; `Chronicler.generate(day:store:polish:)`/`Chronicler.ChronicleResult`/`Chronicler.ChroniclerError` (from Task 2).
- Produces: `struct MemoryView: View`; `struct MemoryChroniclesView: View`; `AppState.regenerateChronicle(day:) async throws -> Chronicler.ChronicleResult`; `Window("Memory", id: "memory")` scene; "Memory…" menu item (consumed by Task 6's live verification; no further tasks depend on these).

No unit tests — SwiftUI views in this project are verified by building +
live verification only (matches `HistoryView`, `SettingsView`, every other
view). Verified live in Task 6.

- [ ] **Step 1: Create MemoryView.swift with the Snapshots tab**

Create `omwhisper-native/UI/MemoryView.swift`:

```swift
//
//  MemoryView.swift
//  OmWhisper
//
//  Browse/search captured memory snapshots + daily chronicles. Snapshots tab
//  structurally mirrors HistoryView.swift's proven shape (searchable List,
//  debounced reload, tap-to-expand rows, pagination) -- deliberately no
//  Export menu (captured screen text isn't meant to leave the device
//  casually) and no multi-select bulk delete (single delete + Clear All
//  covers it; add bulk-select if it turns out to matter).
//

import SwiftUI

struct MemoryView: View {
    private enum Tab { case snapshots, chronicles }
    @State private var tab: Tab = .snapshots

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Snapshots").tag(Tab.snapshots)
                Text("Chronicles").tag(Tab.chronicles)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .snapshots: MemorySnapshotsView()
            case .chronicles: MemoryChroniclesView()
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

private struct MemorySnapshotsView: View {
    @Environment(AppState.self) private var appState

    @State private var entries: [MemorySnapshot] = []
    @State private var searchText = ""
    @State private var offset = 0
    @State private var canLoadMore = true
    @State private var storageInfo: (count: Int, bytes: Int64)?
    @State private var expandedID: Int64?
    @State private var errorMessage: String?
    @State private var showClearConfirmation = false

    private let pageSize = 30
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .searchable(text: $searchText, prompt: "Search captured memory")
        .toolbar {
            ToolbarItemGroup {
                Button("Clear All", role: .destructive) { showClearConfirmation = true }
            }
        }
        .task(id: searchText) { await reload() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Clear all captured memory? This can't be undone.", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { clearAll() }
        }
    }

    private var list: some View {
        List {
            ForEach(entries) { entry in
                MemorySnapshotRow(
                    entry: entry,
                    isExpanded: expandedID == entry.id,
                    onToggleExpand: { expandedID = expandedID == entry.id ? nil : entry.id },
                    onCopy: { copy(entry) },
                    onDelete: { delete(entry) }
                )
                .onAppear { loadNextPageIfNeeded(current: entry) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("🧠").font(.system(size: 40))
            Text("Nothing captured yet").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if let storageInfo {
                Text("\(storageInfo.count) snapshot\(storageInfo.count == 1 ? "" : "s") · \(formatBytes(storageInfo.bytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
    }

    private func reload() async {
        if isSearching {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            search()
        } else {
            loadFirstPage()
        }
    }

    private func loadFirstPage() {
        guard let store = appState.memoryStore else { return }
        do {
            entries = try store.fetchPage(offset: 0, limit: pageSize)
            offset = entries.count
            canLoadMore = entries.count == pageSize
            storageInfo = try store.storageInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadNextPageIfNeeded(current: MemorySnapshot) {
        guard !isSearching, canLoadMore, current.id == entries.last?.id, let store = appState.memoryStore else { return }
        do {
            let next = try store.fetchPage(offset: offset, limit: pageSize)
            entries.append(contentsOf: next)
            offset += next.count
            canLoadMore = next.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func search() {
        guard let store = appState.memoryStore else { return }
        do {
            entries = try store.search(searchText, limit: 100)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copy(_ entry: MemorySnapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.content, forType: .string)
    }

    private func delete(_ entry: MemorySnapshot) {
        guard let id = entry.id, let store = appState.memoryStore else { return }
        do {
            try store.delete(id: id)
            entries.removeAll { $0.id == id }
            storageInfo = try? store.storageInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAll() {
        guard let store = appState.memoryStore else { return }
        do {
            try store.deleteAll()
            loadFirstPage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Tap-to-expand row: collapsed shows app/window/2-line content preview;
/// expanded shows full content with Copy/Delete.
private struct MemorySnapshotRow: View {
    let entry: MemorySnapshot
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.appName).fontWeight(.medium)
                Text(entry.windowTitle).foregroundStyle(.secondary)
            }
            .font(.callout)
            Text(entry.content)
                .lineLimit(isExpanded ? nil : 2)
                .font(.body)
            HStack(spacing: 4) {
                Text(entry.lastSeenAt)
                if !entry.url.isEmpty {
                    Text("· \(entry.url)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if isExpanded {
                HStack {
                    Button("Copy", action: onCopy)
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand() }
        .padding(.vertical, 2)
    }
}

#Preview {
    MemoryView().environment(AppState())
}
```

- [ ] **Step 2: Add AppState.regenerateChronicle(day:)**

In `omwhisper-native/AppState.swift`, add this method near the other
memory-related code (right after the `memoryRetentionDays` computed
property, around line 321, before the `// MARK: Core loop collaborators`
comment):

```swift

    func regenerateChronicle(day: String) async throws -> Chronicler.ChronicleResult {
        guard let memoryStore else { throw Chronicler.ChroniclerError.noSnapshots }
        return try await Chronicler.generate(day: day, store: memoryStore, polish: systemLLM)
    }
```

- [ ] **Step 3: Create MemoryChroniclesView.swift**

Create `omwhisper-native/UI/MemoryChroniclesView.swift`:

```swift
//
//  MemoryChroniclesView.swift
//  OmWhisper
//
//  Day list (left) + chronicle detail (right). SwiftUI-native replacement
//  for smriti's raw AppKit ChronicleTimelineSection -- that file is layout
//  reference only, per this project's established "UI sections: rebuild,
//  smriti is wireframe reference" convention (see S1's port map).
//

import SwiftUI

struct MemoryChroniclesView: View {
    @Environment(AppState.self) private var appState

    @State private var chronicles: [MemoryChronicle] = []
    @State private var selectedDay: String?
    @State private var isRegenerating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(chronicles, selection: $selectedDay) { chronicle in
                VStack(alignment: .leading) {
                    Text(chronicle.day).fontWeight(.medium)
                    Text("\(chronicle.snapshotCount) snapshot\(chronicle.snapshotCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            detail
        }
        // Always visible (not just when a chronicle is selected) -- with
        // zero chronicles generated yet (the normal first-run state), this
        // is the only way to ever produce the first one. Also doubles as
        // "regenerate today" since Chronicler.generate always overwrites.
        // ponytail: only regenerates today, not an arbitrary past day --
        // add a per-day action if users need to fix an older chronicle.
        .toolbar {
            ToolbarItem {
                Button {
                    generateTodaysChronicle()
                } label: {
                    if isRegenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Generate Today's Chronicle")
                    }
                }
                .disabled(isRegenerating)
            }
        }
        .task { load() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if chronicles.isEmpty {
            emptyState
        } else if let selectedDay, let chronicle = chronicles.first(where: { $0.day == selectedDay }) {
            ScrollView {
                Text(.init(chronicle.summary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            Text("Select a day").foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("📅").font(.system(size: 40))
            Text("Chronicles appear here once a day, generated automatically. Use \"Generate Today's Chronicle\" above to create the first one now.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        guard let store = appState.memoryStore else { return }
        do {
            chronicles = try store.listChronicles(limit: 60)
            if selectedDay == nil { selectedDay = chronicles.first?.day }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateTodaysChronicle() {
        isRegenerating = true
        Task {
            defer { isRegenerating = false }
            do {
                let result = try await appState.regenerateChronicle(day: Chronicler.dayString())
                load()
                selectedDay = result.day
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    MemoryChroniclesView().environment(AppState())
}
```

- [ ] **Step 4: Add the Memory window scene and menu item to OmWhisperApp.swift**

In `omwhisper-native/OmWhisperApp.swift`, the `makeScene()` function
currently ends with (around line 44):

```swift
        Window("History", id: "history") {
            HistoryView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}
```

Replace it with:

```swift
        Window("History", id: "history") {
            HistoryView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
        Window("Memory", id: "memory") {
            MemoryView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}
```

Also in the same function, the setup closure currently reads (around line 32-35):

```swift
        let _ = {
            delegate.openSettingsAction = openSettings
            delegate.openHistoryAction = openWindow
        }()
```

Replace it with:

```swift
        let _ = {
            delegate.openSettingsAction = openSettings
            delegate.openHistoryAction = openWindow
            delegate.openMemoryAction = openWindow
        }()
```

In `AppDelegate`, the existing property (around line 65):

```swift
    var openHistoryAction: OpenWindowAction?
```

becomes:

```swift
    var openHistoryAction: OpenWindowAction?
    var openMemoryAction: OpenWindowAction?
```

The existing menu item line (around line 137):

```swift
        addItem(to: menu, title: "History…", action: #selector(openHistory))
```

becomes:

```swift
        addItem(to: menu, title: "History…", action: #selector(openHistory))
        addItem(to: menu, title: "Memory…", action: #selector(openMemory))
```

The existing action method (around line 166-169):

```swift
    @objc private func openHistory() {
        NSApp.activate(ignoringOtherApps: true)
        openHistoryAction?(id: "history")
    }
```

gets a sibling right after it:

```swift
    @objc private func openHistory() {
        NSApp.activate(ignoringOtherApps: true)
        openHistoryAction?(id: "history")
    }

    @objc private func openMemory() {
        NSApp.activate(ignoringOtherApps: true)
        openMemoryAction?(id: "memory")
    }
```

- [ ] **Step 5: Update MemorySettingsView.swift's stale header comment**

In `omwhisper-native/UI/MemorySettingsView.swift`, the header comment
currently reads:

```swift
//  No search/browse UI here -- that's S5's job entirely. Just the toggle,
//  pause, and retention controls this sub-project's scope covers.
```

Replace it with:

```swift
//  Just the toggle, pause, and retention controls -- search/browse UI lives
//  in MemoryView.swift (Window("Memory"), opened from the menu bar).
```

- [ ] **Step 6: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: BUILD SUCCEEDED, all tests pass (no regressions — this task adds
no new automated tests of its own).

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/UI/MemoryView.swift omwhisper-native/UI/MemoryChroniclesView.swift omwhisper-native/OmWhisperApp.swift omwhisper-native/UI/MemorySettingsView.swift omwhisper-native/AppState.swift
git commit -m "✨ feat(memory): add Memory window (Snapshots + Chronicles tabs) + window/menu wiring"
```

---

### Task 6: Live verification + docs

**Files:**
- Modify: `CLAUDE.md`

No new code in this task — build the app, run it, and confirm the feature
works end-to-end on real hardware, then record what was found.

- [ ] **Step 1: Build and launch the app**

Build via Xcode (Cmd+B) or:

```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build
```

Find the freshest built `.app` (per this project's established practice —
multiple stale `DerivedData` dirs accumulate):

```bash
find ~/Library/Developer/Xcode/DerivedData -name "OmWhisper.app" -exec stat -f "%m %N" {} \; | sort -rn | head -1
```

Launch it, or run it from Xcode directly (Cmd+R).

- [ ] **Step 2: Enable Memory and confirm chronicle generation eventually fires**

In Settings → Memory tab, toggle "Remember what's on screen" on, confirm AI
polish backend is set to "System" in the AI tab (required for chronicle
generation per the `isSuppressed` gate). Since `ChronicleScheduler` only
generates *yesterday's* chronicle and skips a day that already has one,
real-time verification of the full 24h cycle isn't practical in one sitting.
Instead, verify the mechanism directly: open the Memory window (menu bar →
"Memory…"), confirm the Snapshots tab shows captured activity (reuses S1's
already-proven capture daemon), then switch to the Chronicles tab and click
the toolbar's "Generate Today's Chronicle" button. Confirm a spinner
appears, then a markdown-rendered chronicle appears in the detail pane with
Summary/Work & projects/Notable sections, and the day list now shows today
selected. This exercises the exact same `Chronicler.generate` code path
`ChronicleScheduler`'s daily timer calls — proves the map-reduce pipeline
works against real snapshot data and a real `SystemLLM` call end-to-end.
Click the button again and confirm it overwrites today's chronicle rather
than duplicating it in the day list.

- [ ] **Step 3: Verify the Snapshots tab search and delete**

In the Memory window's Snapshots tab: confirm recent captures appear with
empty search; type a word known to appear in a captured window's content
and confirm it filters via FTS5 search; tap a row to expand and confirm
Copy/Delete work; confirm the footer shows a snapshot count and byte size.

- [ ] **Step 4: Verify Memory disabled stops chronicle generation**

Toggle Memory off in Settings. Confirm `ChronicleScheduler` stops (no crash,
no further generation) — this is best confirmed by code review of the
`memoryEnabled` setter (Task 4) rather than a multi-day wait; note in the
report that this was verified by inspection, not a live multi-day run, if
that's the case.

- [ ] **Step 5: Update CLAUDE.md**

Add a paragraph to the S1–S6 row of the Progress Tracker table (or a new
row if S5 doesn't have one yet) documenting: S5.1 shipped, the map-reduce
Chronicler design decision and why (only one PolishBackend, 5s timeout,
2,000-char proven-safe ceiling from S4), the new Memory window with
Snapshots/Chronicles tabs, `ChronicleScheduler`'s daily-idempotent
generation, and results from Steps 2-4's live verification (what was
confirmed working, what was verified by inspection rather than a live
multi-day run). Follow the same level of detail as the S1 row already in
that table.

- [ ] **Step 6: Commit the docs update**

```bash
git add CLAUDE.md
git commit -m "📝 docs: mark S5.1 (chronicles + memory browse UI) shipped"
```
