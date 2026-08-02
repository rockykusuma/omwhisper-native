//
//  MCPLauncher.swift
//  OmWhisper
//
//  Entry point for `OmWhisper --mcp` (see main.swift). Deliberately never
//  touches AppState -- no hotkeys, no NSStatusItem, no Sparkle, no audio.
//  Opens HistoryStore/MemoryStore directly and runs the JSON-RPC loop.
//

import Foundation

enum MCPLauncher {
    static func run() -> Never {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.mcpAccessEnabled) else {
            FileHandle.standardError.write(Data(
                "OmWhisper MCP access is disabled. Enable it in OmWhisper → Settings → MCP.\n".utf8))
            exit(1)
        }

        let appSupportDir = AppSupportDirectory.resolve()
        var historyStore: HistoryStore?
        var memoryStore: MemoryStore?
        var meetingStore: MeetingStore?
        if let appSupportDir {
            historyStore = try? HistoryStore.open(atPath: appSupportDir.appendingPathComponent("history.db").path)
            memoryStore = try? MemoryStore.open(atPath: appSupportDir.appendingPathComponent("memory.db").path)
            meetingStore = try? MeetingStore.open(atPath: appSupportDir.appendingPathComponent("meetings.db").path)
        }

        // AppleEmbedder needs no app state and no downloaded asset, so the
        // subprocess gets the same semantic ranking the app has.
        MCPServer(historyStore: historyStore, memoryStore: memoryStore,
                  meetingStore: meetingStore, embedder: AppleEmbedder()).run()
        exit(0)
    }
}
