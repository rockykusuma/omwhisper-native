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

@Suite("Overlay transcript visibility")
struct OverlayTranscriptVisibilityTests {
    @Test("Polish Selected shows no transcript — those fields hold the LAST dictation")
    func hidesStaleTranscriptDuringPolishSelected() {
        // dictation stays .idle throughout Polish Selected by design, so
        // finalizedTranscript still holds whatever was dictated before it.
        #expect(!OverlayView.showsTranscript(dictation: .idle, phase: .polishing, isPreview: false))
    }

    @Test("the settings preview still shows its demo text")
    func previewKeepsItsTranscript() {
        // The preview runs at .idle and fills the transcript deliberately —
        // a bare "hide when idle" rule would silently empty it.
        #expect(OverlayView.showsTranscript(dictation: .idle, phase: .polishing, isPreview: true))
    }

    @Test("a real dictation always shows its transcript")
    func dictationAlwaysShows() {
        for state in [DictationState.starting, .recording] {
            #expect(OverlayView.showsTranscript(dictation: state, phase: .polishing, isPreview: false),
                    "hid the transcript during \(state)")
        }
    }
}
