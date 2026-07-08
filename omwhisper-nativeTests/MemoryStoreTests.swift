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
}
