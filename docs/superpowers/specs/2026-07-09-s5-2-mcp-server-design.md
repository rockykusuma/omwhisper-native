# Design: S5.2 — MCP Server

> Written 2026-07-09. Brainstormed via `superpowers:brainstorming`. Second and
> final sub-project implementing "S5 — Memory surfacing + MCP" from
> `docs/SMRITI_INTEGRATION_PLAN.md`, built on top of S5.1's chronicle store.
> This is the piece that satisfies S5's actual exit criterion: "what was I
> working on before lunch?" answerable from Claude Desktop.

## Goal

A stdio JSON-RPC MCP server, launched by Claude Desktop as a subprocess of
the OmWhisper binary itself (`OmWhisper --mcp`), exposing read-only tools
over captured memory snapshots, chronicles, and dictation history. Gated by
a new, off-by-default "Allow MCP access" toggle in Settings, with a
copy-paste-ready Claude Desktop config snippet shown right there.

## Reference: smriti's implementation

`MCPServer.swift` (already read in full earlier this session) — minimal
stdio JSON-RPC 2.0 server, newline-delimited: `initialize`/`ping`/
`tools/list`/`tools/call` methods, 5 tools (`search_memory`,
`get_recent_activity`, `get_snapshot`, `get_chronicle`, `list_chronicles`),
diagnostics to stderr, JSON-RPC frames to stdout only. No LLM in the
server itself — Claude does the thinking, the server is pure data access.
Launched via smriti's own `smriti mcp` CLI subcommand (smriti is
architected as a CLI tool with subcommands from the start).

**Not directly portable as architecture**: OmWhisper-native is a GUI
menu-bar app (`@main struct OmWhisperApp: App`), not a CLI tool — there is
no subcommand dispatch today. The port map's own note ("Launched via
`OmWhisper.app/Contents/MacOS/omwhisper --mcp` or a bundled helper")
anticipated this; the *tool set and JSON-RPC plumbing* port near-verbatim,
the *launch mechanism* is new.

## Architecture

### Entry point restructure

`omwhisper-native/OmWhisperApp.swift` loses its `@main` attribute. A new
`omwhisper-native/main.swift` becomes the target's actual entry point:

```swift
import Foundation

if CommandLine.arguments.contains("--mcp") {
    MCPLauncher.run()
} else {
    OmWhisperApp.main()
}
```

`App.main()` is a plain static function from the `App` protocol extension
(that's what `@main` synthesizes a call to) — calling it manually from
`main.swift` is the standard, well-established way to branch before
SwiftUI's lifecycle takes over. When `--mcp` is present, the normal GUI
path (`AppState()`, hotkeys, `NSStatusItem`, Sparkle) never runs at all —
`MCPLauncher.run()` is a completely separate, headless code path.

### MCPLauncher

New `omwhisper-native/MCP/MCPLauncher.swift`:

```swift
enum MCPLauncher {
    static func run() -> Never {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.mcpAccessEnabled) else {
            FileHandle.standardError.write(Data(
                "OmWhisper MCP access is disabled. Enable it in OmWhisper → Settings → MCP.\n".utf8))
            exit(1)
        }
        let appSupportDir = AppSupportDirectory.resolve()
        let historyStore = try? appSupportDir.map { try HistoryStore.open(atPath: $0.appendingPathComponent("history.db").path) }
        let memoryStore = try? appSupportDir.map { try MemoryStore.open(atPath: $0.appendingPathComponent("memory.db").path) }
        MCPServer(historyStore: historyStore ?? nil, memoryStore: memoryStore ?? nil).run()
        exit(0)
    }
}
```

`AppSupportDirectory.resolve() -> URL?` is a small new shared helper
(`omwhisper-native/AppSupportDirectory.swift`) factoring out the
app-support-path computation that currently lives inline in
`AppState.init()` — `AppState.init()` is refactored to call it too, rather
than duplicating the `FileManager` lookup + `createDirectory` calls in two
places. This is the one small refactor of existing code this sub-project
needs, and it's a straight extraction with no behavior change (confirmed by
running the full suite unchanged immediately after the extraction, before
any MCP code is added).

The `--mcp` process opens the *same* SQLite files the running GUI app uses
(same bundle ID, same Application Support path) — multiple processes
reading/writing the same SQLite file concurrently is a well-supported,
already-relied-upon pattern in this project (S1's live verification
directly `sqlite3`-inspected `memory.db` while the app was running with no
issues).

### MemoryStore additions

Two new read-only methods needed for the tools that don't already have a
matching `MemoryStore` method:

```swift
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
```

(`fetchPage`/`search`/`getChronicle`/`listChronicles` already exist from
S5.1; `HistoryStore.search(_:)` already exists from M2.)

### MCPServer

New `omwhisper-native/MCP/MCPServer.swift`, ported from smriti's structure
with field-name and store-method adaptations (GRDB records instead of raw
SQLite3 row reads):

```swift
final class MCPServer {
    private let historyStore: HistoryStore?
    private let memoryStore: MemoryStore?
    private let protocolVersion = "2024-11-05"

    init(historyStore: HistoryStore?, memoryStore: MemoryStore?) {
        self.historyStore = historyStore
        self.memoryStore = memoryStore
    }

    func run() {
        FileHandle.standardError.write(Data("omwhisper mcp: ready (stdio)\n".utf8))
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { send(errorId: NSNull(), code: -32700, message: "parse error"); continue }
            handle(msg)
        }
    }

    private func handle(_ msg: [String: Any]) {
        // identical shape to smriti: initialize / ping / tools/list / tools/call dispatch
    }

    struct ToolError: Error { let message: String }

    func callTool(name: String, args: [String: Any]) throws -> String {
        switch name {
        case "search_memory": ...          // memoryStore.search(query, limit:)
        case "get_recent_activity": ...    // memoryStore.recent(minutes:limit:)
        case "get_snapshot": ...           // memoryStore.getSnapshot(id:)
        case "get_chronicle": ...          // memoryStore.getChronicle(day:)
        case "list_chronicles": ...        // memoryStore.listChronicles(limit:)
        case "search_transcriptions": ...  // historyStore.search(query).prefix(limit)
        default: throw ToolError(message: "unknown tool: \(name)")
        }
    }
    // render/emit/send plumbing ported near-verbatim from smriti
}
```

Tool set (six, one more than smriti — `search_transcriptions` is this
project's own dictation history, which smriti has no equivalent of):

| Tool | Backing call | Notes |
|---|---|---|
| `search_memory(query, limit≤50)` | `memoryStore.search` | FTS5 over captured snapshots |
| `get_recent_activity(minutes≤10080, limit≤50)` | `memoryStore.recent` | last N minutes, newest first |
| `get_snapshot(id)` | `memoryStore.getSnapshot` | full content by id |
| `get_chronicle(day)` | `memoryStore.getChronicle` | one day's written summary |
| `list_chronicles()` | `memoryStore.listChronicles` | which days have summaries |
| `search_transcriptions(query, limit≤50)` | `historyStore.search` | dictation history, not screen capture |

Every tool that needs its backing store and finds it `nil` (open failed, or
the feature was simply never enabled so the file doesn't exist yet) returns
a clear text message ("Memory is not available.") rather than crashing —
same "DB failed to open → no-op, not a crash" principle this project uses
everywhere else, just surfaced as tool output instead of a UI toast since
there's no UI in this process.

### Settings toggle + config helper

`AppState` gains `mcpAccessEnabled: Bool` (same `access(keyPath:)`/
`withMutation(keyPath:)` computed-over-`UserDefaults` pattern as every other
setting, default `false`). Unlike `memoryEnabled`/`meetingsEnabled`/etc.
this wires no in-process collaborator — its only effect is being read fresh
by a *future* `--mcp` subprocess invocation, not anything this process does
itself.

New `Tab("MCP", systemImage: "point.3.connected.trianglepath.dotted")` in
`SettingsView`, between Memory and About. `UI/MCPSettingsView.swift`:
toggle, and — only when the toggle is on — a read-only text block showing
the exact JSON Claude Desktop needs, built from `Bundle.main.executablePath`:

```json
{
  "mcpServers": {
    "omwhisper": {
      "command": "<Bundle.main.executablePath>",
      "args": ["--mcp"]
    }
  }
}
```

with a "Copy Config" button (`NSPasteboard`, same pattern as `HistoryRow`'s
existing Copy button) and one line noting where Claude Desktop's config
file lives (`~/Library/Application Support/Claude/claude_desktop_config.json`).

## Global Constraints

- Off by default: `mcpAccessEnabled` defaults to `false`. `MCPLauncher.run()`
  checks it *before* opening any store or starting the JSON-RPC loop —
  refuses immediately (stderr message, `exit(1)`) rather than serving with
  the toggle off.
- Read-only: no tool writes, deletes, or mutates anything. Matches smriti
  and keeps the MCP surface strictly additive/safe.
- No new database, no new data — this sub-project only adds a read path
  over data S1/S5.1/M2 already capture and store.
- The `--mcp` subprocess never instantiates `AppState` — no hotkeys, no
  `NSStatusItem`, no Sparkle, no audio. It only opens `HistoryStore`/
  `MemoryStore` directly and runs the server loop.
- Revoking access (toggling off) takes effect on the MCP subprocess's next
  launch, not instantly for an already-running session — Claude Desktop
  owns the subprocess lifecycle, this app has no channel to signal a
  running `--mcp` process. Worth noting in the UI copy, not solving with
  new IPC.
- `AppSupportDirectory.resolve()` extraction must not change `AppState.init()`'s
  existing behavior — verified by the full test suite passing unchanged
  immediately after the extraction, before any new MCP code is added.

## Error Handling & Permissions

- Toggle off → clear stderr message + `exit(1)`, no store opened at all.
- Store open failure (same causes as the GUI path: disk issue, corrupt DB)
  → that store is `nil`, its tools return "Memory is not available."/
  "History is not available." text rather than crashing; the *other* store
  (if it opened fine) keeps working independently — mirrors `AppState.init()`'s
  existing independent-open-failure handling for `historyStore`/`memoryStore`.
- Malformed JSON-RPC input → `-32700 parse error` response, loop continues
  (doesn't exit on one bad line).
- Unknown tool name → `ToolError`, surfaced as an `isError: true` tool
  result, not a crash.

## Testing

`callTool(name:args:)` is directly unit-testable without going through the
stdio loop (construct an in-memory `MemoryStore`/`HistoryStore`, seed known
rows, call `callTool` directly, assert on the returned string) — this is
where the real logic lives (argument clamping, routing, rendering).
`MemoryStore.recent(minutes:limit:)`/`getSnapshot(id:)` get direct GRDB
round-trip tests, same style as existing `MemoryStoreTests`. The JSON-RPC
wire protocol itself (`handle`/`send`/`emit`, `readLine`-driven stdio loop)
is not cleanly unit-testable in-process (writes directly to
`FileHandle.standardOutput`) — verified live instead: piping a raw
`initialize`/`tools/list`/`tools/call` JSON-RPC sequence into
`OmWhisper --mcp` via shell and reading stdout, plus an actual Claude
Desktop config pointed at the built app for one real end-to-end "what was I
working on" query.

**Exit criteria**: `OmWhisper --mcp` responds correctly to a manual stdio
JSON-RPC session (`initialize`, `tools/list`, `tools/call` for each of the
six tools); Claude Desktop, configured via the Settings-provided snippet,
answers "what was I working on before lunch?" using real captured data;
toggling "Allow MCP access" off and relaunching the subprocess causes it to
refuse to start.
