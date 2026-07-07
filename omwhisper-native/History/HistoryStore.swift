//
//  HistoryStore.swift
//  OmWhisper
//
//  GRDB-backed store for dictation history. Schema/semantics match the old
//  Tauri app's `transcriptions` table (src-tauri/src/history.rs) so
//  LegacyHistoryImporter can copy rows across unchanged.
//

import Foundation
import GRDB

nonisolated struct TranscriptionEntry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "transcriptions"

    var id: Int64?
    var text: String
    var durationSeconds: Double
    var modelUsed: String
    var createdAt: String   // ISO8601
    var wordCount: Int
    var source: String      // "raw" | "smart_dictation"
    var rawText: String?
    var polishStyle: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum ExportFormat {
    case text, markdown, json
}

// nonisolated: GRDB's DatabaseQueue.read/write are synchronous, blocking I/O —
// this collaborator has no UI affinity and must be callable from the
// background Task that runs import/cleanup (see AppState concurrency note
// in CLAUDE.md), same rationale as AudioCapture/AppleEngine.
nonisolated final class HistoryStore: Sendable {
    private let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createTranscriptions") { db in
            try db.create(table: TranscriptionEntry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("durationSeconds", .double).notNull().defaults(to: 0)
                t.column("modelUsed", .text).notNull().defaults(to: "")
                t.column("createdAt", .text).notNull()
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("source", .text).notNull().defaults(to: "raw")
                t.column("rawText", .text)
                t.column("polishStyle", .text)
            }
        }
        try migrator.migrate(dbQueue)
    }

    static func open(atPath path: String) throws -> HistoryStore {
        try HistoryStore(DatabaseQueue(path: path))
    }

    @discardableResult
    func record(text: String, duration: Double, modelUsed: String) throws -> TranscriptionEntry {
        var entry = TranscriptionEntry(
            id: nil,
            text: text,
            durationSeconds: duration,
            modelUsed: modelUsed,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            source: "raw",
            rawText: nil,
            polishStyle: nil
        )
        try dbQueue.write { db in try entry.insert(db) }
        return entry
    }

    /// Bulk-inserts entries carried over from another store (LegacyHistoryImporter),
    /// discarding their source ids so SQLite assigns fresh ones here.
    func importEntries(_ entries: [TranscriptionEntry]) throws {
        try dbQueue.write { db in
            for var entry in entries {
                entry.id = nil
                try entry.insert(db)
            }
        }
    }

    func fetchPage(offset: Int, limit: Int) throws -> [TranscriptionEntry] {
        try dbQueue.read { db in
            try TranscriptionEntry
                .order(Column("createdAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func search(_ query: String) throws -> [TranscriptionEntry] {
        try dbQueue.read { db in
            try TranscriptionEntry
                .filter(Column("text").like("%\(query)%"))
                .order(Column("createdAt").desc)
                .limit(100)
                .fetchAll(db)
        }
    }

    func delete(id: Int64) throws {
        try dbQueue.write { db in _ = try TranscriptionEntry.deleteOne(db, key: id) }
    }

    func deleteAll() throws {
        try dbQueue.write { db in _ = try TranscriptionEntry.deleteAll(db) }
    }

    @discardableResult
    func deleteOlderThan(days: Int) throws -> Int {
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86400))
        return try dbQueue.write { db in
            try TranscriptionEntry.filter(Column("createdAt") < cutoff).deleteAll(db)
        }
    }

    func storageInfo() throws -> (count: Int, bytes: Int64) {
        try dbQueue.read { db in
            let count = try TranscriptionEntry.fetchCount(db)
            let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return (count, pageCount * pageSize)
        }
    }

    func exportAll(format: ExportFormat) throws -> String {
        let entries = try dbQueue.read { db in
            try TranscriptionEntry.order(Column("createdAt").desc).fetchAll(db)
        }
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(entries), as: UTF8.self)
        case .markdown:
            var out = "# OmWhisper Transcription History\n\n"
            for e in entries {
                out += "## \(e.createdAt)\n\n"
                out += "**Model:** \(e.modelUsed) | **Words:** \(e.wordCount) | **Duration:** \(String(format: "%.1f", e.durationSeconds))s\n\n"
                out += e.text
                out += "\n\n---\n\n"
            }
            return out
        case .text:
            var out = ""
            for e in entries {
                out += "[\(e.createdAt)]\n\(e.text)\n\n"
            }
            return out
        }
    }
}
