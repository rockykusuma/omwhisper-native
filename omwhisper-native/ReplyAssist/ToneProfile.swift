//
//  ToneProfile.swift
//  OmWhisper
//
//  Distills a writing-tone style guide (tone.md) from this app's own dictation
//  history -- NOT from continuous screen captures the way smriti's
//  ToneProfile.swift does. That capture mechanism belongs to S1 (memory
//  capture), which ships AFTER S4 in this project's build order; HistoryStore
//  is a better fit besides, since it's literally the user's own past written
//  words rather than a general screen scrape.
//
//  Pure digest/prompt-shaping helpers here are unit-tested directly; the
//  actual distillation call (HistoryStore read + PolishBackend call + file
//  write) is orchestrated by AppState in Task 6, since it needs live
//  collaborators this type deliberately doesn't own.
//

import Foundation

nonisolated enum ToneProfile {
    static let sampleCap = 120
    static let digestCharCap = 90_000
    static let promptPrefixCap = 1_500

    static let distillationPrompt = """
        You analyze a person's past written text and distill their writing tone \
        into a concise style guide for drafting replies in their voice.

        Write RULES, not observations -- e.g. "Use short sentences, no filler \
        words" not "The user tends to write short sentences." At most 20 lines \
        of markdown.
        """

    static func toneFileURL() throws -> URL {
        // Shared bundle-ID-aware root, not an inline lookup — keeps the dev
        // build's tone.md out of the installed app's data directory.
        guard let root = AppSupportDirectory.resolve() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent("tone.md")
    }

    /// Concatenates up to `sampleCap` entries' text (newline-joined), capped
    /// overall at `digestCharCap` characters so the distillation prompt stays
    /// bounded regardless of history size. Entries are consumed in the order
    /// given -- callers pass already-most-recent-first entries.
    static func buildDigest(from entries: [TranscriptionEntry]) -> String {
        var digest = ""
        for entry in entries.prefix(sampleCap) {
            let line = entry.text + "\n"
            guard digest.count + line.count <= digestCharCap else { break }
            digest += line
        }
        return digest
    }

    /// Truncates a stored tone.md to a prompt-safe prefix for use in a draft
    /// prompt -- the file on disk may be longer (or user-edited longer) than
    /// what's safe to include verbatim in every draft call.
    static func promptPrefix(from toneMarkdown: String) -> String {
        String(toneMarkdown.prefix(promptPrefixCap))
    }
}
