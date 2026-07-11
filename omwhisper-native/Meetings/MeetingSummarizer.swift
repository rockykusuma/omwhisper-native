//
//  MeetingSummarizer.swift
//  OmWhisper
//
//  Map-reduce meeting summary through a PolishBackend, mirroring Chronicler's
//  approach for the same reason: SystemLLM's polish() has a ~2,000-char/5s
//  envelope, and a meeting transcript regularly exceeds that. Words are greedily
//  packed into <=chunkCharLimit groups (no content lost even for one long line),
//  each summarized (map), then one reduce call writes the final markdown summary
//  + action items. AppState always passes systemLLM (on-device). The two styles
//  are fixed-UUID and internal -- never added to PolishStyles.builtIns, same
//  hidden-style pattern as Chronicler.
//

import Foundation

nonisolated enum MeetingSummarizer {
    static let chunkCharLimit = 1_800
    static let reduceCharLimit = 1_800

    static let chunkSummaryStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000001")!,
        name: "Meeting Chunk Summary",
        prompt: """
            Summarize this portion of a meeting transcript into 2-5 terse bullet \
            points of what was said/decided. The transcript labels speakers as \
            **You:** and **Others:** — preserve who said what. No preamble, just bullets.
            """,
        isBuiltIn: true
    )

    static let meetingWriteStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000002")!,
        name: "Meeting Summary",
        prompt: """
            You are writing a private summary of a meeting from bullet-point notes \
            (speakers labeled You/Others). Write concise markdown with:
            ## Summary — 2-4 sentences on what the meeting was about and any decisions.
            ## Action items — a bullet list of concrete follow-ups (who owns each, if \
            clear). Omit this section entirely if there were none.
            Rules: be specific, no filler, no speculation beyond the notes.
            """,
        isBuiltIn: true
    )

    /// Pure: greedily pack words into <=limit-char groups so no content is lost
    /// even for a single long line. A single word longer than limit forms its
    /// own (oversized) group rather than being split.
    static func chunk(_ text: String, limit: Int = chunkCharLimit) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var groups: [String] = []
        var current = ""
        for word in words {
            let added = word.count + (current.isEmpty ? 0 : 1)
            if !current.isEmpty && current.count + added > limit {
                groups.append(current)
                current = word
            } else {
                current = current.isEmpty ? word : current + " " + word
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Effectful: map each chunk → chunk-summary, reduce → markdown summary.
    /// Returns "" for an empty transcript. Propagates the first polish() failure.
    static func generate(transcript: String, polish: PolishBackend) async throws -> String {
        let chunks = chunk(transcript)
        guard !chunks.isEmpty else { return "" }

        var chunkSummaries: [String] = []
        for group in chunks {
            let summary = try await polish.polish(group, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(reduceCharLimit))
        let out = try await polish.polish(reduceInput, style: meetingWriteStyle, targetLanguage: nil)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
