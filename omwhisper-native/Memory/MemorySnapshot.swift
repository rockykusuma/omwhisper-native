//
//  MemorySnapshot.swift
//  OmWhisper
//

import GRDB

nonisolated struct MemorySnapshot: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "snapshots"

    var id: Int64?
    var appName: String
    var bundleID: String
    var windowTitle: String
    var content: String
    var url: String
    var contentHash: String
    var capturedAt: String
    var lastSeenAt: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
