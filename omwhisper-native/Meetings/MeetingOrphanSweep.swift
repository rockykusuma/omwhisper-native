//
//  MeetingOrphanSweep.swift
//  OmWhisper
//
//  Deletes meeting directories that no database row points at.
//
//  A meetings row is inserted only when recording STOPS, so a crash or a
//  force-quit mid-recording has always left audio on disk with nothing
//  referencing it -- invisible, un-deletable through the UI, and growing.
//  Pre-roll recording makes that more frequent, since a directory now exists
//  before consent is even asked for.
//
//  Runs once at launch, before any recorder can have started, so it cannot
//  race a live recording.
//

import Foundation
import os

nonisolated private let sweepLog = Logger(subsystem: "com.omwhisper.mac", category: "MeetingOrphanSweep")

nonisolated enum MeetingOrphanSweep {
    /// Pure: directories on disk that no row claims.
    static func orphans(onDisk: [String], known: [String]) -> [String] {
        let claimed = Set(known)
        return onDisk.filter { !claimed.contains($0) }
    }

    /// `root` is the Application Support "meetings" directory. Silent when
    /// there is nothing to do; logs a count when it deletes, because audio
    /// disappearing should be attributable.
    static func run(store: MeetingStore, root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        let onDisk = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.path)
        guard let known = try? store.directories() else { return }

        let stale = orphans(onDisk: onDisk, known: known)
        guard !stale.isEmpty else { return }
        for path in stale { try? fm.removeItem(atPath: path) }
        // Count only, never a path -- a meeting directory is named after the
        // app. `.public` because a redacted count says nothing.
        sweepLog.notice("removed \(stale.count, privacy: .public) orphaned meeting directories")
    }
}
