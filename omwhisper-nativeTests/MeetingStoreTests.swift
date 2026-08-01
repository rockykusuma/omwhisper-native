import Foundation
import GRDB
import Testing
@testable import OmWhisper

@Suite("MeetingStore", .serialized)
struct MeetingStoreTests {
    private func makeStore() throws -> MeetingStore { try MeetingStore(DatabaseQueue()) }

    private func seed(_ store: MeetingStore, app: String, dir: String = "/tmp/omw-test-\(UUID().uuidString)") throws -> Int64 {
        try store.insert(Meeting(
            id: nil, startedAt: ISO8601DateFormatter().string(from: Date()),
            appName: app, directory: dir, durationSeconds: 90,
            transcript: nil, summary: nil, createdAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    @Test func insertGetAndCount() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Zoom")
        let got = try store.get(id: id)
        #expect(got?.appName == "Zoom")
        #expect(got?.transcript == nil)
        #expect(try store.count() == 1)
    }

    @Test func setTranscriptAndSummary() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Meet")
        try store.setTranscriptAndSummary(id: id, transcript: "**You:**\nhi", summary: "## Summary\nshort")
        let got = try store.get(id: id)
        #expect(got?.transcript == "**You:**\nhi")
        #expect(got?.summary == "## Summary\nshort")
    }

    @Test func fetchPageNewestFirst() throws {
        let store = try makeStore()
        _ = try seed(store, app: "First")
        _ = try seed(store, app: "Second")
        _ = try seed(store, app: "Third")
        let page = try store.fetchPage(offset: 0, limit: 10)
        #expect(page.count == 3)
        #expect(page.first?.appName == "Third")   // newest (highest id) first
    }

    @Test func searchMatchesTranscriptAndApp() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Webex")
        try store.setTranscriptAndSummary(id: id, transcript: "we discussed the quarterly roadmap", summary: nil)
        #expect(try store.search("roadmap", limit: 10).count == 1)
        #expect(try store.search("Webex", limit: 10).count == 1)
        #expect(try store.search("unrelated", limit: 10).isEmpty)
    }

    @Test func deleteRemovesRowAndDirectory() throws {
        let store = try makeStore()
        let dir = NSTemporaryDirectory() + "omw-meeting-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = try store.insert(Meeting(
            id: nil, startedAt: "s", appName: "App", directory: dir, durationSeconds: 1,
            transcript: nil, summary: nil, createdAt: "c"
        ))
        try store.delete(id: id)
        #expect(try store.get(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func deleteAllClearsRows() throws {
        let store = try makeStore()
        _ = try seed(store, app: "A")
        _ = try seed(store, app: "B")
        try store.deleteAll()
        #expect(try store.count() == 0)
    }

    /// Replicates the v1 schema exactly (same migration identifier), seeds a row,
    /// then lets MeetingStore run only the NEW migration on the same queue —
    /// proving existing databases survive with data + FTS intact.
    private func makeV1Queue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createMeetings") { db in
            try db.create(table: "meetings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("directory", .text).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("transcript", .text)
                t.column("summary", .text)
                t.column("createdAt", .text).notNull()
            }
            try db.create(virtualTable: "meetings_fts", using: FTS5()) { t in
                t.synchronize(withTable: "meetings")
                t.column("transcript")
                t.column("summary")
                t.column("appName")
            }
        }
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (startedAt, appName, directory, durationSeconds, transcript, summary, createdAt)
                VALUES ('2026-07-01T10:00:00Z', 'Zoom', '/tmp/omw-v1-test', 60,
                        'quarterly roadmap discussion', NULL, '2026-07-01T11:00:00Z')
                """)
        }
        return dbQueue
    }

    @Test func v1DatabaseMigratesInPlace() throws {
        let queue = try makeV1Queue()
        let store = try MeetingStore(queue)
        let all = try store.fetchPage(offset: 0, limit: 10)
        #expect(all.count == 1)
        #expect(all.first?.title == nil)
        #expect(all.first?.attendees == nil)
        #expect(all.first?.speakerNames == nil)
        // FTS survived the drop-and-recreate and still matches old content.
        #expect(try store.search("roadmap", limit: 10).count == 1)
    }

    @Test func titleAttendeesSpeakerNamesRoundTrip() throws {
        let store = try makeStore()
        let id = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-01T10:00:00Z", appName: "Zoom",
            directory: "/tmp/omw-json-test", durationSeconds: 60,
            transcript: nil, summary: nil, createdAt: "2026-08-01T10:00:00Z",
            title: "Q3 Planning", attendees: ["Alice", "Bob"]
        ))
        try store.setSpeakerNames(id: id, ["Speaker 1": "Alice"])
        let got = try store.get(id: id)
        #expect(got?.title == "Q3 Planning")
        #expect(got?.attendees == ["Alice", "Bob"])
        #expect(got?.speakerNames == ["Speaker 1": "Alice"])
        // Title is FTS-indexed.
        #expect(try store.search("Planning", limit: 10).count == 1)
    }

    @Test func setSummaryUpdatesOnlyTheSummary() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Zoom")
        try store.setTranscriptAndSummary(id: id, transcript: "**You:**\nhi", summary: "old")
        try store.setSummary(id: id, "## Summary\nedited by hand")
        let got = try store.get(id: id)
        #expect(got?.summary == "## Summary\nedited by hand")
        #expect(got?.transcript == "**You:**\nhi")
    }

    @Test func setSpeakerNamesNilClears() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Meet")
        try store.setSpeakerNames(id: id, ["Speaker 1": "Alice"])
        try store.setSpeakerNames(id: id, nil)
        #expect(try store.get(id: id)?.speakerNames == nil)
    }
}
