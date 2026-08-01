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

    /// Ollama takes ~10x bigger chunks than SystemLLM's 1,800-char envelope --
    /// an hour-long call goes from ~40 lossy chunks to ~6, which is the whole
    /// point of routing meeting summaries through it. Fits its 30s timeout.
    /// ponytail: tune only if live testing shows timeouts.
    static let ollamaChunkLimit = 12_000

    static let chunkSummaryStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000001")!,
        name: "Meeting Chunk Summary",
        prompt: """
            Summarize this portion of a meeting transcript into 2-5 terse bullet \
            points of what was said/decided. Speakers are labelled **You:** (the \
            person who recorded the meeting) and **Speaker 1:**, **Speaker 2:**, … \
            (the other participants). Preserve who said what, and attribute a point \
            to the recorder ONLY when it appears under a **You:** label — the word \
            "you" inside another speaker's line refers to whoever they were \
            addressing, not the recorder. No preamble, just bullets.
            """,
        isBuiltIn: true
    )

    /// Shared by every template. The "never on the heading line" rule is not
    /// cosmetic: the old prompt's own "## Summary — 2-4 sentences" example
    /// taught the model to write the body on the heading line, which the
    /// section parser read as one giant title and then dropped as empty —
    /// a real 422-char summary rendered as a blank card (fixed 2026-08-01).
    private static let sharedRules = """
        "You" in the notes means the person who recorded the meeting; \
        "Speaker 1", "Speaker 2", … (or their real names) are the other \
        participants. Never credit the recorder with a plan, opinion or \
        commitment another speaker voiced — if a note doesn't say the recorder \
        said it, they didn't. Never put content on the same line as a "## " \
        heading: headings sit alone, bodies start on the next line. Be \
        specific, no filler, no speculation beyond the notes. Omit any section \
        with nothing real to say.
        """

    static let meetingWriteStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000002")!,
        name: "Standard",
        prompt: """
            You are writing a private summary of a meeting from bullet-point notes. \
            Write concise markdown with a "## Summary" heading followed by 2-4 \
            sentences on what the meeting was about and any decisions, then an \
            "## Action items" heading followed by a bullet list of concrete \
            follow-ups (who owns each, if clear). \(sharedRules)
            """,
        isBuiltIn: true
    )

    // MARK: Templates — only the reduce-stage prompt varies; the map (chunk)
    // stage is shared. Fixed UUIDs (…0003-0006) so a stored default survives
    // relaunches, same hidden-style pattern as Chronicler/Reply Assist. These
    // are never added to PolishStyles.builtIns (the dictation-style picker).

    static let standupTemplate = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000003")!,
        name: "Standup",
        prompt: """
            You are writing private standup notes from bullet-point meeting notes. \
            Write concise markdown under these headings: "## Updates" (one bullet \
            per person — what they did or are doing), "## Blockers" (who is blocked \
            and on what), "## Action items" (concrete follow-ups with owners). \
            \(sharedRules)
            """,
        isBuiltIn: true
    )

    static let clientCallTemplate = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000004")!,
        name: "Client call",
        prompt: """
            You are writing private notes on a client call from bullet-point meeting \
            notes. Write concise markdown under these headings: "## Summary" (what \
            the call was about), "## Client needs" (what they asked for, worried \
            about, or objected to), "## Commitments" (what was promised, by whom, by \
            when), "## Next steps". \(sharedRules)
            """,
        isBuiltIn: true
    )

    static let oneOnOneTemplate = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000005")!,
        name: "1:1",
        prompt: """
            You are writing private notes on a one-on-one conversation from \
            bullet-point meeting notes. Write concise markdown under these headings: \
            "## Topics" (what was discussed), "## Feedback" (given or received, \
            attributed correctly), "## Action items" (who follows up on what). \
            \(sharedRules)
            """,
        isBuiltIn: true
    )

    static let interviewTemplate = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000006")!,
        name: "Interview",
        prompt: """
            You are writing private interview notes from bullet-point meeting notes. \
            Write concise markdown under these headings: "## Candidate" (role and \
            background as discussed), "## Strengths" (with the evidence mentioned), \
            "## Concerns" (gaps or doubts raised), "## Next steps". \(sharedRules)
            """,
        isBuiltIn: true
    )

    // MARK: Hidden styles — machinery, never user-selectable templates, so
    // deliberately absent from builtInTemplates (a test pins that).

    static let questionExtractStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000010")!,
        name: "Meeting Question Extract",
        prompt: """
            From the meeting transcript below, extract ONLY the lines and facts \
            relevant to the question given above it. Copy who said what. If \
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

    /// Standard first — it's the default, and the UI lists them in this order.
    static let builtInTemplates: [PolishStyle] = [
        meetingWriteStyle, standupTemplate, clientCallTemplate, oneOnOneTemplate, interviewTemplate,
    ]

    /// Resolve a stored template choice. nil or unknown (a deleted custom
    /// template) falls back to Standard rather than failing the summary.
    static func template(id: UUID?, custom: [PolishStyle]) -> PolishStyle {
        guard let id else { return meetingWriteStyle }
        return builtInTemplates.first { $0.id == id }
            ?? custom.first { $0.id == id }
            ?? meetingWriteStyle
    }

    /// One-shot Q&A over a transcript: map each chunk to whatever is relevant to
    /// the question, then answer from those extracts. Same map-reduce shape and
    /// per-backend chunk sizing as generate(). No conversation state is kept —
    /// anything more conversational belongs in an MCP client with a real model
    /// behind it (see the SP3 spec).
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

    /// Effectful: map each chunk → chunk-summary, reduce → markdown summary
    /// shaped by `template`. Returns "" for an empty transcript. Propagates the
    /// first polish() failure.
    static func generate(
        transcript: String,
        polish: PolishBackend,
        template: PolishStyle = meetingWriteStyle,
        chunkLimit: Int = chunkCharLimit
    ) async throws -> String {
        let chunks = chunk(transcript, limit: chunkLimit)
        guard !chunks.isEmpty else { return "" }

        var chunkSummaries: [String] = []
        for group in chunks {
            let summary = try await polish.polish(group, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
        }

        // Collapse until the summaries fit one reduce call. A long meeting
        // produces more chunk summaries than the limit, and this used to be a
        // bare `prefix(limit)` — which silently DROPPED everything past it,
        // i.e. the back half of the meeting, since chunks are time-ordered.
        // Re-summarize the summaries (a second map-reduce level) instead, so
        // the ending survives into the final write. Same fix Chronicler already
        // carries for the same reason. The count guard prevents a non-
        // converging loop when a single summary exceeds the limit on its own;
        // the prefix below is then the last-resort cap.
        while chunkSummaries.joined(separator: "\n").count > chunkLimit && chunkSummaries.count > 1 {
            let groups = chunk(chunkSummaries.joined(separator: "\n"), limit: chunkLimit)
            guard groups.count < chunkSummaries.count else { break }
            var collapsed: [String] = []
            for group in groups {
                collapsed.append(try await polish.polish(group, style: chunkSummaryStyle, targetLanguage: nil))
            }
            chunkSummaries = collapsed
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(chunkLimit))
        let out = try await polish.polish(reduceInput, style: template, targetLanguage: nil)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
