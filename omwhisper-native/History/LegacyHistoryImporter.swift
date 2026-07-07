//
//  LegacyHistoryImporter.swift
//  OmWhisper
//
//  One-time copy of the old Tauri app's history.db (com.omwhisper.app) into
//  this app's HistoryStore (com.omwhisper.mac). Read-only against the old DB —
//  never written to, never opened again after this runs once (see
//  hasImportedLegacyHistory in SettingsKeys).
//

import Foundation
import GRDB
import os

nonisolated private let importLog = Logger(subsystem: "com.omwhisper.mac", category: "LegacyHistoryImporter")

nonisolated enum LegacyHistoryImporter {
    static func legacyDatabasePath() -> String? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.omwhisper.app/history.db").path
    }

    /// Runs at most once (`hasImportedLegacyHistory` flag) — a missing or
    /// malformed old DB is logged and treated as "nothing to import", not
    /// retried on the next launch.
    static func importIfNeeded(
        into store: HistoryStore,
        legacyPath: String? = legacyDatabasePath(),
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: SettingsKeys.hasImportedLegacyHistory) else { return }
        defer { defaults.set(true, forKey: SettingsKeys.hasImportedLegacyHistory) }

        guard let legacyPath, FileManager.default.fileExists(atPath: legacyPath) else { return }

        do {
            var config = Configuration()
            config.readonly = true
            let legacyQueue = try DatabaseQueue(path: legacyPath, configuration: config)
            try importEntries(from: legacyQueue, into: store)
        } catch {
            importLog.error("import failed: \(error)")
        }
    }

    /// Old schema uses snake_case columns (history.rs); mapped by hand rather
    /// than a Codable strategy since it only runs once, for one table.
    static func importEntries(from legacyQueue: DatabaseQueue, into store: HistoryStore) throws {
        let entries = try legacyQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT text, duration_seconds, model_used, created_at, word_count, source, raw_text, polish_style
                FROM transcriptions
                """)
        }.map { row in
            TranscriptionEntry(
                id: nil,
                text: row["text"],
                durationSeconds: row["duration_seconds"],
                modelUsed: row["model_used"],
                createdAt: row["created_at"],
                wordCount: row["word_count"],
                source: (row["source"] as String?) ?? "raw",
                rawText: row["raw_text"],
                polishStyle: row["polish_style"]
            )
        }
        try store.importEntries(entries)
    }
}
