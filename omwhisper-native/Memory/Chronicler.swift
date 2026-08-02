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
        /// Carries the caller's already-composed explanation, so the user sees
        /// why the on-device model can't run rather than the framework's raw
        /// "An unsupported language or locale was used".
        case backendUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noSnapshots: "No captured activity for that day."
            case .backendUnavailable(let reason): reason
            }
        }
    }

    static let perSnapshotLimit = 500
    /// Both default to Foundation Models' safe envelope. `generate(chunkLimit:)`
    /// overrides them together -- Ollama takes `ollamaChunkLimit`, which collapses
    /// a busy day in far fewer passes and so loses less to repeated summarising.
    static let chunkCharLimit = 1_800
    static let reduceCharLimit = 1_800
    /// Ollama's context is far larger than Foundation Models', so a day collapses
    /// in fewer passes. Same value as MeetingSummarizer.ollamaChunkLimit -- these
    /// two are the same trade-off and should not drift apart.
    static let ollamaChunkLimit = 12_000

    static let defaultBucketMinutes = 15
    static let defaultCap = 400

    /// One representative capture, plus the other window titles seen alongside
    /// it. Titles are the highest-signal content per character in a snapshot
    /// (file names, page titles), so they survive even when their bodies don't.
    nonisolated struct Selected: Equatable {
        let snapshot: MemorySnapshot
        let otherTitles: [String]
    }

    /// Pure: the day's snapshots -> the subset worth sending to a model.
    ///
    /// Measured on the real store 2026-08-01: 1,429 snapshots describe 117
    /// windows across 26 fifteen-minute buckets, and two apps account for 80%
    /// of them. Feeding all of it cost ~60 sequential model calls for one
    /// paragraph -- and the collapse loop then threw most of it away anyway.
    /// Reducing here does that discarding cheaply, and keeps the day's SHAPE
    /// (which apps, in what order) which is what a chronicle is for.
    static func select(
        _ snapshots: [MemorySnapshot],
        bucketMinutes: Int = defaultBucketMinutes,
        cap: Int = defaultCap
    ) -> [Selected] {
        guard !snapshots.isEmpty else { return [] }
        let parser = ISO8601DateFormatter()

        // Group by (bucket, app). A snapshot whose timestamp won't parse gets
        // its own bucket rather than being dropped -- losing a capture is worse
        // than keeping a redundant one.
        var groups: [String: [MemorySnapshot]] = [:]
        var groupOrder: [String] = []
        for snapshot in snapshots {
            let key: String
            if let date = parser.date(from: snapshot.lastSeenAt) {
                let bucket = Int(date.timeIntervalSince1970) / (bucketMinutes * 60)
                key = "\(bucket)|\(snapshot.appName)"
            } else {
                key = "unparsed|\(snapshot.lastSeenAt)|\(snapshot.appName)"
            }
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(snapshot)
        }

        var picked: [Selected] = []
        for key in groupOrder {
            guard let members = groups[key],
                  let best = members.max(by: { $0.content.count < $1.content.count })
            else { continue }
            let others = members
                .filter { $0.id != best.id && !$0.windowTitle.isEmpty && $0.windowTitle != best.windowTitle }
                .map(\.windowTitle)
            // Deduped, order-stable: several captures of one window are one title.
            var seen: Set<String> = []
            let otherTitles = others.filter { seen.insert($0).inserted }
            picked.append(Selected(snapshot: best, otherTitles: otherTitles))
        }

        picked.sort { $0.snapshot.lastSeenAt < $1.snapshot.lastSeenAt }
        guard picked.count > cap else { return picked }

        // Even stride, not a prefix: truncating would drop the whole later day.
        let step = Double(picked.count) / Double(cap)
        return (0..<cap).map { picked[min(picked.count - 1, Int(Double($0) * step))] }
    }

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

    /// Adds the other windows seen in this capture's (bucket, app) group. Their
    /// bodies were dropped by `select`; their titles are cheap and carry the
    /// most signal per character, so the chronicle still knows you were there.
    static func formatBlock(_ selected: Selected) -> String {
        let base = formatBlock(selected.snapshot)
        guard !selected.otherTitles.isEmpty else { return base }
        return base + "\n(also in \(selected.snapshot.appName): \(selected.otherTitles.joined(separator: ", ")))"
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
    static func generate(
        day: String, store: MemoryStore, polish: PolishBackend,
        chunkLimit: Int = chunkCharLimit,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> ChronicleResult {
        let snapshots = try store.snapshotsForDay(day)
        guard !snapshots.isEmpty else {
            throw ChroniclerError.noSnapshots
        }
        // Reduce BEFORE the model sees anything -- see select()'s note.
        let blocks = select(snapshots).map(formatBlock)
        let chunks = chunk(blocks, limit: chunkLimit)

        // +1 for the final reduce call, so progress ends at the total.
        let total = chunks.count + 1
        var done = 0

        var chunkSummaries: [String] = []
        for group in chunks {
            try Task.checkCancellation()
            onProgress?(done, total)
            let text = String(group.joined(separator: "\n\n").prefix(chunkLimit))
            let summary = try await polish.polish(text, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
            done += 1
        }

        // Collapse until the summaries fit one reduce call. A busy day produces
        // more chunk summaries than reduceCharLimit; the old code just did
        // `prefix(reduceCharLimit)` here, which silently DROPPED everything past
        // ~1,800 chars -- i.e. the whole afternoon/evening, since chunks are
        // day-ordered. Instead, re-chunk-and-summarize the summaries (a second
        // map-reduce level) until they fit, so late-day activity survives into
        // the final chronicle. The `count` guard prevents a non-converging loop
        // if a single summary is itself over the limit (degenerate; then the
        // final prefix below is the last-resort cap).
        while chunkSummaries.joined(separator: "\n").count > chunkLimit && chunkSummaries.count > 1 {
            var collapsed: [String] = []
            for group in chunk(chunkSummaries, limit: chunkLimit) {
                let text = String(group.joined(separator: "\n\n").prefix(chunkLimit))
                collapsed.append(try await polish.polish(text, style: chunkSummaryStyle, targetLanguage: nil))
            }
            if collapsed.count >= chunkSummaries.count { break }
            chunkSummaries = collapsed
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(chunkLimit))
        try Task.checkCancellation()
        onProgress?(done, total)
        let chronicle = try await polish.polish(reduceInput, style: chronicleWriteStyle, targetLanguage: nil)
        done += 1
        onProgress?(done, total)
        let trimmed = chronicle.trimmingCharacters(in: .whitespacesAndNewlines)

        try store.upsertChronicle(day: day, summary: trimmed, snapshotCount: snapshots.count)
        return ChronicleResult(day: day, summary: trimmed, snapshotCount: snapshots.count)
    }

    /// UTC date string. Snapshots are stored via `ISO8601DateFormatter()` (UTC)
    /// and queried with SQLite `date()` (also UTC), so "yesterday"/"today" here
    /// MUST be computed in UTC too -- the old `Calendar.current` (local) version
    /// disagreed with the store near midnight and for users far from UTC,
    /// chronicling the wrong day (or an empty one). Matches HistoryStore.homeStats,
    /// which was pinned to UTC for the same reason. Trade-off: the day boundary is
    /// UTC midnight, so a late evening can straddle two chronicles -- accepted for
    /// consistency with the store, which is the actual correctness fix.
    /// The user's LOCAL calendar day — "today" means their today, not UTC's.
    ///
    /// This was briefly pinned to UTC to match MemoryStore's `date(lastSeenAt)`,
    /// which reads the stored `…Z` timestamps as UTC. That fixed the mismatch from
    /// the wrong end: it moved the label instead of the query. East of UTC it made
    /// every chronicle span 05:30→05:30 local, and between midnight and 05:30 IST
    /// "today" resolved to yesterday's date over yesterday's snapshots.
    /// snapshotsForDay now compares in localtime, so the two agree on the user's day.
    static func dayString(daysAgo: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return formatter.string(from: date)
    }
}
