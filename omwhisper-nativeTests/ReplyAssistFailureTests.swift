import Testing
@testable import OmWhisper

@Suite("Reply Assist failures")
struct ReplyAssistFailureTests {
    private let all: [ReplyAssistFailure] = [
        .noTextField, .noBackend, .draftFailed("timed out"), .focusChanged, .sentinelDeclined
    ]

    @Test("every failure has a non-empty label")
    func everyFailureHasALabel() {
        // An empty label renders an invisible capsule — the exact silent
        // failure this whole change exists to remove.
        for failure in all {
            #expect(!failure.overlayLabel.isEmpty, "\(failure) has no label")
        }
    }

    @Test("labels are short enough for the capsule and match the house register")
    func labelsAreShortAndUppercase() {
        // The capsule is minWidth 180 at 11pt; long labels wrap or clip. The
        // existing labels are "NOTHING HEARD" and "SOMETHING BROKE — TEXT COPIED".
        for failure in all {
            #expect(failure.overlayLabel.count <= 24, "\(failure.overlayLabel) is too long")
            #expect(failure.overlayLabel == failure.overlayLabel.uppercased(),
                    "\(failure.overlayLabel) is not uppercase")
        }
    }

    @Test("each cause is distinguishable — the point of naming them")
    func labelsAreDistinct() {
        // One shared "SOMETHING WENT WRONG" would pass the tests above while
        // leaving the user unable to tell a missing field from a dead backend.
        let labels = all.map(\.overlayLabel)
        #expect(Set(labels).count == labels.count)
    }

    @Test("the underlying error text is carried in the message, not the label")
    func draftFailedCarriesItsReason() {
        // The label stays short; the detail belongs in errorMessage, which will
        // be useful the day that channel is connected.
        #expect(ReplyAssistFailure.draftFailed("Ollama timed out").message.contains("Ollama timed out"))
        #expect(!ReplyAssistFailure.draftFailed("Ollama timed out").overlayLabel.contains("Ollama"))
    }
}
