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
    static func resolve() -> URL? {
        let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("com.omwhisper.mac", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
