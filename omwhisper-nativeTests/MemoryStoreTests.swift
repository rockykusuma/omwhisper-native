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

    // MARK: - passages (semantic search)

    @Test func passagesRoundTripAndReplaceCleanly() throws {
        let store = try makeStore()
        try store.upsert(appName: "Arc", bundleID: "com.arc", windowTitle: "T",
                         content: "radiology appointment booking", url: "")
        let snap = try #require(try store.fetchPage(offset: 0, limit: 1).first)
        let id = try #require(snap.id)

        try store.replacePassages(snapshotId: id, passages: [("first", Data([1, 2])), ("second", Data([3, 4]))])
        #expect(try store.allPassageVectors().count == 2)

        // Replacing is not appending — re-indexing a snapshot must not duplicate.
        try store.replacePassages(snapshotId: id, passages: [("only", Data([5, 6]))])
        let rows = try store.allPassageVectors()
        #expect(rows.count == 1)
        #expect(rows.first?.text == "only")
    }

    /// Deleting a snapshot must take its passages: the prune runs daily and an
    /// orphaned vector index would grow without bound.
    @Test func deletingASnapshotDeletesItsPassages() throws {
        let store = try makeStore()
        try store.upsert(appName: "Arc", bundleID: "com.arc", windowTitle: "T",
                         content: "some content", url: "")
        let id = try #require(try store.fetchPage(offset: 0, limit: 1).first?.id)
        try store.replacePassages(snapshotId: id, passages: [("p", Data([1, 2]))])
        try store.delete(id: id)
        #expect(try store.allPassageVectors().isEmpty)
    }

    @Test func snapshotsMissingPassagesDrivesBackfill() throws {
        let store = try makeStore()
        try store.upsert(appName: "A", bundleID: "a", windowTitle: "1", content: "one", url: "")
        try store.upsert(appName: "A", bundleID: "a", windowTitle: "2", content: "two", url: "")
        #expect(try store.snapshotsMissingPassages(limit: 10).count == 2)

        let first = try #require(try store.snapshotsMissingPassages(limit: 10).first?.id)
        try store.replacePassages(snapshotId: first, passages: [("p", Data([1, 2]))])
        #expect(try store.snapshotsMissingPassages(limit: 10).count == 1)
    }

    // MARK: - hybrid search

    /// A stub embedder makes semantic ranking deterministic and model-free:
    /// the vector is just term-presence, so "cost" and "pricing" can be made
    /// to look alike without shipping a model into the test.
    private struct StubEmbedder: MemoryEmbedder {
        var dimension: Int { 3 }
        func vector(_ text: String) -> [Float]? {
            let t = text.lowercased()
            return [t.contains("cost") || t.contains("pricing") ? 1 : 0,
                    t.contains("hearing") ? 1 : 0,
                    t.contains("build") ? 1 : 0]
        }
    }

    private func indexAll(_ store: MemoryStore, _ emb: MemoryEmbedder) throws {
        for s in try store.snapshotsMissingPassages(limit: 100) {
            guard let id = s.id else { continue }
            let vecs = SemanticIndexing.passages(s.content).compactMap { p -> (String, Data)? in
                guard let v = emb.vector(p) else { return nil }
                return (p, SemanticIndexing.encode(v))
            }
            try store.replacePassages(snapshotId: id, passages: vecs)
        }
    }

    @Test func hybridFindsAParaphraseKeywordSearchCannot() throws {
        let store = try makeStore()
        try store.upsert(appName: "Arc", bundleID: "a", windowTitle: "Costs",
                         content: "our cost structure for next year", url: "")
        try store.upsert(appName: "Arc", bundleID: "a", windowTitle: "Aids",
                         content: "hearing aid firmware notes", url: "")
        let emb = StubEmbedder()
        try indexAll(store, emb)

        // "pricing" appears nowhere in the corpus — keyword search finds nothing.
        #expect(try store.search("pricing").isEmpty)
        let hits = try store.hybridSearch("pricing", embedder: emb, limit: 5)
        #expect(hits.first?.snapshot.windowTitle == "Costs")
        #expect(hits.first?.matchedPassage?.contains("cost structure") == true)
    }

    /// The non-negotiable: with no embedder, behaviour is exactly today's.
    @Test func hybridWithoutEmbedderEqualsKeywordSearch() throws {
        let store = try makeStore()
        try store.upsert(appName: "Arc", bundleID: "a", windowTitle: "T",
                         content: "quarterly revenue report", url: "")
        let hybrid = try store.hybridSearch("revenue", embedder: nil, limit: 5).map(\.snapshot.id)
        let keyword = try store.search("revenue").map(\.id)
        #expect(hybrid == keyword)
        #expect(!hybrid.isEmpty)
    }
}
