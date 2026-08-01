# SP3 — Post-Meeting Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer questions about meetings and get them out of the app — MCP tools for cross-meeting Q&A with a real frontier model, an in-app one-shot "ask about this meeting", markdown/text export, and a follow-up email draft. Completes the competitive-parity plan (`docs/superpowers/specs/2026-08-01-meetings-competitive-parity-design.md` §4).

**Architecture:** `MCPServer` gains a third store (`meetingStore`) and two read-only tools, matching its existing dispatch/render shape exactly. In-app Q&A reuses SP2's map-reduce machinery with two new hidden fixed-UUID `PolishStyle`s and the same `generateMeetingSummary` backend routing (Ollama-or-System, never Cloud). Export builds a pure string from a `Meeting` and writes it through `NSSavePanel`, following `HistoryView.export`'s established pattern.

**Tech Stack:** Swift 6 (MainActor-by-default), GRDB, existing `PolishBackend`, SwiftUI, Swift Testing.

## Global Constraints

- Meetings never egress: the Q&A and follow-up paths route through `AppState`'s existing meeting-backend selection (Ollama when selected, else SystemLLM). **Cloud must never appear.**
- MCP tools are **read-only** and stay behind the existing `mcpAccessEnabled` gate — `MCPLauncher` already refuses to open any store when it's off; the new store must be inside that same guard.
- Every LLM prompt must put section bodies on the line *after* a `## ` heading, never on the heading line (the blank-card bug's cause).
- Hidden styles use fixed UUIDs and are never added to `PolishStyles.builtIns` or `MeetingSummarizer.builtInTemplates` — they are machinery, not user-selectable templates.
- Full-suite command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`.
- Isolated worktree; emoji conventional commits.

---

### Task 1: MCP meeting tools

**Files:**
- Modify: `omwhisper-native/MCP/MCPServer.swift`
- Modify: `omwhisper-native/MCP/MCPLauncher.swift`
- Test: `omwhisper-nativeTests/MCPServerTests.swift`

**Interfaces:**
- Produces: `MCPServer.init(historyStore:memoryStore:meetingStore:)` — **`meetingStore` must have a default of `nil`** so the existing `makeServer` helper in `MCPServerTests` and any other call site keep compiling; two tools, `search_meetings(query, limit)` and `get_meeting(id)`.
- Consumes: `MeetingStore.search/fetchPage/get` (existing), `MeetingDiarization.applySpeakerNames` (SP1) so tool output carries renamed speakers, not raw labels.

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MCPServerTests.swift`:

```swift
    private func makeMeetingStore() throws -> MeetingStore {
        try MeetingStore(DatabaseQueue())
    }

    @Test("search_meetings requires a non-empty query")
    func searchMeetingsRequiresQuery() {
        let server = MCPServer(historyStore: nil, memoryStore: nil, meetingStore: nil)
        do {
            _ = try server.callTool(name: "search_meetings", args: [:])
            Issue.record("expected callTool to throw for a missing query")
        } catch {
            // expected
        }
    }

    @Test("search_meetings reports when meetings are unavailable")
    func searchMeetingsHandlesNilStore() throws {
        let server = MCPServer(historyStore: nil, memoryStore: nil, meetingStore: nil)
        let out = try server.callTool(name: "search_meetings", args: ["query": "roadmap"])
        #expect(out.localizedCaseInsensitiveContains("not available"))
    }

    @Test("search_meetings finds a meeting by transcript text")
    func searchMeetingsFindsByTranscript() throws {
        let store = try makeMeetingStore()
        let id = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-01T10:00:00Z", appName: "Zoom",
            directory: "/tmp/omw-mcp-test", durationSeconds: 600,
            transcript: nil, summary: nil, createdAt: "2026-08-01T10:00:00Z",
            title: "Q3 Planning"))
        try store.setTranscriptAndSummary(
            id: id, transcript: "**Speaker 1:** [0:01]\nwe discussed the pricing model", summary: nil)
        let server = MCPServer(historyStore: nil, memoryStore: nil, meetingStore: store)
        let out = try server.callTool(name: "search_meetings", args: ["query": "pricing"])
        #expect(out.contains("Q3 Planning"))
        #expect(try server.callTool(name: "search_meetings", args: ["query": "unrelated"])
            .localizedCaseInsensitiveContains("no meetings"))
    }

    /// The tool must serve renamed speakers, not raw diarization labels — an
    /// assistant answering "what did Alice say" can't work from "Speaker 1".
    @Test("get_meeting returns detail with speaker names resolved")
    func getMeetingResolvesSpeakerNames() throws {
        let store = try makeMeetingStore()
        let id = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-01T10:00:00Z", appName: "Teams",
            directory: "/tmp/omw-mcp-test2", durationSeconds: 300,
            transcript: nil, summary: nil, createdAt: "2026-08-01T10:00:00Z",
            title: "Standup", attendees: ["Alice"]))
        try store.setTranscriptAndSummary(
            id: id, transcript: "**Speaker 1:** [0:01]\nblocked on the build", summary: "## Summary\nshort")
        try store.setSpeakerNames(id: id, ["Speaker 1": "Alice"])
        let server = MCPServer(historyStore: nil, memoryStore: nil, meetingStore: store)
        let out = try server.callTool(name: "get_meeting", args: ["id": id])
        #expect(out.contains("Alice"))
        #expect(!out.contains("Speaker 1"))
        #expect(out.contains("Standup"))
    }

    @Test("get_meeting throws for an unknown id")
    func getMeetingUnknownID() throws {
        let store = try makeMeetingStore()
        let server = MCPServer(historyStore: nil, memoryStore: nil, meetingStore: store)
        do {
            _ = try server.callTool(name: "get_meeting", args: ["id": 999])
            Issue.record("expected callTool to throw for an unknown id")
        } catch {
            // expected
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MCPServerTests 2>&1 | grep -E "error:" | head -4`
Expected: `extra argument 'meetingStore' in call` / `unknown tool`.

- [ ] **Step 3: Implement the store + dispatch**

In `MCPServer.swift`, add the stored property beside the other two and extend `init` (default `nil` — existing call sites must keep compiling):

```swift
    private let meetingStore: MeetingStore?
```

```swift
    init(historyStore: HistoryStore?, memoryStore: MemoryStore?, meetingStore: MeetingStore? = nil) {
```

…assigning `self.meetingStore = meetingStore` alongside the existing assignments.

Add two cases to `callTool`, immediately before `default:`:

```swift
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
```

Add the two renderers next to the existing `render(_:emptyMessage:)`:

```swift
    /// One line per meeting for search results — enough to choose one, then
    /// get_meeting(id) for the full text. Mirrors render()'s compact style.
    private static func meetingSummaryLine(_ m: Meeting) -> String {
        let minutes = Int(m.durationSeconds / 60)
        return "id: \(m.id ?? 0) | \(m.startedAt) | \(m.title ?? m.appName) | \(minutes)m"
    }

    /// Full detail. Speaker names are resolved (SP1) so an assistant sees
    /// "Alice", not "Speaker 1" — the raw labels are meaningless to a caller.
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
```

Add the two tool definitions to `toolDefinitions`:

```swift
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
```

- [ ] **Step 4: Open the store in the launcher**

In `MCPLauncher.swift`, **inside the same block that opens the other two stores** (the one gated by the access check — do not add it outside that guard):

```swift
            meetingStore = try? MeetingStore.open(atPath: appSupportDir.appendingPathComponent("meetings.db").path)
```

…with `var meetingStore: MeetingStore?` declared beside the others, and pass it to the `MCPServer(...)` call.

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MCPServerTests 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/MCP/MCPServer.swift omwhisper-native/MCP/MCPLauncher.swift omwhisper-nativeTests/MCPServerTests.swift
git commit -m "✨ feat(meetings): search_meetings + get_meeting MCP tools"
```

---

### Task 2: Export a meeting to markdown / plain text

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingStore.swift` (pure export builder)
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift` (menu + save panel)
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `MeetingDetails.export(_ meeting: Meeting, format: MeetingExportFormat) -> String`; `nonisolated enum MeetingExportFormat { case markdown, text }`.
- Consumes: `MeetingDiarization.applySpeakerNames`.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func exportMarkdownCarriesHeaderSummaryAndResolvedTranscript() throws {
        let store = try makeStore()
        let id = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-01T10:00:00Z", appName: "Zoom",
            directory: "/tmp/omw-export", durationSeconds: 900,
            transcript: nil, summary: nil, createdAt: "2026-08-01T10:00:00Z",
            title: "Q3 Planning", attendees: ["Alice", "Bob"]))
        try store.setTranscriptAndSummary(
            id: id, transcript: "**Speaker 1:** [0:01]\nhello", summary: "## Summary\nshort")
        try store.setSpeakerNames(id: id, ["Speaker 1": "Alice"])
        let meeting = try #require(try store.get(id: id))

        let md = MeetingDetails.export(meeting, format: .markdown)
        #expect(md.contains("# Q3 Planning"))
        #expect(md.contains("Alice, Bob"))
        #expect(md.contains("## Summary"))
        #expect(md.contains("**Alice:**"))     // renamed, not "Speaker 1"
        #expect(!md.contains("Speaker 1"))
    }

    /// Plain text must not leak markdown syntax — that's the whole point of
    /// offering it as a separate format.
    @Test func exportTextStripsMarkdownMarkers() throws {
        let store = try makeStore()
        let id = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-01T10:00:00Z", appName: "Zoom",
            directory: "/tmp/omw-export2", durationSeconds: 60,
            transcript: nil, summary: nil, createdAt: "2026-08-01T10:00:00Z",
            title: "Retro"))
        try store.setTranscriptAndSummary(
            id: id, transcript: "**You:** [0:01]\nhi", summary: "## Summary\nshort")
        let meeting = try #require(try store.get(id: id))

        let txt = MeetingDetails.export(meeting, format: .text)
        #expect(txt.contains("Retro"))
        #expect(txt.contains("You:"))
        #expect(!txt.contains("**"))
        #expect(!txt.contains("## "))
    }

    @Test func exportUsesAppNameWhenUntitled() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Webex")
        let meeting = try #require(try store.get(id: id))
        #expect(MeetingDetails.export(meeting, format: .markdown).contains("# Webex"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'MeetingExportFormat'` / no member `export`.

- [ ] **Step 3: Implement**

In `MeetingStore.swift`, add above `enum MeetingDetails`:

```swift
nonisolated enum MeetingExportFormat { case markdown, text }
```

…and inside `MeetingDetails`:

```swift
    /// One meeting as a self-contained document: header, summary, transcript
    /// with speaker renames applied. Pure — the save panel lives in the view.
    static func export(_ meeting: Meeting, format: MeetingExportFormat) -> String {
        let transcript = MeetingDiarization.applySpeakerNames(
            meeting.transcript ?? "", names: meeting.speakerNames ?? [:])
        var out = "# \(meeting.title ?? meeting.appName)\n\n"
        out += "\(meeting.startedAt) · \(Int(meeting.durationSeconds / 60))m · \(meeting.appName)\n"
        if let attendees = meeting.attendees, !attendees.isEmpty {
            out += "With \(attendees.joined(separator: ", "))\n"
        }
        if let summary = meeting.summary, !summary.isEmpty {
            out += "\n\(summary)\n"
        }
        out += "\n## Transcript\n\n\(transcript.isEmpty ? "(not transcribed)" : transcript)\n"
        return format == .markdown ? out : stripMarkdown(out)
    }

    /// Markdown → plain text: drop heading hashes and bold markers, keep the
    /// words and the line structure. Deliberately not a markdown parser —
    /// the input is only ever what export() just wrote plus model-written
    /// summary markdown, both of which use exactly these two markers.
    private static func stripMarkdown(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line -> String in
                var l = line
                while l.hasPrefix("#") { l.removeFirst() }
                return l.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            }
            .joined(separator: "\n")
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: TEST SUCCEEDED.

- [ ] **Step 5: Wire the UI**

In `HubMeetingsSectionView.swift`, add `import UniformTypeIdentifiers` at the top if absent (HistoryView needs it for `UTType`; check before adding).

In `MeetingDetailView.header`'s button row, replace the existing `Button("Copy transcript")` block with:

```swift
                if !turns.isEmpty {
                    Menu("Share") {
                        Button("Copy transcript") { copyTranscript() }
                        Button("Copy summary") { copySummary() }
                        Divider()
                        Button("Export as Markdown…") { exportMeeting(.markdown, ext: "md") }
                        Button("Export as Text…") { exportMeeting(.text, ext: "txt") }
                    }
                    .fixedSize()
                }
```

Add the actions beside `copyTranscript()`:

```swift
    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.summary ?? "", forType: .string)
    }

    /// Same NSSavePanel shape as HistoryView.export — one established pattern
    /// for "write a file the user names".
    private func exportMeeting(_ format: MeetingExportFormat, ext: String) {
        let content = MeetingDetails.export(meeting, format: format)
        let panel = NSSavePanel()
        let base = (meeting.title ?? meeting.appName)
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(base).\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }
```

- [ ] **Step 6: Full build + suite, commit**

Run the full-suite command → TEST SUCCEEDED.

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-native/UI/HubMeetingsSectionView.swift omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "✨ feat(meetings): export a meeting as markdown or text; copy summary"
```

---

### Task 3: Ask about this meeting (one-shot) + follow-up draft

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingSummarizer.swift` (two hidden styles + `answer`)
- Modify: `omwhisper-native/AppState.swift` (two entry points)
- Test: `omwhisper-nativeTests/MeetingSummarizerTests.swift`

**Interfaces:**
- Produces: `MeetingSummarizer.answer(question:transcript:polish:chunkLimit:) async throws -> String`; `MeetingSummarizer.followUpStyle`; `AppState.askAboutMeeting(id:question:) async -> String?`; `AppState.draftFollowUp(id:) async -> String?`.
- Consumes: SP2's `chunk`, `generateMeetingSummary`'s backend selection (reuse the same private helpers), `MeetingDiarization.applySpeakerNames`.

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MeetingSummarizerTests.swift`:

```swift
    /// Records every (style, text) pair so the map/reduce shape can be asserted.
    private struct CapturingPolish: PolishBackend {
        let capture: @Sendable (UUID, String) -> Void
        let reply: String
        func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
            capture(style.id, text)
            return reply
        }
    }

    @Test func answerPutsTheQuestionInBothStages() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [(UUID, String)]())
        let fake = CapturingPolish(capture: { id, text in seen.withLock { $0.append((id, text)) } },
                                   reply: "not discussed")
        _ = try await MeetingSummarizer.answer(
            question: "what did we decide about pricing",
            transcript: "**You:** [0:00]\nhello", polish: fake)
        let calls = seen.withLock { $0 }
        #expect(calls.count >= 2)
        // Extraction stage carries the question, and so does the final answer stage.
        #expect(calls.first!.1.localizedCaseInsensitiveContains("pricing"))
        #expect(calls.last!.1.localizedCaseInsensitiveContains("pricing"))
    }

    @Test func answerOnEmptyTranscriptSaysSo() async throws {
        let fake = CapturingPolish(capture: { _, _ in }, reply: "x")
        let out = try await MeetingSummarizer.answer(
            question: "anything?", transcript: "   ", polish: fake)
        #expect(out.localizedCaseInsensitiveContains("nothing"))
    }

    @Test func followUpStyleIsHiddenFromTemplates() {
        #expect(!MeetingSummarizer.builtInTemplates.contains { $0.id == MeetingSummarizer.followUpStyle.id })
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingSummarizerTests 2>&1 | grep -E "error:" | head -3`
Expected: no member `answer` / `followUpStyle`.

- [ ] **Step 3: Implement the styles and `answer`**

In `MeetingSummarizer.swift`, after `interviewTemplate` (these are machinery, so they are deliberately NOT added to `builtInTemplates`):

```swift
    // MARK: Hidden styles — machinery, never user-selectable templates.

    static let questionExtractStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000010")!,
        name: "Meeting Question Extract",
        prompt: """
            From this portion of a meeting transcript, extract ONLY the lines and \
            facts relevant to the question that follows it. Copy who said what. If \
            nothing in this portion is relevant, reply exactly: NOTHING RELEVANT. \
            No preamble.
            """,
        isBuiltIn: true
    )

    static let questionAnswerStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000011")!,
        name: "Meeting Question Answer",
        prompt: """
            Answer the question using ONLY the extracted meeting notes provided. \
            Two or three sentences, specific, naming who said what where it \
            matters. If the notes do not contain the answer, say exactly: \
            "That wasn't discussed in this meeting." Never speculate.
            """,
        isBuiltIn: true
    )

    static let followUpStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000012")!,
        name: "Meeting Follow-up Email",
        prompt: """
            Write a short follow-up email from these meeting notes, as the person \
            who recorded the meeting. Start with a "Subject:" line, then the body: \
            a one-line thanks, 2-4 bullets of what was decided, and the action \
            items with owners. Plain and professional, no filler, no invented \
            commitments. Output only the email.
            """,
        isBuiltIn: true
    )

    /// One-shot Q&A over a transcript: map each chunk to whatever is relevant to
    /// the question, then answer from those extracts. Same map-reduce shape and
    /// per-backend chunk sizing as generate(); no conversation state is kept.
    static func answer(
        question: String,
        transcript: String,
        polish: PolishBackend,
        chunkLimit: Int = chunkCharLimit
    ) async throws -> String {
        let chunks = chunk(transcript, limit: chunkLimit)
        guard !chunks.isEmpty else { return "There's nothing transcribed to answer from." }

        var extracts: [String] = []
        for group in chunks {
            let extract = try await polish.polish(
                "QUESTION: \(question)\n\nTRANSCRIPT:\n\(group)",
                style: questionExtractStyle, targetLanguage: nil)
            let trimmed = extract.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.localizedCaseInsensitiveContains("NOTHING RELEVANT") {
                extracts.append(trimmed)
            }
        }
        guard !extracts.isEmpty else { return "That wasn't discussed in this meeting." }

        let material = String(extracts.joined(separator: "\n").prefix(chunkLimit))
        let out = try await polish.polish(
            "QUESTION: \(question)\n\nNOTES:\n\(material)",
            style: questionAnswerStyle, targetLanguage: nil)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

- [ ] **Step 4: AppState entry points**

In `AppState.swift`, after `regenerateSummary`:

```swift
    /// One-shot question about a single meeting. Same on-device backend
    /// selection as summaries (Ollama when selected, else SystemLLM, never
    /// Cloud). Returns nil when no backend is available or the call fails —
    /// the caller shows errorMessage, which is already set here.
    func askAboutMeeting(id: Int64, question: String) async -> String? {
        guard let store = meetingStore, let meeting = try? store.get(id: id),
              let transcript = meeting.transcript, !transcript.isEmpty else {
            errorMessage = "That meeting has no transcript to answer from."
            return nil
        }
        guard let candidate = meetingSummaryBackends().first else {
            errorMessage = "No on-device summarizer available — turn on Apple Intelligence, or select Ollama in Settings > AI."
            return nil
        }
        let resolved = MeetingDiarization.applySpeakerNames(
            transcript, names: meeting.speakerNames ?? [:])
        do {
            return try await MeetingSummarizer.answer(
                question: question, transcript: resolved,
                polish: candidate.polish, chunkLimit: candidate.chunkLimit)
        } catch {
            errorMessage = "Couldn't answer that — \(error.localizedDescription)"
            return nil
        }
    }

    /// Draft a follow-up email from the meeting's summary (falling back to the
    /// transcript when there's no summary yet). Returns nil on failure.
    func draftFollowUp(id: Int64) async -> String? {
        guard let store = meetingStore, let meeting = try? store.get(id: id) else { return nil }
        let source = meeting.summary ?? MeetingDiarization.applySpeakerNames(
            meeting.transcript ?? "", names: meeting.speakerNames ?? [:])
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Nothing to draft from yet — transcribe the meeting first."
            return nil
        }
        guard let candidate = meetingSummaryBackends().first else {
            errorMessage = "No on-device summarizer available — turn on Apple Intelligence, or select Ollama in Settings > AI."
            return nil
        }
        do {
            return try await candidate.polish.polish(
                String(source.prefix(candidate.chunkLimit)),
                style: MeetingSummarizer.followUpStyle, targetLanguage: nil)
        } catch {
            errorMessage = "Couldn't draft the follow-up — \(error.localizedDescription)"
            return nil
        }
    }
```

- [ ] **Step 5: Run to verify pass, then full suite**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingSummarizerTests 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"` → SUCCEEDED.
Then the full-suite command → TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Meetings/MeetingSummarizer.swift omwhisper-native/AppState.swift omwhisper-nativeTests/MeetingSummarizerTests.swift
git commit -m "✨ feat(meetings): one-shot meeting Q&A and follow-up email drafting"
```

---

### Task 4: Ask box + Draft follow-up UI

**Files:**
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift`

**Interfaces:**
- Consumes: `appState.askAboutMeeting(id:question:)`, `appState.draftFollowUp(id:)`.
- Produces: no new API. Pure SwiftUI — verified live, no unit tests (project convention).

- [ ] **Step 1: State**

In `MeetingDetailView`:

```swift
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false
    @State private var draft: String?
```

- [ ] **Step 2: Ask box**

In the detail `ScrollView`'s `VStack`, directly after the summary card and before `transcriptBody`:

```swift
                    if meeting.transcript != nil { askCard }
```

Add:

```swift
    /// One question, one answer — no thread. Anything more conversational
    /// belongs in an MCP client with a real model behind it (see SP3 spec).
    private var askCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            PorcelainEyebrow("Ask about this meeting")
            HStack(spacing: 8) {
                TextField("What did we decide about…", text: $question)
                    .porcelainField()
                    .onSubmit { ask() }
                Button(asking ? "Asking…" : "Ask") { ask() }
                    .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let answer {
                Text(answer)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Color.Porcelain.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .omCard()
    }

    private func ask() {
        guard let id = meeting.id else { return }
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        asking = true
        answer = nil
        Task {
            answer = await appState.askAboutMeeting(id: id, question: q)
            asking = false
        }
    }
```

- [ ] **Step 3: Draft follow-up**

Add to the Share menu from Task 2, after the export items:

```swift
                        Divider()
                        Button("Draft follow-up email…") { makeDraft() }
```

Add the action and a review sheet (shown so the user reads it before it reaches anyone — never sent, only copied):

```swift
    private func makeDraft() {
        guard let id = meeting.id else { return }
        working = true
        Task {
            draft = await appState.draftFollowUp(id: id)
            working = false
        }
    }
```

Attach to the detail `VStack` in `body`:

```swift
        .sheet(isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Follow-up draft")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                ScrollView {
                    Text(draft ?? "")
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 460, height: 280)
                HStack {
                    Button("Close") { draft = nil }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft ?? "", forType: .string)
                        draft = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .background(Color.Porcelain.bg)
        }
```

- [ ] **Step 4: Full build + suite, commit**

Run the full-suite command → TEST SUCCEEDED.

```bash
git add omwhisper-native/UI/HubMeetingsSectionView.swift
git commit -m "✨ feat(meetings): ask-about-this-meeting box and follow-up draft sheet"
```

---

### Task 5: MCP config docs + live verification

- [ ] **Step 1: Confirm the Settings config block still fits**

`UI/MCPSettingsView.swift` renders a Claude Desktop config built from `Bundle.main.executablePath` and lists what the server exposes. Read it; if it enumerates tool names, add the two new ones. If it doesn't enumerate them, change nothing — the server advertises them via `tools/list` at runtime.

- [ ] **Step 2: Rebuild and relaunch the dev app**

```bash
osascript -e 'tell application id "com.omwhisper.mac.dev" to quit' 2>/dev/null
DD=$(xcodebuild -showBuildSettings -scheme omwhisper-native -project omwhisper-native.xcodeproj -configuration Debug 2>/dev/null | grep -m1 "  BUILT_PRODUCTS_DIR" | sed 's/.*= //')
open "$DD/OmWhisper-Dev.app"
```

- [ ] **Step 3: Prove the MCP tools against the real binary** (the check that can fail — the tools are dispatched by a subprocess, not the GUI)

With MCP access enabled in Settings, pipe a real request into the built binary:

```bash
DD=$(xcodebuild -showBuildSettings -scheme omwhisper-native -project omwhisper-native.xcodeproj -configuration Debug 2>/dev/null | grep -m1 "  BUILT_PRODUCTS_DIR" | sed 's/.*= //')
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"the"}}}' \
  | "$DD/OmWhisper-Dev.app/Contents/MacOS/OmWhisper-Dev" --mcp | head -20
```

Expected: an `initialize` result, then a real meeting line from the dev database (or "No meetings match" if the dev store is empty — seed one by recording first, otherwise this check proves nothing).

- [ ] **Step 4: Live checklist (user)**

1. **Ask** — open a transcribed meeting, ask something it *does* cover → a specific answer; ask something it doesn't → "That wasn't discussed in this meeting" rather than an invention.
2. **Export** — Share → Export as Markdown → the file opens with title, attendees, summary and renamed speakers; export as Text → no `**` or `##` markers.
3. **Copy summary** — pastes the summary, not the transcript.
4. **Follow-up draft** — sheet shows a Subject line plus decisions and action items; Copy puts it on the clipboard. Nothing is sent anywhere.
5. **MCP from a real client** — add the config from Settings → MCP to Claude Desktop, restart it, and ask "what did I discuss in my last meeting?" — it should call `search_meetings` then `get_meeting`.
