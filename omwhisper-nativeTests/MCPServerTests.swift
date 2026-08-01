import Testing
import Foundation
import GRDB
@testable import OmWhisper

@Suite("MCPServer")
struct MCPServerTests {
    private func makeServer(memory: MemoryStore? = nil, history: HistoryStore? = nil) -> MCPServer {
        MCPServer(historyStore: history, memoryStore: memory)
    }

    @Test("search_memory requires a non-empty query")
    func searchMemoryRequiresQuery() {
        let server = makeServer()
        do {
            _ = try server.callTool(name: "search_memory", args: [:])
            Issue.record("expected callTool to throw for a missing query")
        } catch {
            // expected
        }
    }

    @Test("search_memory returns a not-available message when memoryStore is nil")
    func searchMemoryHandlesNilStore() throws {
        let server = makeServer()
        let result = try server.callTool(name: "search_memory", args: ["query": "budget"])
        #expect(result == "Memory is not available.")
    }

    @Test("search_memory finds and renders a matching snapshot")
    func searchMemoryFindsContent() throws {
        let memory = try MemoryStore(DatabaseQueue())
        try memory.upsert(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Inbox", content: "quarterly budget review", url: "")
        let server = makeServer(memory: memory)
        let result = try server.callTool(name: "search_memory", args: ["query": "budget"])
        #expect(result.contains("Mail"))
        #expect(result.contains("budget"))
    }

    @Test("search_memory reports no matches with a clear message")
    func searchMemoryNoMatches() throws {
        let memory = try MemoryStore(DatabaseQueue())
        let server = makeServer(memory: memory)
        let result = try server.callTool(name: "search_memory", args: ["query": "nonexistent"])
        #expect(result.contains("No snapshots match"))
    }

    @Test("get_recent_activity returns snapshots within the window")
    func recentActivityReturnsSnapshots() throws {
        let memory = try MemoryStore(DatabaseQueue())
        try memory.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Today", content: "hello", url: "")
        let server = makeServer(memory: memory)
        let result = try server.callTool(name: "get_recent_activity", args: [:])
        #expect(result.contains("Notes"))
    }

    @Test("get_snapshot requires an integer id")
    func getSnapshotRequiresID() {
        let server = makeServer()
        do {
            _ = try server.callTool(name: "get_snapshot", args: [:])
            Issue.record("expected callTool to throw for a missing id")
        } catch {
            // expected
        }
    }

    @Test("get_snapshot returns full content for a known id")
    func getSnapshotReturnsFullContent() throws {
        let memory = try MemoryStore(DatabaseQueue())
        try memory.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Today", content: "the full body text", url: "")
        let server = makeServer(memory: memory)
        let rows = try memory.fetchPage(offset: 0, limit: 1)
        guard let id = rows.first?.id else {
            Issue.record("expected row to have an id")
            return
        }
        let result = try server.callTool(name: "get_snapshot", args: ["id": id])
        #expect(result.contains("the full body text"))
    }

    @Test("get_snapshot throws for an unknown id")
    func getSnapshotThrowsForUnknownID() throws {
        let memory = try MemoryStore(DatabaseQueue())
        let server = makeServer(memory: memory)
        do {
            _ = try server.callTool(name: "get_snapshot", args: ["id": 999])
            Issue.record("expected callTool to throw for an unknown id")
        } catch {
            // expected
        }
    }

    @Test("get_chronicle returns the stored summary")
    func getChronicleReturnsSummary() throws {
        let memory = try MemoryStore(DatabaseQueue())
        try memory.upsertChronicle(day: "2026-07-08", summary: "Worked on the memory feature.", snapshotCount: 3)
        let server = makeServer(memory: memory)
        let result = try server.callTool(name: "get_chronicle", args: ["day": "2026-07-08"])
        #expect(result.contains("Worked on the memory feature."))
    }

    @Test("get_chronicle throws for a day with no chronicle")
    func getChronicleThrowsWhenMissing() throws {
        let memory = try MemoryStore(DatabaseQueue())
        let server = makeServer(memory: memory)
        do {
            _ = try server.callTool(name: "get_chronicle", args: ["day": "2026-01-01"])
            Issue.record("expected callTool to throw for a missing chronicle")
        } catch {
            // expected
        }
    }

    @Test("list_chronicles lists stored days newest first")
    func listChroniclesOrdersByDay() throws {
        let memory = try MemoryStore(DatabaseQueue())
        try memory.upsertChronicle(day: "2026-07-06", summary: "Day 1.", snapshotCount: 1)
        try memory.upsertChronicle(day: "2026-07-08", summary: "Day 3.", snapshotCount: 1)
        let server = makeServer(memory: memory)
        let result = try server.callTool(name: "list_chronicles", args: [:])
        guard let firstIndex = result.range(of: "2026-07-08")?.lowerBound,
              let secondIndex = result.range(of: "2026-07-06")?.lowerBound else {
            Issue.record("expected both days to appear in the result")
            return
        }
        #expect(firstIndex < secondIndex)
    }

    @Test("search_transcriptions finds and renders a matching entry")
    func searchTranscriptionsFindsContent() throws {
        let history = try HistoryStore(DatabaseQueue())
        try history.record(text: "quarterly budget review notes", duration: 5, modelUsed: "test")
        let server = makeServer(history: history)
        let result = try server.callTool(name: "search_transcriptions", args: ["query": "budget"])
        #expect(result.contains("budget"))
    }

    @Test("search_transcriptions returns a not-available message when historyStore is nil")
    func searchTranscriptionsHandlesNilStore() throws {
        let server = makeServer()
        let result = try server.callTool(name: "search_transcriptions", args: ["query": "budget"])
        #expect(result == "History is not available.")
    }

    @Test("unknown tool name throws")
    func unknownToolThrows() {
        let server = makeServer()
        do {
            _ = try server.callTool(name: "not_a_real_tool", args: [:])
            Issue.record("expected callTool to throw for an unknown tool")
        } catch {
            // expected
        }
    }

    // MARK: meetings (SP3)

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
}
