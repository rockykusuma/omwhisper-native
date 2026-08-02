import Testing
import Foundation
import os
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

/// Counts polish() calls so a chunk-limit change is measurable. A class with a
/// lock rather than a struct: PolishBackend is Sendable and polish() is
/// non-mutating, so there is nowhere to put a counter otherwise. Matches
/// AudioCapture's established lock-not-actor-isolation pattern.
private final class CountingPolishBackend: PolishBackend, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var callCount: Int { lock.withLock { $0 } }

    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        lock.withLock { $0 += 1 }
        return style.id == Chronicler.chunkSummaryStyle.id ? "- did some work" : "STUB CHRONICLE"
    }
}

@Suite("Chronicler chunk limit")
struct ChronicleChunkLimitTests {
    /// One snapshot per row, each comfortably under the per-snapshot cap, but
    /// enough of them that 1,800-char chunking needs several passes.
    private func seededStore(count: Int) throws -> MemoryStore {
        let store = try MemoryStore(DatabaseQueue())
        for i in 0..<count {
            try store.upsert(
                appName: "App\(i)", bundleID: "com.example.app\(i)",
                windowTitle: "Window \(i)",
                content: String(repeating: "alpha beta gamma delta ", count: 20) + "row\(i)",
                url: ""
            )
        }
        return store
    }

    @Test("a bigger chunk limit means fewer model calls")
    func biggerChunkLimitMeansFewerModelCalls() async throws {
        let day = Chronicler.dayString()

        let small = CountingPolishBackend()
        _ = try await Chronicler.generate(day: day, store: try seededStore(count: 12),
                                          polish: small, chunkLimit: Chronicler.chunkCharLimit)

        let big = CountingPolishBackend()
        _ = try await Chronicler.generate(day: day, store: try seededStore(count: 12),
                                          polish: big, chunkLimit: 12_000)

        // The assertion that fails if chunkLimit is accepted and ignored.
        // "it still produced a chronicle" would pass either way.
        #expect(big.callCount < small.callCount,
                "12k limit made \(big.callCount) calls, 1.8k made \(small.callCount)")
        #expect(big.callCount >= 1)
    }

    @Test("omitting the limit behaves exactly as the old default did")
    func defaultLimitIsUnchanged() async throws {
        let day = Chronicler.dayString()

        let explicit = CountingPolishBackend()
        _ = try await Chronicler.generate(day: day, store: try seededStore(count: 12),
                                          polish: explicit, chunkLimit: Chronicler.chunkCharLimit)

        let byDefault = CountingPolishBackend()
        _ = try await Chronicler.generate(day: day, store: try seededStore(count: 12),
                                          polish: byDefault)

        #expect(byDefault.callCount == explicit.callCount)
    }
}

@Suite("Chronicler selection")
struct ChronicleSelectionTests {
    private func snap(
        _ id: Int64, app: String, title: String = "w", content: String = "body",
        at iso: String
    ) -> MemorySnapshot {
        MemorySnapshot(
            id: id, appName: app, bundleID: "com.example.\(app)", windowTitle: title,
            content: content, url: "", contentHash: "h\(id)", capturedAt: iso, lastSeenAt: iso)
    }

    @Test("two snapshots of one app in one bucket collapse to one")
    func collapsesWithinBucket() {
        let picked = Chronicler.select([
            snap(1, app: "Arc", content: "short", at: "2026-08-01T09:01:00Z"),
            snap(2, app: "Arc", content: "much longer body here", at: "2026-08-01T09:07:00Z"),
        ])
        #expect(picked.count == 1)
        // Longest content wins -- the most substantial capture, not an arbitrary one.
        #expect(picked.first?.snapshot.id == 2)
    }

    @Test("two apps in the same bucket both survive")
    func keepsEachAppInABucket() {
        let picked = Chronicler.select([
            snap(1, app: "Arc", at: "2026-08-01T09:01:00Z"),
            snap(2, app: "Code", at: "2026-08-01T09:02:00Z"),
        ])
        #expect(picked.count == 2)
        #expect(Set(picked.map(\.snapshot.appName)) == ["Arc", "Code"])
    }

    @Test("a bucket boundary splits the same app")
    func splitsAcrossBucketBoundary() {
        let picked = Chronicler.select([
            snap(1, app: "Arc", at: "2026-08-01T09:14:59Z"),
            snap(2, app: "Arc", at: "2026-08-01T09:15:01Z"),
        ])
        #expect(picked.count == 2)
    }

    @Test("output stays in chronological order")
    func preservesChronology() {
        let picked = Chronicler.select([
            snap(3, app: "Code", at: "2026-08-01T11:00:00Z"),
            snap(1, app: "Arc", at: "2026-08-01T09:00:00Z"),
            snap(2, app: "Orca", at: "2026-08-01T10:00:00Z"),
        ])
        #expect(picked.map(\.snapshot.id) == [1, 2, 3])
    }

    @Test("other window titles in a group survive even though their bodies don't")
    func keepsOtherTitles() {
        let picked = Chronicler.select([
            snap(1, app: "Code", title: "Chronicler.swift", content: "aaa", at: "2026-08-01T09:01:00Z"),
            snap(2, app: "Code", title: "AppState.swift", content: "a much longer body", at: "2026-08-01T09:02:00Z"),
            snap(3, app: "Code", title: "Ollama.swift", content: "bb", at: "2026-08-01T09:03:00Z"),
        ])
        #expect(picked.count == 1)
        #expect(picked.first?.snapshot.windowTitle == "AppState.swift")
        #expect(Set(picked.first?.otherTitles ?? []) == ["Chronicler.swift", "Ollama.swift"])
    }

    @Test("empty input returns empty")
    func emptyInput() {
        #expect(Chronicler.select([]).isEmpty)
    }

    @Test("a real day's volume reduces to a bounded count")
    func reducesARealDay() {
        // The measured shape of 2026-08-01: 1,429 snapshots, 17 apps, 26 buckets.
        // This is the test that fails if select() is a no-op -- asserting only
        // that it "returns something" would pass either way.
        var day: [MemorySnapshot] = []
        var id: Int64 = 0
        for bucket in 0..<26 {
            for appIndex in 0..<17 {
                for repeatIndex in 0..<4 {
                    id += 1
                    let minute = bucket * 15 + (repeatIndex % 15)
                    let iso = String(format: "2026-08-01T%02d:%02d:00Z", 6 + minute / 60, minute % 60)
                    day.append(snap(id, app: "App\(appIndex)", title: "w\(repeatIndex)",
                                    content: String(repeating: "x", count: 100 + repeatIndex), at: iso))
                }
            }
        }
        #expect(day.count == 26 * 17 * 4)
        let picked = Chronicler.select(day)
        #expect(picked.count < day.count / 3, "selected \(picked.count) of \(day.count)")
        #expect(picked.count >= 17, "must keep at least one entry per app")
    }

    @Test("the cap is enforced and drops from across the day, not just the tail")
    func capSpreadsAcrossTheDay() {
        var day: [MemorySnapshot] = []
        for i in 0..<300 {
            let iso = String(format: "2026-08-01T%02d:%02d:00Z", 0 + i / 60, i % 60)
            day.append(snap(Int64(i), app: "App\(i)", at: iso))
        }
        let picked = Chronicler.select(day, cap: 50)
        #expect(picked.count == 50)
        // A tail-truncating cap would keep only the earliest hour.
        let lastKept = picked.last?.snapshot.lastSeenAt ?? ""
        #expect(lastKept > "2026-08-01T03:00:00Z", "cap dropped the whole later day: \(lastKept)")
    }
}

@Suite("Chronicler progress")
struct ChronicleProgressTests {
    @Test("the block names the other windows from its group")
    func blockIncludesOtherTitles() {
        let snapshot = MemorySnapshot(
            id: 1, appName: "Code", bundleID: "com.example.code", windowTitle: "AppState.swift",
            content: "editing", url: "", contentHash: "h", capturedAt: "2026-08-01T09:00:00Z",
            lastSeenAt: "2026-08-01T09:00:00Z")
        let block = Chronicler.formatBlock(
            Chronicler.Selected(snapshot: snapshot, otherTitles: ["Ollama.swift", "Chronicler.swift"]))
        #expect(block.contains("AppState.swift"))
        #expect(block.contains("Ollama.swift"))
        #expect(block.contains("Chronicler.swift"))
        #expect(block.contains("editing"))
    }

    @Test("progress is monotonic and ends at the total")
    func reportsProgress() async throws {
        let store = try MemoryStore(DatabaseQueue())
        for i in 0..<40 {
            try store.upsert(appName: "App\(i % 4)", bundleID: "com.example.a\(i % 4)",
                             windowTitle: "w\(i)",
                             content: String(repeating: "alpha beta gamma ", count: 30) + "\(i)",
                             url: "")
        }
        let reports = OSAllocatedUnfairLock(initialState: [(Int, Int)]())
        _ = try await Chronicler.generate(
            day: Chronicler.dayString(), store: store, polish: StubPolish(),
            chunkLimit: 400,
            onProgress: { done, total in reports.withLock { $0.append((done, total)) } })

        let seen = reports.withLock { $0 }
        #expect(!seen.isEmpty, "no progress was reported")
        #expect(seen.allSatisfy { $0.1 > 0 }, "total must be known when reporting")
        let dones = seen.map(\.0)
        #expect(dones == dones.sorted(), "progress went backwards: \(dones)")
        #expect(dones.last == seen.last?.1, "final progress should equal the total")
    }
}

/// Deterministic stand-in — declared separately so this suite doesn't depend on
/// the file-private stub above it.
private struct StubPolish: PolishBackend {
    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        style.id == Chronicler.chunkSummaryStyle.id ? "- did some work" : "STUB CHRONICLE"
    }
}
