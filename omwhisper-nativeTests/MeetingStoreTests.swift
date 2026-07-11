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
}
