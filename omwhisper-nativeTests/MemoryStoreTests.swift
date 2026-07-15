import Testing
import Foundation
import GRDB
@testable import OmWhisper

@Suite("MemoryStore")
struct MemoryStoreTests {
    private func makeStore() throws -> MemoryStore {
        try MemoryStore(DatabaseQueue())  // in-memory, fresh per test
    }

    @Test("contentHash is stable and content-sensitive")
    func hashIsStableAndSensitive() {
        let a = MemoryStore.contentHash("hello world")
        let b = MemoryStore.contentHash("hello world")
        let c = MemoryStore.contentHash("hello there")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("upsertDecision creates a new row when nothing matches")
    func decisionCreatesNew() {
        let row = MemoryStore.upsertDecision(
            existing: nil, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled",
            content: "hello", url: "", contentHash: "h1", now: "2026-07-08T00:00:00Z"
        )
        #expect(row.id == nil)
        #expect(row.capturedAt == "2026-07-08T00:00:00Z")
        #expect(row.lastSeenAt == "2026-07-08T00:00:00Z")
    }

    @Test("upsertDecision reuses the existing row, bumping only lastSeenAt")
    func decisionReusesExisting() {
        let existing = MemorySnapshot(
            id: 42, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled",
            content: "hello", url: "", contentHash: "h1", capturedAt: "2026-07-08T00:00:00Z", lastSeenAt: "2026-07-08T00:00:00Z"
        )
        let row = MemoryStore.upsertDecision(
            existing: existing, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled",
            content: "hello", url: "", contentHash: "h1", now: "2026-07-08T00:05:00Z"
        )
        #expect(row.id == 42)
        #expect(row.capturedAt == "2026-07-08T00:00:00Z")  // unchanged
        #expect(row.lastSeenAt == "2026-07-08T00:05:00Z")  // bumped
    }

    @Test("upsert inserts on first capture and dedupes an unchanged repeat")
    func upsertDedupesRepeat() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "hello", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "hello", url: "")
        let results = try store.search("hello", limit: 10)
        #expect(results.count == 1)
    }

    @Test("upsert with changed content creates a second row")
    func upsertChangedContentInsertsNew() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "hello", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "goodbye", url: "")
        let results = try store.search("hello", limit: 10)
        #expect(results.count == 1)
        let all = try store.search("hello OR goodbye", limit: 10)
        #expect(all.count == 2)
    }

    @Test("search finds content via FTS5")
    func searchFindsContent() throws {
        let store = try makeStore()
        try store.upsert(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Inbox", content: "quarterly budget review", url: "")
        let results = try store.search("budget", limit: 10)
        #expect(results.count == 1)
        #expect(results.first?.appName == "Mail")
    }

    @Test("prune(olderThanDays: 0) is a no-op")
    func pruneZeroIsNoOp() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Old", content: "stale content", url: "")
        try store.prune(olderThanDays: 0)
        #expect(try store.search("stale", limit: 10).count == 1)
    }

    @Test("prune removes rows whose lastSeenAt is older than the retention window")
    func pruneRemovesOldRows() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Old", content: "stale content", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Fresh", content: "fresh content", url: "")
        // upsert always stamps lastSeenAt = now, so directly backdate the
        // "Old" row via dbQueue (internal, not private -- exposed
        // specifically so tests can exercise real time-based deletion
        // without injecting a clock into MemoryStore's production API).
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-100 * 86_400))
        try store.dbQueue.write { db in
            try MemorySnapshot.filter(Column("windowTitle") == "Old").updateAll(db, Column("lastSeenAt").set(to: old))
        }
        try store.prune(olderThanDays: 90)
        #expect(try store.search("stale", limit: 10).isEmpty)
        #expect(try store.search("fresh", limit: 10).count == 1)
    }

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

    /// Queries by Chronicler.dayString — the LOCAL day — deliberately, not by
    /// slicing the UTC ISO8601 string. The two must agree; when they didn't, a
    /// chronicle generated between midnight and UTC-offset (00:00–05:30 IST) asked
    /// for yesterday's date and got yesterday's snapshots. Using the real
    /// dayString here is what pins them together.
    @Test("snapshotsForDay returns only that day's snapshots, oldest first")
    func snapshotsForDayFiltersByDate() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Today", content: "today content", url: "")
        let yesterday = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        try store.dbQueue.write { db in
            try MemorySnapshot.filter(Column("windowTitle") == "Today")
                .updateAll(db, Column("capturedAt").set(to: yesterday), Column("lastSeenAt").set(to: yesterday))
        }
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "TodayReal", content: "real today", url: "")
        let results = try store.snapshotsForDay(Chronicler.dayString())
        #expect(results.map(\.windowTitle) == ["TodayReal"])
    }

    /// The regression directly: a snapshot captured just after local midnight
    /// belongs to today, even while UTC still says yesterday.
    @Test("a snapshot taken now is found under today's local day")
    func snapshotsForDayUsesLocalDay() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Now", content: "just captured", url: "")
        #expect(try store.snapshotsForDay(Chronicler.dayString()).map(\.windowTitle) == ["Now"])
        #expect(try store.snapshotsForDay(Chronicler.dayString(daysAgo: 1)).isEmpty)
    }

    @Test("recent returns snapshots seen within the window, newest first")
    func recentReturnsWithinWindow() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Fresh", content: "fresh content", url: "")
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Stale", content: "stale content", url: "")
        try store.dbQueue.write { db in
            try MemorySnapshot.filter(Column("windowTitle") == "Stale").updateAll(db, Column("lastSeenAt").set(to: stale))
        }
        let results = try store.recent(minutes: 30, limit: 10)
        #expect(results.map(\.windowTitle) == ["Fresh"])
    }

    @Test("recent respects limit")
    func recentRespectsLimit() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "A", content: "a", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "B", content: "b", url: "")
        let results = try store.recent(minutes: 30, limit: 1)
        #expect(results.count == 1)
    }

    @Test("getSnapshot returns the matching row by id")
    func getSnapshotReturnsMatch() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "hello", url: "")
        let rows = try store.fetchPage(offset: 0, limit: 1)
        guard let id = rows.first?.id else {
            Issue.record("expected row to have an id")
            return
        }
        let result = try store.getSnapshot(id: id)
        #expect(result?.content == "hello")
    }

    @Test("getSnapshot returns nil for an unknown id")
    func getSnapshotReturnsNilForUnknown() throws {
        let store = try makeStore()
        #expect(try store.getSnapshot(id: 999) == nil)
    }
}
