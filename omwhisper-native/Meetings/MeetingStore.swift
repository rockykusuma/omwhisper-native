//
//  MeetingStore.swift
//  OmWhisper
//
//  Separate GRDB database (meetings.db) for recorded-meeting metadata + on-device
//  transcript/summary. Distinct from history.db/memory.db -- recorded calls are
//  their own sensitivity class, wiped independently. Mirrors MemoryStore's shape
//  (DatabaseQueue, DatabaseMigrator, FTS5 via synchronize(withTable:)).
//
//  nonisolated: GRDB I/O has no MainActor affinity, matching MemoryStore.
//

import Foundation
import GRDB

nonisolated struct Meeting: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "meetings"
    var id: Int64?
    var startedAt: String
    var appName: String
    var directory: String
    var durationSeconds: Double
    var transcript: String?
    var summary: String?
    var createdAt: String
    // v2 (SP1 meeting identity). All optional with nil defaults so v1 rows and
    // existing call sites are untouched. attendees/speakerNames are stored as
    // JSON TEXT (GRDB encodes Codable collection properties as JSON).
    var title: String? = nil
    var attendees: [String]? = nil
    var speakerNames: [String: String]? = nil

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

nonisolated enum MeetingStoreError: Error, LocalizedError {
    case notFound
    var errorDescription: String? { "That meeting could not be found." }
}

nonisolated final class MeetingStore: Sendable {
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createMeetings") { db in
            try db.create(table: Meeting.databaseTableName) { t in
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
                t.synchronize(withTable: Meeting.databaseTableName)
                t.column("transcript")
                t.column("summary")
                t.column("appName")
            }
        }
        migrator.registerMigration("meetingIdentity") { db in
            try db.alter(table: Meeting.databaseTableName) { t in
                t.add(column: "title", .text)
                t.add(column: "attendees", .text)
                t.add(column: "speakerNames", .text)
            }
            // Recreate the FTS mirror to index title. synchronize() installed
            // triggers on `meetings` whose bodies reference meetings_fts; their
            // exact names are GRDB-internal, so find them via sqlite_master.
            let triggers = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'trigger' AND sql LIKE '%meetings_fts%'
                """)
            for name in triggers { try db.execute(sql: "DROP TRIGGER \"\(name)\"") }
            try db.drop(table: "meetings_fts")
            try db.create(virtualTable: "meetings_fts", using: FTS5()) { t in
                t.synchronize(withTable: Meeting.databaseTableName)
                t.column("transcript")
                t.column("summary")
                t.column("appName")
                t.column("title")
            }
        }
        try migrator.migrate(dbQueue)
    }

    static func open(atPath path: String) throws -> MeetingStore {
        try MeetingStore(DatabaseQueue(path: path))
    }

    func insert(_ meeting: Meeting) throws -> Int64 {
        try dbQueue.write { db in
            var m = meeting
            try m.insert(db)
            return m.id ?? 0
        }
    }

    func get(id: Int64) throws -> Meeting? {
        try dbQueue.read { db in try Meeting.fetchOne(db, key: id) }
    }

    func setTranscriptAndSummary(id: Int64, transcript: String?, summary: String?) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.transcript = transcript
            m.summary = summary
            try m.update(db)
        }
    }

    /// Summary only — the user editing their notes must never touch the
    /// transcript, which is the record of what was actually said.
    func setSummary(id: Int64, _ summary: String?) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.summary = summary
            try m.update(db)
        }
    }

    /// Replace the whole raw-label → display-name mapping (nil clears it).
    /// Re-transcribing produces fresh, unstable diarization labels, so callers
    /// reset this rather than trying to migrate names across runs.
    func setSpeakerNames(id: Int64, _ names: [String: String]?) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.speakerNames = names
            try m.update(db)
        }
    }

    /// Newest first; `id` tiebreaker for same-second inserts (ISO8601 whole-second
    /// precision), matching MemoryStore's fetchPage ordering fix.
    func fetchPage(offset: Int, limit: Int) throws -> [Meeting] {
        try dbQueue.read { db in
            try Meeting
                .order(Column("startedAt").desc, Column("id").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func search(_ query: String, limit: Int = 50) throws -> [Meeting] {
        let terms = query.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " OR ")
        guard !terms.isEmpty else { return [] }
        return try dbQueue.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT meetings.* FROM meetings
                JOIN meetings_fts ON meetings_fts.rowid = meetings.id
                WHERE meetings_fts MATCH ?
                ORDER BY meetings.startedAt DESC, meetings.id DESC
                LIMIT ?
                """, arguments: [terms, limit])
        }
    }

    func delete(id: Int64) throws {
        let directory = try dbQueue.read { db in try Meeting.fetchOne(db, key: id)?.directory }
        _ = try dbQueue.write { db in try Meeting.deleteOne(db, key: id) }
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
    }

    func deleteAll() throws {
        let directories = try dbQueue.read { db in try Meeting.fetchAll(db).map(\.directory) }
        _ = try dbQueue.write { db in try Meeting.deleteAll(db) }
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
    }

    func count() throws -> Int {
        try dbQueue.read { db in try Meeting.fetchCount(db) }
    }
}
