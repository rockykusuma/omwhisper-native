//
//  MemoryStore.swift
//  OmWhisper
//
//  Separate GRDB database from HistoryStore (own file, own DatabaseQueue) --
//  memory (background screen capture) and dictation history are
//  differently-sensitive data with different default-on/off states; a user
//  must be able to wipe one without touching the other.
//
//  Schema ported from smriti's Store.swift (raw SQLite3 there; this is a
//  from-scratch GRDB schema, not a port of that C API code):
//  snapshots(id, appName, bundleID, windowTitle, content, url, contentHash,
//  capturedAt, lastSeenAt), UNIQUE(bundleID, windowTitle, contentHash) dedup
//  index, an FTS5 virtual table kept in sync via GRDB's synchronize(withTable:)
//  (confirmed real against the pinned GRDB 7.11.1 source -- auto-generates
//  the AFTER INSERT/DELETE/UPDATE triggers, no hand-written trigger SQL).
//
//  nonisolated: GRDB I/O has no MainActor affinity, matching HistoryStore's
//  own concurrency note.
//

import CryptoKit
import Foundation
import GRDB

nonisolated struct MemoryChronicle: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "chronicles"
    var id: String { day }
    var day: String
    var summary: String
    var snapshotCount: Int
    var createdAt: String
}

/// One ~1000-char chunk of a snapshot plus its embedding. Separate rows rather
/// than one vector per snapshot: a 6,350-char page collapsed to a single point
/// retrieves badly, and passages are what let the UI show which part matched.
nonisolated struct MemoryPassage: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "passages"
    var id: Int64?
    var snapshotId: Int64
    var ordinal: Int
    var text: String
    var vector: Data          // float16, see SemanticIndexing.encode

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

nonisolated final class MemoryStore: Sendable {
    /// internal, not private -- MemoryStoreTests reaches in to backdate a
    /// row directly, the only way to exercise prune()'s real deletion path
    /// without injecting a clock into the production upsert/prune API.
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createSnapshots") { db in
            try db.create(table: MemorySnapshot.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("appName", .text).notNull()
                t.column("bundleID", .text).notNull()
                t.column("windowTitle", .text).notNull()
                t.column("content", .text).notNull()
                t.column("url", .text).notNull().defaults(to: "")
                t.column("contentHash", .text).notNull()
                t.column("capturedAt", .text).notNull()
                t.column("lastSeenAt", .text).notNull()
            }
            try db.create(
                index: "idx_snapshots_dedup",
                on: MemorySnapshot.databaseTableName,
                columns: ["bundleID", "windowTitle", "contentHash"],
                unique: true
            )
            try db.create(virtualTable: "snapshots_fts", using: FTS5()) { t in
                t.synchronize(withTable: MemorySnapshot.databaseTableName)
                t.column("content")
                t.column("windowTitle")
                t.column("appName")
            }
        }
        migrator.registerMigration("createChronicles") { db in
            try db.create(table: MemoryChronicle.databaseTableName) { t in
                t.column("day", .text).notNull().primaryKey()
                t.column("summary", .text).notNull()
                t.column("snapshotCount", .integer).notNull()
                t.column("createdAt", .text).notNull()
            }
        }
        migrator.registerMigration("createPassages") { db in
            try db.create(table: MemoryPassage.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                // Cascade: prune() deletes snapshots directly, and an orphaned
                // vector index would grow forever.
                t.column("snapshotId", .integer).notNull()
                    .references(MemorySnapshot.databaseTableName, onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("vector", .blob).notNull()
            }
            try db.create(index: "passages_snapshot", on: MemoryPassage.databaseTableName,
                          columns: ["snapshotId"])
        }
        try migrator.migrate(dbQueue)
    }

    static func open(atPath path: String) throws -> MemoryStore {
        try MemoryStore(DatabaseQueue(path: path))
    }

    static func contentHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Pure decision: given the existing row matching this capture's dedup
    /// key (if any), what row should be written -- the same row with only
    /// lastSeenAt bumped (and url refreshed, since a page's URL can change
    /// while its title/content stay identical), or a brand new row.
    nonisolated static func upsertDecision(
        existing: MemorySnapshot?, appName: String, bundleID: String, windowTitle: String,
        content: String, url: String, contentHash: String, now: String
    ) -> MemorySnapshot {
        if var existing, existing.contentHash == contentHash {
            existing.lastSeenAt = now
            existing.url = url
            return existing
        }
        return MemorySnapshot(
            id: nil, appName: appName, bundleID: bundleID, windowTitle: windowTitle,
            content: content, url: url, contentHash: contentHash, capturedAt: now, lastSeenAt: now
        )
    }

    func upsert(appName: String, bundleID: String, windowTitle: String, content: String, url: String) throws {
        let hash = Self.contentHash(content)
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            let existing = try MemorySnapshot
                .filter(Column("bundleID") == bundleID
                    && Column("windowTitle") == windowTitle
                    && Column("contentHash") == hash)
                .fetchOne(db)
            var row = Self.upsertDecision(
                existing: existing, appName: appName, bundleID: bundleID, windowTitle: windowTitle,
                content: content, url: url, contentHash: hash, now: now
            )
            try row.save(db)
        }
    }

    // MARK: - Passages (semantic search)

    /// Replace every passage for a snapshot. Replace, not append: re-indexing
    /// after a content change must not leave the old vectors behind.
    func replacePassages(snapshotId: Int64, passages: [(text: String, vector: Data)]) throws {
        try dbQueue.write { db in
            try MemoryPassage.filter(Column("snapshotId") == snapshotId).deleteAll(db)
            for (i, p) in passages.enumerated() {
                var row = MemoryPassage(id: nil, snapshotId: snapshotId, ordinal: i,
                                        text: p.text, vector: p.vector)
                try row.insert(db)
            }
        }
    }

    /// Every vector, for the in-memory cosine scan. At ~40k passages this is a
    /// few tens of MB and a few million float ops -- an ANN index would be
    /// complexity for no measurable gain at this scale.
    func allPassageVectors() throws -> [(snapshotId: Int64, ordinal: Int, vector: Data, text: String)] {
        try dbQueue.read { db in
            try MemoryPassage.fetchAll(db).map {
                ($0.snapshotId, $0.ordinal, $0.vector, $0.text)
            }
        }
    }

    /// Backfill driver: snapshots with no passages yet, oldest first. This query
    /// IS the cursor, so an interrupted backfill simply resumes.
    func snapshotsMissingPassages(limit: Int) throws -> [MemorySnapshot] {
        try dbQueue.read { db in
            try MemorySnapshot.fetchAll(db, sql: """
                SELECT snapshots.* FROM snapshots
                LEFT JOIN passages ON passages.snapshotId = snapshots.id
                WHERE passages.id IS NULL
                ORDER BY snapshots.id ASC
                LIMIT ?
                """, arguments: [limit])
        }
    }

    /// Keyword and semantic ranked independently, then fused. `embedder == nil`,
    /// an unembeddable query, or an empty passage table all fall through to
    /// exactly today's keyword behaviour -- a user who never enables this must
    /// see no change.
    func hybridSearch(_ query: String, embedder: MemoryEmbedder?, limit: Int = 20) throws
        -> [(snapshot: MemorySnapshot, matchedPassage: String?)] {
        let keywordHits = try search(query, limit: limit)
        let keywordIDs = keywordHits.compactMap(\.id)

        guard let embedder, let qv = embedder.vector(query) else {
            return keywordHits.map { ($0, nil) }
        }

        // Best-scoring passage per snapshot.
        var best: [Int64: (score: Float, text: String)] = [:]
        for row in try allPassageVectors() {
            let score = SemanticIndexing.cosine(qv, SemanticIndexing.decode(row.vector))
            if score > (best[row.snapshotId]?.score ?? -1) {
                best[row.snapshotId] = (score, row.text)
            }
        }
        guard !best.isEmpty else { return keywordHits.map { ($0, nil) } }

        let semanticIDs = best.sorted { $0.value.score > $1.value.score }
            .prefix(limit).map(\.key)
        let fused = SemanticIndexing.fuse(keyword: keywordIDs, semantic: Array(semanticIDs))

        var byID = Dictionary(uniqueKeysWithValues: keywordHits.compactMap { s in s.id.map { ($0, s) } })
        let missing = fused.filter { byID[$0] == nil }
        if !missing.isEmpty {
            try dbQueue.read { db in
                for s in try MemorySnapshot.fetchAll(db, keys: missing) {
                    if let id = s.id { byID[id] = s }
                }
            }
        }
        return fused.prefix(limit).compactMap { id in
            byID[id].map { ($0, best[id]?.text) }
        }
    }

    func search(_ query: String, limit: Int = 20) throws -> [MemorySnapshot] {
        let terms = query.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " OR ")
        return try dbQueue.read { db in
            try MemorySnapshot.fetchAll(db, sql: """
                SELECT snapshots.* FROM snapshots
                JOIN snapshots_fts ON snapshots_fts.rowid = snapshots.id
                WHERE snapshots_fts MATCH ?
                ORDER BY rank LIMIT ?
                """, arguments: [terms, limit])
        }
    }

    func fetchPage(offset: Int, limit: Int) throws -> [MemorySnapshot] {
        // Secondary sort on id breaks ties deterministically -- lastSeenAt is
        // whole-second precision (ISO8601DateFormatter's default), so bursts
        // of captures within the same second would otherwise sort arbitrarily.
        try dbQueue.read { db in
            try MemorySnapshot
                .order(Column("lastSeenAt").desc, Column("id").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func recent(minutes: Int, limit: Int = 20) throws -> [MemorySnapshot] {
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(minutes) * 60))
        return try dbQueue.read { db in
            try MemorySnapshot
                .filter(Column("lastSeenAt") > cutoff)
                .order(Column("lastSeenAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func getSnapshot(id: Int64) throws -> MemorySnapshot? {
        try dbQueue.read { db in try MemorySnapshot.fetchOne(db, key: id) }
    }

    func delete(id: Int64) throws {
        try dbQueue.write { db in _ = try MemorySnapshot.deleteOne(db, key: id) }
    }

    func deleteAll() throws {
        try dbQueue.write { db in _ = try MemorySnapshot.deleteAll(db) }
    }

    func storageInfo() throws -> (count: Int, bytes: Int64) {
        try dbQueue.read { db in
            let count = try MemorySnapshot.fetchCount(db)
            let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return (count, pageCount * pageSize)
        }
    }

    func prune(olderThanDays days: Int) throws {
        guard days > 0 else { return }
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400))
        try dbQueue.write { db in
            _ = try MemorySnapshot.filter(Column("lastSeenAt") < cutoff).deleteAll(db)
        }
    }

    func upsertChronicle(day: String, summary: String, snapshotCount: Int) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let row = MemoryChronicle(day: day, summary: summary, snapshotCount: snapshotCount, createdAt: now)
        try dbQueue.write { db in try row.save(db) }
    }

    func getChronicle(day: String) throws -> MemoryChronicle? {
        try dbQueue.read { db in try MemoryChronicle.fetchOne(db, key: day) }
    }

    func listChronicles(limit: Int = 60) throws -> [MemoryChronicle] {
        try dbQueue.read { db in
            try MemoryChronicle
                .order(Column("day").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// `day` is a LOCAL calendar day (Chronicler.dayString). Timestamps are stored
    /// as UTC ISO8601 ("…Z"), so the comparison needs 'localtime' to convert them
    /// — without it a chronicle's day runs UTC-midnight to UTC-midnight, which for
    /// anyone not on UTC is neither of their days.
    func snapshotsForDay(_ day: String) throws -> [MemorySnapshot] {
        try dbQueue.read { db in
            try MemorySnapshot.fetchAll(db, sql: """
                SELECT * FROM snapshots
                WHERE date(lastSeenAt, 'localtime') = ? OR date(capturedAt, 'localtime') = ?
                ORDER BY lastSeenAt ASC
                """, arguments: [day, day])
        }
    }
}
