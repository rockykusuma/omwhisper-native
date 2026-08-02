//
//  MCPServer.swift
//  OmWhisper
//
//  Minimal stdio MCP server (JSON-RPC 2.0, newline-delimited), ported from
//  smriti's MCPServer.swift (same author, MIT, read-only reference) with
//  GRDB-record field names instead of raw SQLite3 row reads, and one extra
//  tool (search_transcriptions) this app has that smriti doesn't.
//
//  No LLM here -- Claude does the thinking. stdout carries only JSON-RPC;
//  diagnostics go to stderr. Launched via MCPLauncher.run() (OmWhisper --mcp),
//  never via the normal GUI AppState path.
//

import Foundation

nonisolated final class MCPServer {
    private let historyStore: HistoryStore?
    private let memoryStore: MemoryStore?
    private let meetingStore: MeetingStore?
    /// nil means search_memory stays keyword-only, which is exactly the
    /// pre-semantic behaviour — hybridSearch degrades to search() for a nil
    /// embedder, so nothing here needs a fallback branch.
    private let embedder: MemoryEmbedder?
    private let protocolVersion = "2024-11-05"

    /// meetingStore and embedder default to nil so pre-SP3 call sites keep compiling.
    init(historyStore: HistoryStore?, memoryStore: MemoryStore?,
         meetingStore: MeetingStore? = nil, embedder: MemoryEmbedder? = nil) {
        self.historyStore = historyStore
        self.memoryStore = memoryStore
        self.meetingStore = meetingStore
        self.embedder = embedder
    }

    /// Blocking read-eval loop over stdin. Returns on EOF.
    func run() {
        FileHandle.standardError.write(Data("omwhisper mcp: ready (stdio)\n".utf8))
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard
                let data = line.data(using: .utf8),
                let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                send(errorId: NSNull(), code: -32700, message: "parse error")
                continue
            }
            handle(msg)
        }
    }

    // MARK: - Dispatch

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]

        guard let id else { return }

        switch method {
        case "initialize":
            send(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "omwhisper", "version": "1.0.0"],
            ])

        case "ping":
            send(id: id, result: [:])

        case "tools/list":
            send(id: id, result: ["tools": MCPServer.toolDefinitions])

        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try callTool(name: name, args: args)
                send(id: id, result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ])
            } catch let error as ToolError {
                send(id: id, result: [
                    "content": [["type": "text", "text": error.message]],
                    "isError": true,
                ])
            } catch {
                send(id: id, result: [
                    "content": [["type": "text", "text": "omwhisper error: \(error)"]],
                    "isError": true,
                ])
            }

        default:
            send(errorId: id, code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: - Tools

    struct ToolError: Error { let message: String }

    func callTool(name: String, args: [String: Any]) throws -> String {
        switch name {
        case "search_memory":
            guard let query = args["query"] as? String, !query.isEmpty else {
                throw ToolError(message: "search_memory requires a non-empty 'query' string")
            }
            guard let memoryStore else { return "Memory is not available." }
            let limit = clamp(args["limit"], default: 10, max: 50)
            // Same hybrid ranking the hub uses. An MCP client asking "what was
            // I working on before lunch?" is the case semantic search exists
            // for, and it was the one caller still doing exact-word matching.
            let hits = try memoryStore.hybridSearch(query, embedder: embedder, limit: limit)
            let rows = SemanticIndexing.diversified(hits, maxRun: 2, appName: { $0.snapshot.appName })
            return render(rows.map(\.snapshot), emptyMessage: "No snapshots match \"\(query)\".")

        case "get_recent_activity":
            guard let memoryStore else { return "Memory is not available." }
            let minutes = clamp(args["minutes"], default: 30, max: 60 * 24 * 7)
            let limit = clamp(args["limit"], default: 20, max: 50)
            let rows = try memoryStore.recent(minutes: minutes, limit: limit)
            return render(rows, emptyMessage: "No snapshots in the last \(minutes) minutes.")

        case "get_snapshot":
            guard let idValue = args["id"], let id = Int64("\(idValue)") else {
                throw ToolError(message: "get_snapshot requires an integer 'id'")
            }
            guard let memoryStore else { return "Memory is not available." }
            guard let row = try memoryStore.getSnapshot(id: id) else {
                throw ToolError(message: "No snapshot with id \(id).")
            }
            let urlLine = row.url.isEmpty ? "" : "url: \(row.url)\n"
            return """
                id: \(row.id ?? 0)
                app: \(row.appName) (\(row.bundleID))
                window: \(row.windowTitle)
                \(urlLine)first seen: \(row.capturedAt)
                last seen:  \(row.lastSeenAt)

                \(row.content)
                """

        case "get_chronicle":
            guard let day = args["day"] as? String, !day.isEmpty else {
                throw ToolError(message: "get_chronicle requires 'day' (YYYY-MM-DD)")
            }
            guard let memoryStore else { return "Memory is not available." }
            guard let chronicle = try memoryStore.getChronicle(day: day) else {
                throw ToolError(message: "No chronicle for \(day).")
            }
            return "Chronicle for \(chronicle.day) (\(chronicle.snapshotCount) snapshots, written \(chronicle.createdAt)):\n\n\(chronicle.summary)"

        case "list_chronicles":
            guard let memoryStore else { return "Memory is not available." }
            let all = try memoryStore.listChronicles()
            guard !all.isEmpty else { return "No chronicles stored yet." }
            return all.map {
                "\($0.day) — \($0.snapshotCount) snapshots, written \($0.createdAt)"
            }.joined(separator: "\n")

        case "search_transcriptions":
            guard let query = args["query"] as? String, !query.isEmpty else {
                throw ToolError(message: "search_transcriptions requires a non-empty 'query' string")
            }
            guard let historyStore else { return "History is not available." }
            let limit = clamp(args["limit"], default: 10, max: 50)
            let rows = Array(try historyStore.search(query).prefix(limit))
            return render(rows, emptyMessage: "No transcriptions match \"\(query)\".")

        case "search_meetings":
            guard let query = args["query"] as? String, !query.isEmpty else {
                throw ToolError(message: "search_meetings requires a non-empty 'query' string")
            }
            guard let meetingStore else { return "Meetings are not available." }
            let limit = clamp(args["limit"], default: 10, max: 50)
            let rows = try meetingStore.search(query, limit: limit)
            guard !rows.isEmpty else { return "No meetings match \"\(query)\"." }
            return rows.map(Self.meetingSummaryLine).joined(separator: "\n")

        case "get_meeting":
            guard let idValue = args["id"], let id = Int64("\(idValue)") else {
                throw ToolError(message: "get_meeting requires an integer 'id'")
            }
            guard let meetingStore else { return "Meetings are not available." }
            guard let meeting = try meetingStore.get(id: id) else {
                throw ToolError(message: "No meeting with id \(id).")
            }
            return Self.meetingDetail(meeting)

        default:
            throw ToolError(message: "unknown tool: \(name)")
        }
    }

    /// One line per meeting for search results — enough to choose one, then
    /// get_meeting(id) for the full text. Mirrors render()'s compact style.
    private static func meetingSummaryLine(_ m: Meeting) -> String {
        "id: \(m.id ?? 0) | \(m.startedAt) | \(m.title ?? m.appName) | \(Int(m.durationSeconds / 60))m"
    }

    /// Full detail. Speaker names are resolved (SP1) so a caller sees "Alice",
    /// not "Speaker 1" — the raw diarization labels are meaningless outside
    /// this app, and an assistant can't answer "what did Alice say" from them.
    private static func meetingDetail(_ m: Meeting) -> String {
        let attendees = (m.attendees ?? []).joined(separator: ", ")
        let transcript = MeetingDiarization.applySpeakerNames(
            m.transcript ?? "", names: m.speakerNames ?? [:])
        return """
            id: \(m.id ?? 0)
            title: \(m.title ?? m.appName)
            app: \(m.appName)
            started: \(m.startedAt)
            duration: \(Int(m.durationSeconds / 60))m
            \(attendees.isEmpty ? "" : "attendees: \(attendees)\n")
            \(m.summary.map { "SUMMARY\n\($0)\n" } ?? "")
            TRANSCRIPT
            \(transcript.isEmpty ? "(not transcribed)" : transcript)
            """
    }

    /// Compact listing: id + metadata + content preview.
    private func render(_ rows: [MemorySnapshot], emptyMessage: String) -> String {
        guard !rows.isEmpty else { return emptyMessage }
        return rows.map { row in
            let preview = row.content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(300)
            let location = row.url.isEmpty ? "" : " <\(row.url)>"
            return "#\(row.id ?? 0) [\(row.lastSeenAt)] \(row.appName) — \(row.windowTitle)\(location)\n\(preview)"
        }.joined(separator: "\n\n")
    }

    private func render(_ rows: [TranscriptionEntry], emptyMessage: String) -> String {
        guard !rows.isEmpty else { return emptyMessage }
        return rows.map { row in
            let preview = row.text
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(300)
            return "#\(row.id ?? 0) [\(row.createdAt)] \(row.wordCount) words\n\(preview)"
        }.joined(separator: "\n\n")
    }

    private func clamp(_ value: Any?, default def: Int, max: Int) -> Int {
        let n = (value as? Int) ?? (value as? Double).map(Int.init) ?? def
        return Swift.max(1, Swift.min(n, max))
    }

    // nonisolated(unsafe): immutable literal data, never mutated after init --
    // Swift 6 can't prove [String: Any]'s Sendability statically, but there's
    // no actual shared-mutable-state risk here.
    private nonisolated(unsafe) static let toolDefinitions: [[String: Any]] = [
        [
            "name": "search_meetings",
            "description": "Full-text search across recorded meetings (title, transcript, summary, app). Returns one line per meeting with its id — call get_meeting(id) for the full transcript and summary.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search terms (FTS5 match, terms are ORed)"],
                    "limit": ["type": "integer", "description": "Max results (default 10, max 50)"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "get_meeting",
            "description": "Full detail for one recorded meeting: title, date, duration, attendees, summary, and the speaker-labelled transcript with any renamed speakers applied.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "integer", "description": "Meeting id from search_meetings"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "search_memory",
            "description": "Full-text search across everything OmWhisper has captured from the screen (window text captured locally, when Memory is enabled). Returns matching snapshots with id, timestamp, app, window title, and a content preview. Use get_snapshot(id) for full text.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search terms (FTS5 match, terms are ORed)"],
                    "limit": ["type": "integer", "description": "Max results (default 10, max 50)"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "get_recent_activity",
            "description": "What was on the user's screen recently. Returns snapshots from the last N minutes, newest first, with id, timestamp, app, window title, and a content preview.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "description": "Look-back window in minutes (default 30)"],
                    "limit": ["type": "integer", "description": "Max results (default 20, max 50)"],
                ],
            ],
        ],
        [
            "name": "get_snapshot",
            "description": "Fetch the full captured text of a single snapshot by id (ids come from search_memory / get_recent_activity results).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "integer", "description": "Snapshot id"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "get_chronicle",
            "description": "Fetch the stored daily chronicle (a written summary of that day's captured screen activity) for a given local date. Use list_chronicles to see which days exist.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "day": ["type": "string", "description": "Local date, YYYY-MM-DD"],
                ],
                "required": ["day"],
            ],
        ],
        [
            "name": "list_chronicles",
            "description": "List which days have stored chronicles (daily summaries), newest first.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "search_transcriptions",
            "description": "Full-text search across the user's own dictated transcription history (not screen capture). Returns matching entries with id, timestamp, word count, and a text preview.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search terms (substring match)"],
                    "limit": ["type": "integer", "description": "Max results (default 10, max 50)"],
                ],
                "required": ["query"],
            ],
        ],
    ]

    // MARK: - JSON-RPC plumbing

    private func send(id: Any, result: [String: Any]) {
        emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(errorId: Any, code: Int, message: String) {
        emit(["jsonrpc": "2.0", "id": errorId, "error": ["code": code, "message": message]])
    }

    private func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A) // newline-delimited framing
        FileHandle.standardOutput.write(data)
    }
}
