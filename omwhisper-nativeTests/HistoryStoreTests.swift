//
//  HistoryStoreTests.swift
//  omwhisper-nativeTests
//
//  Ports the old Tauri app's history.rs test suite 1:1 (see history.rs
//  #[cfg(test)] mod tests), against the real HistoryStore/GRDB implementation
//  via an in-memory DatabaseQueue rather than parallel raw SQL.
//

import Foundation
import GRDB
import Testing
@testable import OmWhisper

struct HistoryStoreTests {
    private func makeStore() throws -> (HistoryStore, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let store = try HistoryStore(dbQueue)
        return (store, dbQueue)
    }

    /// Seeds a row with an explicit `createdAt`, bypassing `record()` — needed
    /// for ordering/cutoff tests where multiple entries must sort deterministically.
    private func seed(
        _ dbQueue: DatabaseQueue, text: String, createdAt: String,
        duration: Double = 1.0, modelUsed: String = "tiny.en"
    ) throws {
        var entry = TranscriptionEntry(
            id: nil, text: text, durationSeconds: duration, modelUsed: modelUsed,
            createdAt: createdAt, wordCount: text.split(whereSeparator: \.isWhitespace).count,
            source: "raw", rawText: nil, polishStyle: nil
        )
        try dbQueue.write { db in try entry.insert(db) }
    }

    // MARK: insert & count

    @Test func insertReturnsIncrementingIds() throws {
        let (store, _) = try makeStore()
        let first = try store.record(text: "Hello world", duration: 2.0, modelUsed: "tiny.en")
        let second = try store.record(text: "Second entry", duration: 3.0, modelUsed: "tiny.en")
        #expect(first.id == 1)
        #expect(second.id == 2)
    }

    @Test func wordCountComputedCorrectly() throws {
        let (store, _) = try makeStore()
        let entry = try store.record(text: "one two three four", duration: 1.0, modelUsed: "tiny.en")
        #expect(entry.wordCount == 4)
    }

    // MARK: pagination

    @Test func paginationReturnsCorrectSlice() throws {
        let (store, dbQueue) = try makeStore()
        for i in 1...5 {
            try seed(dbQueue, text: "Entry \(i)", createdAt: "2024-01-0\(i)T10:00:00Z")
        }
        let page = try store.fetchPage(offset: 1, limit: 2)
        #expect(page.count == 2)
    }

    @Test func getAllReturnsNewestFirst() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "First", createdAt: "2024-01-01T10:00:00Z")
        try seed(dbQueue, text: "Second", createdAt: "2024-01-02T10:00:00Z")
        try seed(dbQueue, text: "Third", createdAt: "2024-01-03T10:00:00Z")
        let page = try store.fetchPage(offset: 0, limit: 100)
        #expect(page.map(\.text) == ["Third", "Second", "First"])
    }

    // MARK: search

    @Test func searchFindsMatchingEntry() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "Hello world from Swift", createdAt: "2024-01-01T10:00:00Z")
        try seed(dbQueue, text: "Unrelated text here", createdAt: "2024-01-02T10:00:00Z")
        let results = try store.search("Swift")
        #expect(results.count == 1)
        #expect(results[0].text.contains("Swift"))
    }

    @Test func searchNoMatchReturnsEmpty() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "Hello world", createdAt: "2024-01-01T10:00:00Z")
        #expect(try store.search("xyz_not_found").isEmpty)
    }

    @Test func searchIsCaseInsensitive() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "Hello WORLD", createdAt: "2024-01-01T10:00:00Z")
        #expect(try store.search("hello").count == 1)
    }

    // MARK: delete

    @Test func deleteRemovesCorrectRow() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "To delete", createdAt: "2024-01-01T10:00:00Z")
        try seed(dbQueue, text: "Keep me", createdAt: "2024-01-02T10:00:00Z")
        let toDelete = try store.fetchPage(offset: 0, limit: 100).first { $0.text == "To delete" }!
        try store.delete(id: toDelete.id!)
        let remaining = try store.fetchPage(offset: 0, limit: 100)
        #expect(remaining.count == 1)
        #expect(remaining[0].text == "Keep me")
    }

    @Test func clearRemovesAllRows() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "A", createdAt: "2024-01-01T10:00:00Z")
        try seed(dbQueue, text: "B", createdAt: "2024-01-02T10:00:00Z")
        try store.deleteAll()
        #expect(try store.fetchPage(offset: 0, limit: 100).isEmpty)
    }

    // MARK: export

    @Test func exportJSONContainsText() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "Test transcription", createdAt: "2024-01-01T10:00:00Z", duration: 5.0)
        let json = try store.exportAll(format: .json)
        #expect(json.contains("Test transcription"))
        #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) is [Any])
    }

    @Test func exportTextFormatContainsText() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "First sentence", createdAt: "2024-01-01T10:00:00Z")
        try seed(dbQueue, text: "Second sentence", createdAt: "2024-01-02T10:00:00Z")
        let text = try store.exportAll(format: .text)
        #expect(text.contains("First sentence"))
        #expect(text.contains("Second sentence"))
    }

    @Test func exportMarkdownContainsHeaders() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "Hello world test", createdAt: "2024-01-01T10:00:00Z", duration: 2.5, modelUsed: "tiny.en")
        let md = try store.exportAll(format: .markdown)
        #expect(md.hasPrefix("# OmWhisper"))
        #expect(md.contains("##"))
        #expect(md.contains("**Model:**"))
    }

    // MARK: storage info

    @Test func storageInfoReportsCountAndNonZeroBytes() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "A", createdAt: "2024-01-01T10:00:00Z")
        try seed(dbQueue, text: "B", createdAt: "2024-01-02T10:00:00Z")
        let info = try store.storageInfo()
        #expect(info.count == 2)
        #expect(info.bytes > 0)
    }

    // MARK: deleteOlderThan

    @Test func deleteOlderThanRemovesOnlyOldRows() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, text: "Ancient", createdAt: "2000-01-01T00:00:00Z")
        _ = try store.record(text: "Recent", duration: 1.0, modelUsed: "tiny.en")
        let deleted = try store.deleteOlderThan(days: 1)
        #expect(deleted == 1)
        let remaining = try store.fetchPage(offset: 0, limit: 100)
        #expect(remaining.count == 1)
        #expect(remaining[0].text == "Recent")
    }

    // MARK: importEntries (used by LegacyHistoryImporter)

    @Test func importEntriesInsertsRowsWithFreshIds() throws {
        let (store, _) = try makeStore()
        let incoming = [
            TranscriptionEntry(
                id: 999, text: "Imported one", durationSeconds: 1.5, modelUsed: "tiny.en",
                createdAt: "2023-01-01T00:00:00Z", wordCount: 2, source: "raw", rawText: nil, polishStyle: nil
            ),
            TranscriptionEntry(
                id: 1000, text: "Imported two", durationSeconds: 2.5, modelUsed: "tiny.en",
                createdAt: "2023-01-02T00:00:00Z", wordCount: 2, source: "raw", rawText: nil, polishStyle: nil
            ),
        ]
        try store.importEntries(incoming)
        let all = try store.fetchPage(offset: 0, limit: 100)
        #expect(all.count == 2)
        #expect(all.map(\.text).sorted() == ["Imported one", "Imported two"])
        #expect(all.allSatisfy { $0.id != 999 && $0.id != 1000 })
    }
}
