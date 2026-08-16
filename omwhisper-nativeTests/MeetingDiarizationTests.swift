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
        // Each label carries the turn's start time — AppMarkdown.turns(from:)
        // parses it back out for the transcript UI.
        #expect(D.renderInterleaved(turns) == "**You:** [0:00]\nhello there\n\n**Speaker 1:** [0:02]\nhi")
    }

    @Test func applySpeakerNamesSubstitutesLabelsOnly() {
        let transcript = "**Speaker 1:** [0:03]\nhello **You:** [0:05]\nSpeaker 1 said hi to Speaker 10"
        let out = D.applySpeakerNames(transcript, names: ["Speaker 1": "Alice"])
        // Label replaced; body-text "Speaker 1" and the distinct "Speaker 10" untouched.
        #expect(out.contains("**Alice:** [0:03]"))
        #expect(out.contains("Speaker 1 said hi to Speaker 10"))
    }

    @Test func applySpeakerNamesNeverRemapsYou() {
        let transcript = "**You:** [0:01]\nhi"
        let out = D.applySpeakerNames(transcript, names: ["You": "Bob"])
        #expect(out == transcript)
    }

    @Test func applySpeakerNamesSkipsEmptyAndUnknown() {
        let transcript = "**Speaker 1:** [0:03]\nhello\n\n**Speaker 2:** [0:09]\nyes"
        let out = D.applySpeakerNames(
            transcript, names: ["Speaker 1": "   ", "Speaker 3": "Ghost"])
        #expect(out == transcript)  // blank name skipped; Speaker 3 not present
    }

    @Test func speakerTenNotClobberedBySpeakerOne() {
        let transcript = "**Speaker 10:** [0:03]\nhello"
        let out = D.applySpeakerNames(transcript, names: ["Speaker 1": "Alice"])
        #expect(out == transcript)  // "**Speaker 1:**" ≠ "**Speaker 10:**" — colon guards it
    }

    @Test("removingYouTurns drops You blocks from a diarized transcript")
    func removesYouFromDiarized() {
        let input = """
        **You:** [0:00]
        Let me put myself on mute.

        **Speaker 1:** [0:04]
        We shipped the release on Tuesday.

        **You:** [0:09]
        Did you see the game last night?

        **Speaker 2:** [0:12]
        The rollout looked clean.
        """
        #expect(D.removingYouTurns(input) == """
        **Speaker 1:** [0:04]
        We shipped the release on Tuesday.

        **Speaker 2:** [0:12]
        The rollout looked clean.
        """)
    }

    @Test("removingYouTurns handles the legacy You/Others transcript")
    func removesYouFromLegacy() {
        let input = "**You:**\nmy side\n\n**Others:**\ntheir side"
        #expect(D.removingYouTurns(input) == "**Others:**\ntheir side")
    }

    @Test("a body line that mentions You is never removed")
    func bodyMentionsAreSafe() {
        // The failure this exists for: a contains("You") filter would delete
        // Speaker 1 entirely — someone else's sentence, silently — and every
        // store-level assertion would still pass.
        let input = """
        **Speaker 1:** [0:02]
        You mentioned the deadline, and **You:** was in my notes too.

        **You:** [0:08]
        that was my aside
        """
        let out = D.removingYouTurns(input)
        #expect(out.contains("You mentioned the deadline"))
        #expect(out.contains("**Speaker 1:**"))
        #expect(!out.contains("that was my aside"))
    }

    @Test("a transcript with no You turns is returned unchanged")
    func noYouTurnsIsUnchanged() {
        let input = "**Speaker 1:** [0:00]\nhello\n\n**Speaker 2:** [0:03]\nhi"
        #expect(D.removingYouTurns(input) == input)
    }

    @Test("a transcript of only You turns becomes empty")
    func onlyYouTurnsBecomesEmpty() {
        #expect(D.removingYouTurns("**You:** [0:00]\nall mine").isEmpty)
    }

    @Test("renamed speakers are not mistaken for You")
    func renamedSpeakersSurvive() {
        // applySpeakerNames rewrites labels at read time, but the STORED
        // transcript keeps generic labels. A meeting where someone is actually
        // named "Young" must not lose their turns to a prefix match.
        let input = "**Young:** [0:00]\nkeep me\n\n**You:** [0:04]\ndrop me"
        #expect(D.removingYouTurns(input) == "**Young:** [0:00]\nkeep me")
    }
}
