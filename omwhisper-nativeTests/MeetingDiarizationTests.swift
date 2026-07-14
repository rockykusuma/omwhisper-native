import Testing
@testable import OmWhisper

struct MeetingDiarizationTests {
    typealias D = MeetingDiarization

    @Test func alignPicksMostOverlappingSpeaker() {
        let texts = [(text: "x", start: 2.0, end: 3.0)]
        let speakers = [(id: "A", start: 0.0, end: 1.0), (id: "B", start: 1.0, end: 5.0)]
        #expect(D.alignSpeakers(texts: texts, speakers: speakers).first?.speaker == "B")
    }

    @Test func alignFallsBackToNearestWhenNoOverlap() {
        let texts = [(text: "y", start: 10.0, end: 11.0)]
        let speakers = [(id: "A", start: 0.0, end: 1.0), (id: "B", start: 8.0, end: 9.0)]
        #expect(D.alignSpeakers(texts: texts, speakers: speakers).first?.speaker == "B")
    }

    @Test func relabelMapsOthersToSpeakerNByFirstAppearance() {
        let segs = [
            TranscriptSegment(text: "a", start: 0, end: 1, speaker: "You"),
            TranscriptSegment(text: "b", start: 1, end: 2, speaker: "xyz"),
            TranscriptSegment(text: "c", start: 2, end: 3, speaker: "abc"),
            TranscriptSegment(text: "d", start: 3, end: 4, speaker: "xyz"),
        ]
        #expect(D.relabelOthers(segs).map(\.speaker) == ["You", "Speaker 1", "Speaker 2", "Speaker 1"])
    }

    @Test func mergeSortsByStart() {
        let segs = [
            TranscriptSegment(text: "late", start: 5, end: 6, speaker: "You"),
            TranscriptSegment(text: "early", start: 1, end: 2, speaker: "Speaker 1"),
        ]
        #expect(D.mergeByTime(segs).map(\.text) == ["early", "late"])
    }

    @Test func collapseFoldsConsecutiveSameSpeaker() {
        let segs = [
            TranscriptSegment(text: "one", start: 0, end: 1, speaker: "You"),
            TranscriptSegment(text: "two", start: 1, end: 2, speaker: "You"),
            TranscriptSegment(text: "hi", start: 2, end: 3, speaker: "Speaker 1"),
        ]
        let c = D.collapseTurns(segs)
        #expect(c.count == 2)
        #expect(c.first?.text == "one two")
        #expect(c.first?.end == 2)
    }

    @Test func renderProducesMarkdownHeadings() {
        let turns = [
            TranscriptSegment(text: "hello there", start: 0, end: 2, speaker: "You"),
            TranscriptSegment(text: "hi", start: 2, end: 3, speaker: "Speaker 1"),
        ]
        #expect(D.renderInterleaved(turns) == "**You:**\nhello there\n\n**Speaker 1:**\nhi")
    }
}
