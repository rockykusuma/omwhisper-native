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

nonisolated struct HomeStats: Equatable {
    let wordsToday: Int
    let durationTodaySeconds: Double
    let streakDays: Int
    /// Oldest to newest (index 0 = 6 days ago, index 6 = today); 0 for any
    /// day with no dictations.
    let last7DaysWordCounts: [Int]

    var speakingPaceWPM: Int {
        guard durationTodaySeconds > 0 else { return 0 }
        return Int((Double(wordsToday) / (durationTodaySeconds / 60)).rounded())
    }

    /// Typing time at 45wpm minus actual dictation time, clamped to >= 0 --
    /// dictating slower than you'd type is a real (if rare) outcome and
    /// shouldn't show as negative "time saved."
    var minutesSavedVsTyping: Int {
        let typingMinutes = Double(wordsToday) / 45.0
        let dictationMinutes = durationTodaySeconds / 60.0
        return max(0, Int((typingMinutes - dictationMinutes).rounded()))
    }
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

    /// Backs the hub's Home dashboard. `streakDays`' algorithm is a direct
    /// port of the old Tauri app's get_stats_summary (omwhisper/src-tauri/src/
    /// history.rs) -- consecutive distinct days including today, walking
    /// backward, stopping at the first gap. "Words today"/"time saved"/
    /// "speaking pace" are new for this dashboard (the old app never computed
    /// them), derived from the real wordCount/durationSeconds columns.
    func homeStats() throws -> HomeStats {
        try dbQueue.read { db in
            let todayRow = try Row.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(wordCount), 0) AS words, COALESCE(SUM(durationSeconds), 0) AS duration
                FROM transcriptions WHERE DATE(createdAt) = DATE('now')
                """
            )
            let wordsToday: Int = todayRow?["words"] ?? 0
            let durationToday: Double = todayRow?["duration"] ?? 0

            let dayRows = try Row.fetchAll(
                db,
                sql: "SELECT DISTINCT DATE(createdAt) AS day FROM transcriptions ORDER BY day DESC"
            )
            let dayStrings: [String] = dayRows.compactMap { $0["day"] }
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            // SQLite DATE(createdAt) / DATE('now') both extract the UTC day (as do
            // wordsToday and last7). Compare the streak in UTC too, or the loop breaks
            // whenever the local day differs from the UTC day (early morning in UTC+
            // zones) and streak reads 0. Keeps all of homeStats on one clock.
            let utc = TimeZone(identifier: "UTC") ?? .current
            dayFormatter.timeZone = utc
            var calendar = Calendar.current
            calendar.timeZone = utc

            var streak = 0
            var expected = Date()
            for dayString in dayStrings {
                guard let day = dayFormatter.date(from: dayString) else { break }
                if calendar.isDate(day, inSameDayAs: expected) {
                    streak += 1
                    expected = calendar.date(byAdding: .day, value: -1, to: expected) ?? expected
                } else {
                    break
                }
            }

            var last7: [Int] = []
            for offset in stride(from: 6, through: 0, by: -1) {
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(wordCount), 0) AS words FROM transcriptions WHERE DATE(createdAt) = DATE('now', ?)",
                    arguments: ["-\(offset) days"]
                )
                last7.append(row?["words"] ?? 0)
            }

            return HomeStats(wordsToday: wordsToday, durationTodaySeconds: durationToday, streakDays: streak, last7DaysWordCounts: last7)
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
