import Testing
@testable import OmWhisper

struct AppMarkdownTests {
    typealias M = AppMarkdown

    // MARK: timecode

    @Test func timecodeFormatsMinutesAndHours() {
        #expect(M.timecode(0) == "0:00")
        #expect(M.timecode(3.4) == "0:03")
        #expect(M.timecode(65) == "1:05")
        #expect(M.timecode(3753) == "1:02:33")
        #expect(M.timecode(-5) == "0:00")
    }

    // MARK: turns — the inverse of renderInterleaved

    @Test func parsesSpeakerTurnsWithTimecodes() {
        let markdown = """
            **You:** [0:00]
            I think I'm watching a YouTube video

            **Speaker 1:** [0:08]
            This looks like Formula One.
            """
        let turns = M.turns(from: markdown)
        #expect(turns.count == 2)
        #expect(turns[0].speaker == "You")
        #expect(turns[0].timecode == "0:00")
        #expect(turns[0].text == "I think I'm watching a YouTube video")
        #expect(turns[0].isYou)
        #expect(turns[1].speaker == "Speaker 1")
        #expect(turns[1].timecode == "0:08")
        #expect(!turns[1].isYou)
    }

    /// Transcripts written before timecodes existed, and the non-diarized
    /// You/Others fallback, must still render — just without times.
    @Test func parsesLegacyTurnsWithoutTimecodes() {
        let markdown = """
            **You:**
            hello there

            **Others:**
            general kenobi
            """
        let turns = M.turns(from: markdown)
        #expect(turns.map(\.speaker) == ["You", "Others"])
        #expect(turns.allSatisfy { $0.timecode == nil })
        #expect(turns[1].text == "general kenobi")
    }

    @Test func keepsMultiLineTurnTextTogether() {
        let turns = M.turns(from: "**You:** [0:01]\nfirst line\nsecond line")
        #expect(turns.count == 1)
        #expect(turns[0].text == "first line\nsecond line")
    }

    /// The no-audio permission note has no speaker labels at all — the caller
    /// falls back to plain text rather than showing an empty transcript.
    @Test func unlabelledTextYieldsNoTurns() {
        #expect(M.turns(from: "⚠️ No audio was captured for this recording.").isEmpty)
        #expect(M.turns(from: "").isEmpty)
    }

    @Test func labelWithNoBodyIsDropped() {
        #expect(M.turns(from: "**You:** [0:00]\n\n**Speaker 1:** [0:02]\nreal text").count == 1)
    }

    // MARK: summary sections

    /// SwiftUI's markdown renders no headings, so "## Summary —" was showing up
    /// literally in the UI. The view draws its own eyebrows from these.
    @Test func splitsSummaryOnHeadingsAndTidiesTitles() {
        let markdown = """
            ## Summary —
            The team discussed the release.

            ## Action items —
            * Ship the build
            * Email the notes
            """
        let sections = M.sections(from: markdown)
        #expect(sections.count == 2)
        #expect(sections[0].title == "Summary")
        #expect(sections[0].lines == ["The team discussed the release."])
        #expect(sections[1].title == "Action items")
        #expect(sections[1].lines.count == 2)
    }

    @Test func summaryWithoutHeadingsStillRenders() {
        let sections = M.sections(from: "Just a plain summary.")
        #expect(sections.count == 1)
        #expect(sections[0].title == nil)
        #expect(sections[0].lines == ["Just a plain summary."])
    }

    /// The live-caught empty-summary-card bug: the model wrote the body on the
    /// SAME line as the heading ("## Summary — text…" — our own prompt's
    /// template reads that way), the whole paragraph became the section title,
    /// lines stayed empty, and the empty-section filter dropped everything —
    /// a real 422-char summary rendered as a blank white card.
    @Test func headingWithBodyOnSameLineKeepsTheBody() {
        let markdown = """
            ## Summary — The team discussed the release and agreed to ship.
            ## Action Items — None.
            """
        let sections = M.sections(from: markdown)
        #expect(sections.count == 2)
        #expect(sections[0].title == "Summary")
        #expect(sections[0].lines == ["The team discussed the release and agreed to ship."])
        #expect(sections[1].title == "Action Items")
        #expect(sections[1].lines == ["None."])
    }

    @Test func bulletBodyStripsMarkersOnly() {
        #expect(M.bulletBody("* Ship the build") == "Ship the build")
        #expect(M.bulletBody("- Ship the build") == "Ship the build")
        #expect(M.bulletBody("Not a bullet") == nil)
    }

    // MARK: round-trip

    /// The renderer and parser must stay in step — this fails if either changes
    /// format alone.
    @Test func renderInterleavedRoundTripsThroughTurns() {
        let segments = [
            TranscriptSegment(text: "hello there", start: 0, end: 3, speaker: "You"),
            TranscriptSegment(text: "general kenobi", start: 65, end: 70, speaker: "Speaker 1"),
        ]
        let turns = M.turns(from: MeetingDiarization.renderInterleaved(segments))
        #expect(turns.map(\.speaker) == ["You", "Speaker 1"])
        #expect(turns.map(\.timecode) == ["0:00", "1:05"])
        #expect(turns.map(\.text) == ["hello there", "general kenobi"])
    }
}
