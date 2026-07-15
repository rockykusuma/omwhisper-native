import Testing
import Foundation
import GRDB
@testable import OmWhisper

@Suite("Chronicler")
struct ChroniclerTests {

    // MARK: - formatBlock

    @Test("formatBlock clips content to perSnapshotLimit and includes metadata")
    func formatBlockClipsContent() {
        let snapshot = MemorySnapshot(
            id: 1, appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "AppState.swift",
            content: String(repeating: "x", count: Chronicler.perSnapshotLimit + 500),
            url: "", contentHash: "h", capturedAt: "2026-07-08T09:00:00Z", lastSeenAt: "2026-07-08T09:00:00Z"
        )
        let block = Chronicler.formatBlock(snapshot)
        #expect(block.contains("Xcode"))
        #expect(block.contains("AppState.swift"))
        #expect(block.count <= Chronicler.perSnapshotLimit + 100)  // metadata prefix + clipped content
    }

    @Test("formatBlock omits the url segment when url is empty")
    func formatBlockOmitsEmptyURL() {
        let snapshot = MemorySnapshot(
            id: 1, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled",
            content: "hello", url: "", contentHash: "h", capturedAt: "2026-07-08T09:00:00Z", lastSeenAt: "2026-07-08T09:00:00Z"
        )
        #expect(!Chronicler.formatBlock(snapshot).contains("<>"))
    }

    @Test("formatBlock includes the url segment when present")
    func formatBlockIncludesURL() {
        let snapshot = MemorySnapshot(
            id: 1, appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Example",
            content: "hello", url: "https://example.com", contentHash: "h",
            capturedAt: "2026-07-08T09:00:00Z", lastSeenAt: "2026-07-08T09:00:00Z"
        )
        #expect(Chronicler.formatBlock(snapshot).contains("<https://example.com>"))
    }

    // MARK: - chunk

    @Test("chunk of an empty array is empty")
    func chunkEmptyIsEmpty() {
        #expect(Chronicler.chunk([]).isEmpty)
    }

    @Test("chunk packs several small blocks into one group under the limit")
    func chunkPacksSmallBlocks() {
        let blocks = Array(repeating: "short block", count: 5)  // 5 * ~11 chars, well under limit
        let groups = Chronicler.chunk(blocks, limit: 1_800)
        #expect(groups.count == 1)
        #expect(groups[0].count == 5)
    }

    @Test("chunk splits into a new group once the limit would be exceeded")
    func chunkSplitsAtLimit() {
        let blockA = String(repeating: "a", count: 60)
        let blockB = String(repeating: "b", count: 60)
        let groups = Chronicler.chunk([blockA, blockB], limit: 100)
        #expect(groups.count == 2)
        #expect(groups[0] == [blockA])
        #expect(groups[1] == [blockB])
    }

    @Test("chunk gives a single oversized block its own group rather than dropping or splitting it")
    func chunkOversizedBlockGetsOwnGroup() {
        let huge = String(repeating: "x", count: 5_000)
        let small = "tiny"
        let groups = Chronicler.chunk([huge, small], limit: 1_800)
        #expect(groups.count == 2)
        #expect(groups[0] == [huge])
        #expect(groups[1] == [small])
    }

    // MARK: - dayString

    @Test("dayString(daysAgo: 0) matches today's local calendar date")
    func dayStringToday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        #expect(Chronicler.dayString() == formatter.string(from: Date()))
    }

    @Test("dayString(daysAgo: 1) is one calendar day before dayString(daysAgo: 0)")
    func dayStringYesterday() {
        let today = Chronicler.dayString(daysAgo: 0)
        let yesterday = Chronicler.dayString(daysAgo: 1)
        #expect(yesterday < today)
    }

    // MARK: - generate

    @Test("generate throws noSnapshots for a day with nothing captured")
    func generateThrowsWhenNoSnapshots() async throws {
        let store = try MemoryStore(DatabaseQueue())
        do {
            _ = try await Chronicler.generate(day: "2026-01-01", store: store, polish: StubPolishBackend())
            Issue.record("expected ChroniclerError.noSnapshots to be thrown")
        } catch Chronicler.ChroniclerError.noSnapshots {
            // expected
        }
    }

    @Test("generate stores a chronicle built from the stub backend's output")
    func generateStoresChronicle() async throws {
        let store = try MemoryStore(DatabaseQueue())
        try store.upsert(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "AppState.swift", content: "editing code", url: "")
        // dayString (local), not the UTC ISO8601 prefix — snapshotsForDay matches
        // on the local day, and the two disagree between midnight and UTC offset.
        let day = Chronicler.dayString()
        let result = try await Chronicler.generate(day: day, store: store, polish: StubPolishBackend())
        #expect(result.day == day)
        #expect(result.snapshotCount == 1)
        #expect(result.summary == "STUB CHRONICLE")
        #expect(try store.getChronicle(day: day)?.summary == "STUB CHRONICLE")
    }
}

/// Deterministic stand-in for the real LLM call — returns a fixed chunk
/// summary for the map step and a fixed final chronicle for the reduce step,
/// so generate()'s orchestration (not SystemLLM's real network/on-device
/// behavior, already covered by its own live usage elsewhere) is what's
/// under test here.
private struct StubPolishBackend: PolishBackend {
    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        style.id == Chronicler.chunkSummaryStyle.id ? "- did some work" : "STUB CHRONICLE"
    }
}
