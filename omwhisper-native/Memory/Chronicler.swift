//
//  Chronicler.swift
//  OmWhisper
//
//  Map-reduce daily summarization: this app has exactly one PolishBackend
//  (SystemLLM, on-device Foundation Models) whose polish() call has a
//  hardcoded 5s timeout already found (S4) to need inputs capped around
//  2,000 chars. A whole day's snapshots regularly exceed that, so instead of
//  smriti's single ~120,000-char digest call, this chunks the day into
//  ≤1,800-char groups, summarizes each chunk (map), then writes the final
//  chronicle from the concatenated chunk summaries (reduce) -- every
//  individual polish() call stays inside the already-proven-safe zone, no
//  changes to PolishBackend/SystemLLM.
//

import Foundation

nonisolated enum Chronicler {
    struct ChronicleResult {
        let day: String
        let summary: String
        let snapshotCount: Int
    }

    enum ChroniclerError: Error, LocalizedError, Equatable {
        case noSnapshots
        var errorDescription: String? { "No captured activity for that day." }
    }

    static let perSnapshotLimit = 500
    static let chunkCharLimit = 1_800
    static let reduceCharLimit = 1_800

    /// Fixed-UUID internal styles -- never shown in the AI tab's picker (not
    /// added to PolishStyles.builtIns), same pattern as S4's hidden
    /// reply-draft style.
    static let chunkSummaryStyle = PolishStyle(
        id: UUID(uuidString: "6C8A1C1E-0000-4A00-8000-000000000001")!,
        name: "Memory Chunk Summary",
        prompt: """
            Summarize this log of app/window activity into 2-4 terse bullet \
            points of what was worked on. No preamble, just bullets.
            """,
        isBuiltIn: true
    )
    static let chronicleWriteStyle = PolishStyle(
        id: UUID(uuidString: "6C8A1C1E-0000-4A00-8000-000000000002")!,
        name: "Memory Chronicle",
        prompt: """
            You are writing a private daily chronicle from bullet-point \
            activity summaries captured from the user's Mac screen \
            throughout the day. Write a concise markdown chronicle with \
            these sections:
            ## Summary — 2-3 sentences on what the day was about.
            ## Work & projects — what was worked on, per project/task, \
            merging repeated mentions of the same thing.
            ## Notable — anything worth remembering later: decisions, \
            errors, things ordered/booked, articles read.
            Rules: be specific, no filler, no speculation beyond what the \
            bullets show. The reader is the user themselves — write in \
            second person ("you worked on...").
            """,
        isBuiltIn: true
    )

    /// Pure: one digest line for a snapshot, content clipped to perSnapshotLimit.
    static func formatBlock(_ snapshot: MemorySnapshot) -> String {
        let content = snapshot.content
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(perSnapshotLimit)
        let location = snapshot.url.isEmpty ? "" : " <\(snapshot.url)>"
        return "[\(snapshot.lastSeenAt)] \(snapshot.appName) — \(snapshot.windowTitle)\(location)\n\(content)"
    }

    /// Pure: greedily packs blocks into groups whose combined length (with a
    /// blank-line separator between blocks) stays under `limit`. A single
    /// block longer than `limit` becomes its own oversized group rather than
    /// being split mid-block or dropped.
    static func chunk(_ blocks: [String], limit: Int = chunkCharLimit) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var currentLength = 0
        for block in blocks {
            let addedLength = block.count + (current.isEmpty ? 0 : 2)
            if !current.isEmpty && currentLength + addedLength > limit {
                groups.append(current)
                current = [block]
                currentLength = block.count
            } else {
                current.append(block)
                currentLength += addedLength
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Effectful: full generation for one day. Throws ChroniclerError.noSnapshots
    /// if there are no snapshots for that day; propagates the first polish()
    /// failure. Overwrites any existing chronicle for the same day.
    static func generate(day: String, store: MemoryStore, polish: PolishBackend) async throws -> ChronicleResult {
        let snapshots = try store.snapshotsForDay(day)
        guard !snapshots.isEmpty else {
            throw ChroniclerError.noSnapshots
        }
        let blocks = snapshots.map(formatBlock)
        let chunks = chunk(blocks)

        var chunkSummaries: [String] = []
        for group in chunks {
            let text = String(group.joined(separator: "\n\n").prefix(chunkCharLimit))
            let summary = try await polish.polish(text, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(reduceCharLimit))
        let chronicle = try await polish.polish(reduceInput, style: chronicleWriteStyle, targetLanguage: nil)
        let trimmed = chronicle.trimmingCharacters(in: .whitespacesAndNewlines)

        try store.upsertChronicle(day: day, summary: trimmed, snapshotCount: snapshots.count)
        return ChronicleResult(day: day, summary: trimmed, snapshotCount: snapshots.count)
    }

    /// Local calendar date string, matching smriti's dayString(daysAgo:).
    static func dayString(daysAgo: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return formatter.string(from: date)
    }
}
