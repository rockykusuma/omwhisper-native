//
//  LegacyHistoryImporterTests.swift
//  omwhisper-nativeTests
//

import Foundation
import GRDB
import Testing
@testable import OmWhisper

struct LegacyHistoryImporterTests {
    /// Old Tauri app's schema (snake_case columns) — see history.rs `open_db()`.
    private func makeLegacyQueue(rows: [(text: String, createdAt: String)]) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE transcriptions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT NOT NULL,
                    duration_seconds REAL NOT NULL DEFAULT 0,
                    model_used TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    word_count INTEGER NOT NULL DEFAULT 0,
                    source TEXT NOT NULL DEFAULT 'raw',
                    raw_text TEXT,
                    polish_style TEXT
                )
                """)
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO transcriptions (text, duration_seconds, model_used, created_at, word_count, source) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [row.text, 1.5, "tiny.en", row.createdAt, 2, "raw"]
                )
            }
        }
        return dbQueue
    }

    /// File-backed variant for `importIfNeeded` tests, which reopen by path —
    /// an in-memory queue's `.path` can't be reopened from a second connection.
    private func makeLegacyFile(rows: [(text: String, createdAt: String)]) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).db").path
        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE transcriptions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT NOT NULL,
                    duration_seconds REAL NOT NULL DEFAULT 0,
                    model_used TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    word_count INTEGER NOT NULL DEFAULT 0,
                    source TEXT NOT NULL DEFAULT 'raw',
                    raw_text TEXT,
                    polish_style TEXT
                )
                """)
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO transcriptions (text, duration_seconds, model_used, created_at, word_count, source) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [row.text, 1.5, "tiny.en", row.createdAt, 2, "raw"]
                )
            }
        }
        return path
    }

    @Test func importEntriesCopiesRowsCorrectly() throws {
        let legacyQueue = try makeLegacyQueue(rows: [
            (text: "First legacy entry", createdAt: "2023-01-01T10:00:00Z"),
            (text: "Second legacy entry", createdAt: "2023-01-02T10:00:00Z"),
        ])
        let store = try HistoryStore(DatabaseQueue())

        try LegacyHistoryImporter.importEntries(from: legacyQueue, into: store)

        let imported = try store.fetchPage(offset: 0, limit: 100)
        #expect(imported.count == 2)
        #expect(imported.map(\.text).sorted() == ["First legacy entry", "Second legacy entry"])
        #expect(imported.allSatisfy { $0.modelUsed == "tiny.en" && $0.wordCount == 2 })
    }

    @Test func importIfNeededRespectsFlagOnSecondRun() throws {
        let legacyPath = try makeLegacyFile(rows: [(text: "Once only", createdAt: "2023-01-01T10:00:00Z")])
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        let store = try HistoryStore(DatabaseQueue())
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        LegacyHistoryImporter.importIfNeeded(into: store, legacyPath: legacyPath, defaults: defaults)
        LegacyHistoryImporter.importIfNeeded(into: store, legacyPath: legacyPath, defaults: defaults)

        let imported = try store.fetchPage(offset: 0, limit: 100)
        #expect(imported.count == 1)
        #expect(defaults.bool(forKey: SettingsKeys.hasImportedLegacyHistory))
    }

    @Test func importIfNeededHandlesMissingDatabase() throws {
        let store = try HistoryStore(DatabaseQueue())
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        LegacyHistoryImporter.importIfNeeded(into: store, legacyPath: "/nonexistent/path/history.db", defaults: defaults)

        #expect(try store.fetchPage(offset: 0, limit: 100).isEmpty)
        #expect(defaults.bool(forKey: SettingsKeys.hasImportedLegacyHistory))
    }

    @Test func importIfNeededHandlesMalformedDatabase() throws {
        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("malformed-\(UUID().uuidString).db").path
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let store = try HistoryStore(DatabaseQueue())
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        LegacyHistoryImporter.importIfNeeded(into: store, legacyPath: tmpPath, defaults: defaults)

        #expect(try store.fetchPage(offset: 0, limit: 100).isEmpty)
        #expect(defaults.bool(forKey: SettingsKeys.hasImportedLegacyHistory))
    }
}
