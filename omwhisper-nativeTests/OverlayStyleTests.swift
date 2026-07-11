import Testing
@testable import OmWhisper

struct OverlayStyleTests {
    @Test func allCasesInOrder() {
        #expect(OverlayStyle.allCases == [.full, .orb, .whisperLine])
    }

    @Test func titles() {
        #expect(OverlayStyle.full.title == "Full")
        #expect(OverlayStyle.orb.title == "Orb")
        #expect(OverlayStyle.whisperLine.title == "Whisper line")
    }

    @Test func captionsAreNonEmptyAndDistinct() {
        let captions = OverlayStyle.allCases.map(\.caption)
        #expect(captions.allSatisfy { !$0.isEmpty })
        #expect(Set(captions).count == captions.count)
    }

    @Test func rawValueRoundTrips() {
        #expect(OverlayStyle(rawValue: "orb") == .orb)
        #expect(OverlayStyle(rawValue: "bogus") == nil)
    }
}
