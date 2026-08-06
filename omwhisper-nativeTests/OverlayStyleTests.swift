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

@Suite("Overlay visibility")
struct OverlayVisibilityTests {
    @Test("an error is visible with no dictation running — the bug")
    func errorVisibleWhenIdle() {
        // Reply Assist runs entirely at .idle. The old rule admitted .polishing
        // but not .error, so every Reply Assist failure rendered nothing at all
        // and the user could not tell "working" from "failed".
        #expect(OverlayView.isVisible(dictation: .idle,
                                      phase: .error(label: "NO TEXT FIELD"),
                                      isPreview: false))
    }

    @Test("a draft in flight is visible with no dictation running")
    func draftingVisibleWhenIdle() {
        #expect(OverlayView.isVisible(dictation: .idle, phase: .drafting, isPreview: false))
    }

    @Test("idle with nothing happening stays hidden")
    func idleStaysHidden() {
        // Guards against "fixing" the above by making the HUD permanent.
        #expect(!OverlayView.isVisible(dictation: .idle, phase: .none, isPreview: false))
    }

    @Test("polishing and a live dictation are unchanged")
    func existingCasesUnchanged() {
        #expect(OverlayView.isVisible(dictation: .idle, phase: .polishing, isPreview: false))
        for state in [DictationState.starting, .recording, .finalizing] {
            #expect(OverlayView.isVisible(dictation: state, phase: .none, isPreview: false),
                    "\(state) should show the HUD")
        }
    }

    @Test("a settings preview is always visible")
    func previewAlwaysVisible() {
        // Matches showsTranscript's existing contract.
        #expect(OverlayView.isVisible(dictation: .idle, phase: .none, isPreview: true))
    }

    @Test("a draft shows no transcript — those fields hold the LAST dictation")
    func draftingHidesStaleTranscript() {
        // Same reason Polish Selected suppresses it: dictation stays .idle, so
        // finalizedTranscript still holds whatever was dictated before. Without
        // this the DRAFTING HUD displays the previous dictation's words.
        #expect(!OverlayView.showsTranscript(dictation: .idle, phase: .drafting, isPreview: false))
    }
}
