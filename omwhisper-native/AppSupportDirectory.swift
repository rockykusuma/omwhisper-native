//
//  AppSupportDirectory.swift
//  OmWhisper
//
//  Shared by AppState.init() (the GUI path) and MCPLauncher.run() (the
//  --mcp path) so both resolve the exact same on-disk location for
//  history.db/memory.db without duplicating the FileManager lookup.
//

import Foundation

nonisolated enum AppSupportDirectory {
    /// Pure: the Application Support folder name for a bundle ID. Falls back to
    /// the production ID so a nil bundle ID (bare test runners) never invents a
    /// new location. Keyed to the LIVE bundle ID so the .dev Debug fork gets its
    /// own data root and can never open the installed app's databases (see
    /// docs/superpowers/specs/2026-08-01-dev-build-isolation-design.md).
    static func folderName(bundleID: String?) -> String {
        bundleID ?? "com.omwhisper.mac"
    }

    static func resolve() -> URL? {
        let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent(folderName(bundleID: Bundle.main.bundleIdentifier), isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
