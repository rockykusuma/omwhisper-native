//
//  MemorySelfTest.swift
//  OmWhisper
//
//  Debug-only diagnostic: captures the current frontmost window, writes it
//  to a throwaway in-memory store, and confirms FTS5 search actually finds
//  it back -- covers the "FTS search works" exit criterion without
//  requiring a full day of live capture to observe it.
//

#if DEBUG
import Foundation
import GRDB

enum MemorySelfTest {
    static func run() -> String {
        guard let snapshot = WindowSnapshotReader.captureFrontmost() else {
            return "FAILED: no frontmost window captured (excluded app, or nothing on screen)"
        }
        guard let store = try? MemoryStore(DatabaseQueue()) else {
            return "FAILED: could not open an in-memory MemoryStore"
        }
        do {
            try store.upsert(
                appName: snapshot.appName, bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle,
                content: snapshot.content, url: snapshot.url ?? ""
            )
        } catch {
            return "FAILED: upsert threw \(error)"
        }
        let probe = snapshot.content.split(separator: " ").first(where: { $0.count > 3 }).map(String.init) ?? snapshot.content
        guard let results = try? store.search(probe, limit: 5), !results.isEmpty else {
            return "FAILED: search(\"\(probe)\") found nothing after a successful upsert"
        }
        return """
            OK ✓
            app=\(snapshot.appName) bundleID=\(snapshot.bundleID) url=\(snapshot.url ?? "(none)")
            content length=\(snapshot.content.count)
            search probe="\(probe)" found \(results.count) result(s)
            """
    }
}
#endif
