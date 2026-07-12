//
//  BrainDumpStructurer.swift
//  OmWhisper
//
//  Map-reduce a spoken brain-dump into a structured artifact, mirroring
//  MeetingSummarizer for the same reason: a multi-minute ramble far exceeds
//  SystemLLM's ~2,000-char/5s envelope. Short rambles (one chunk) skip the map
//  and apply the shape prompt directly. Effectful structure() propagates the
//  first polish() failure to the caller, which falls back to the raw ramble.
//

import Foundation

nonisolated enum BrainDumpStructurer {
    static let chunkCharLimit = 1_800
    static let reduceCharLimit = 1_800

    /// Pure: greedily pack words into <=limit-char groups (verbatim from
    /// MeetingSummarizer.chunk — no content lost even for one long line).
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

    /// Map (long only) → reduce into `shape`. `context` (target app + screen terms)
    /// is appended to the reduce input. Returns "" for empty input.
    static func structure(transcript: String, shape: PolishStyle,
                          context: String?, polish: PolishBackend) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let chunks = chunk(trimmed)
        let material: String
        if chunks.count <= 1 {
            material = trimmed
        } else {
            var notes: [String] = []
            for group in chunks {
                notes.append(try await polish.polish(group, style: BrainDumpShapes.chunkNotesStyle, targetLanguage: nil))
            }
            material = String(notes.joined(separator: "\n").prefix(reduceCharLimit))
        }

        let input = context.map { "\(material)\n\n[Context: \($0)]" } ?? material
        let out = try await polish.polish(input, style: shape, targetLanguage: nil)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
