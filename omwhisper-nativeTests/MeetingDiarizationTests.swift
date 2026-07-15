import Testing
@testable import OmWhisper

struct MeetingDiarizationTests {
    typealias D = MeetingDiarization

    // MARK: dropEchoed — speaker bleed into the mic track

    /// The real failure this was written for: both tracks transcribed the same
    /// sentence (laptop speakers -> mic), so it appeared twice — once as "You".
    /// Texts are the actual pair from the 2026-07-15 recording.
    @Test func dropsEchoOfTheSameSentenceOnBothTracks() {
        let you = [TranscriptSegment(
            text: "AI is coming and just like the industrial revolution", start: 0.0, end: 3.44, speaker: "You"
        )]
        let others = [TranscriptSegment(
            text: "AI is coming and just like the industrial revolution", start: 0.0, end: 3.50, speaker: "1"
        )]
        #expect(D.dropEchoed(you: you, others: others).isEmpty)
    }

    /// Independent transcription of the same audio yields different word errors
    /// ("For the Internet" vs "or the internet") — echo detection must survive that.
    @Test func dropsEchoDespiteDifferingTranscriptionErrors() {
        let you = [TranscriptSegment(
            text: "For the Internet it is definitely going to change a lot of things", start: 17.24, end: 21.0, speaker: "You"
        )]
        let others = [TranscriptSegment(
            text: "or the internet, it is definitely going to change a lot of things", start: 17.22, end: 20.98, speaker: "1"
        )]
        #expect(D.dropEchoed(you: you, others: others).isEmpty)
    }

    /// The whole point: the user's own speech is never on the system track, so it
    /// must survive even while echo around it is dropped.
    @Test func keepsRealSpeechThatIsNotOnTheSystemTrack() {
        let you = [
            TranscriptSegment(text: "AI is coming and just like the industrial revolution", start: 0.0, end: 3.44, speaker: "You"),
            TranscriptSegment(text: "I think I'm watching a YouTube video", start: 3.44, end: 9.2, speaker: "You"),
        ]
        let others = [TranscriptSegment(
            text: "AI is coming and just like the industrial revolution", start: 0.0, end: 3.50, speaker: "1"
        )]
        let kept = D.dropEchoed(you: you, others: others)
        #expect(kept.map(\.text) == ["I think I'm watching a YouTube video"])
    }

    /// Same words at a disjoint time are a genuine echo of nothing — someone
    /// repeating a phrase later is their own speech, not bleed.
    @Test func keepsMatchingTextWhenTimesDoNotOverlap() {
        let you = [TranscriptSegment(text: "sounds good to me", start: 30.0, end: 32.0, speaker: "You")]
        let others = [TranscriptSegment(text: "sounds good to me", start: 0.0, end: 2.0, speaker: "1")]
        #expect(D.dropEchoed(you: you, others: others).count == 1)
    }

    /// Headphones: nothing bleeds, so nothing is ever dropped.
    @Test func keepsEverythingWhenNothingMatches() {
        let you = [TranscriptSegment(text: "what do you think about the deadline", start: 0.0, end: 3.0, speaker: "You")]
        let others = [TranscriptSegment(text: "the quarterly numbers came in strong", start: 0.0, end: 3.0, speaker: "1")]
        #expect(D.dropEchoed(you: you, others: others).count == 1)
    }

    @Test func similarityIsOneForIdenticalAndZeroForEmpty() {
        #expect(D.similarity("Hello there", "hello, there!") == 1.0)
        #expect(D.similarity("", "anything") == 0)
    }

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
