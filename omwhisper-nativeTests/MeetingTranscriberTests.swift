import Foundation
import Testing
@testable import OmWhisper

struct MeetingTranscriberTests {
    @Test func labelsBothTracks() {
        let out = MeetingTranscriber.labeledTranscript(you: "hello", others: "hi there")
        #expect(out == "**You:**\nhello\n\n**Others:**\nhi there")
    }

    /// The behaviour the "don't record my microphone" feature leans on: a
    /// meeting recorded with no me.caf must transcribe as others-only rather
    /// than throwing. transcribeFile's guard returns before the engine is
    /// touched, which is why passing a real engine here costs nothing.
    @Test func missingTrackTranscribesToEmpty() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-track-\(UUID().uuidString).caf")
        let text = try await MeetingTranscriber.transcribeFile(missing, engine: AppleEngine())
        #expect(text.isEmpty)
    }

    @Test func omitsEmptyTrack() {
        #expect(MeetingTranscriber.labeledTranscript(you: "hello", others: "  ") == "**You:**\nhello")
        #expect(MeetingTranscriber.labeledTranscript(you: "", others: "hi") == "**Others:**\nhi")
    }

    @Test func bothEmptyGivesEmpty() {
        #expect(MeetingTranscriber.labeledTranscript(you: " ", others: "") == "")
    }
}
