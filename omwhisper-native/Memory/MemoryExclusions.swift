//
//  MemoryExclusions.swift
//  OmWhisper
//
//  The user's own additions to the exclusion floor. ScreenContextReader's
//  hardcoded set (password managers, private browsing, .env) is a safety
//  floor that stays hardcoded and un-removable; this only ever ADDS.
//
//  Apps and title keywords are checked BEFORE the accessibility text walk,
//  so an excluded app's content is never read. Domains are checked after,
//  in MemoryCapture -- the URL isn't known until the window has been read.
//
//  nonisolated: consulted from WindowSnapshotReader's nonisolated capture path.
//

import Foundation

nonisolated struct MemoryExclusions: Equatable {
    /// Bundle IDs, matched exactly.
    var apps: Set<String> = []
    /// Matched case-insensitively as substrings of the window title -- the same
    /// mechanism as the built-in "Private Browsing" / "Incognito" entries.
    var titleKeywords: [String] = []

    static let none = MemoryExclusions()

    func excludes(bundleID: String, windowTitle: String) -> Bool {
        if apps.contains(bundleID) { return true }
        return titleKeywords.contains { keyword in
            let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank needle is contained in every string. Without this guard a
            // user who adds a row and clears it silently disables all capture.
            guard !needle.isEmpty else { return false }
            return windowTitle.localizedCaseInsensitiveContains(needle)
        }
    }
}
