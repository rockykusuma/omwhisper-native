import Testing
@testable import OmWhisper

struct MeetingTranscriberTests {
    @Test func labelsBothTracks() {
        let out = MeetingTranscriber.labeledTranscript(you: "hello", others: "hi there")
        #expect(out == "**You:**\nhello\n\n**Others:**\nhi there")
    }

    @Test func omitsEmptyTrack() {
        #expect(MeetingTranscriber.labeledTranscript(you: "hello", others: "  ") == "**You:**\nhello")
        #expect(MeetingTranscriber.labeledTranscript(you: "", others: "hi") == "**Others:**\nhi")
    }

    @Test func bothEmptyGivesEmpty() {
        #expect(MeetingTranscriber.labeledTranscript(you: " ", others: "") == "")
    }
}
