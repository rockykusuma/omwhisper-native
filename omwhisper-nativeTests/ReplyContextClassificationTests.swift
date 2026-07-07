import Testing
@testable import OmWhisper

@Suite("ReplyContextReader.classify")
struct ReplyContextClassificationTests {
    @Test("empty field with no placeholder -> reply")
    func emptyNoPlaceholder() {
        #expect(ReplyContextReader.classify(value: nil, placeholder: nil, selection: nil) == .reply)
        #expect(ReplyContextReader.classify(value: "", placeholder: nil, selection: nil) == .reply)
    }

    @Test("empty field whose AX value mirrors its placeholder -> reply, not continueDraft")
    func placeholderMistakenForValue() {
        let mode = ReplyContextReader.classify(value: "Type a message...", placeholder: "Type a message...", selection: nil)
        #expect(mode == .reply)
    }

    @Test("non-empty draft with a different placeholder -> continueDraft")
    func realDraft() {
        let mode = ReplyContextReader.classify(value: "Hey, just wanted to say", placeholder: "Type a message...", selection: nil)
        #expect(mode == .continueDraft("Hey, just wanted to say"))
    }

    @Test("selection over 3 chars -> rewrite, even with a non-empty draft present")
    func selectionWins() {
        let mode = ReplyContextReader.classify(value: "some draft text", placeholder: nil, selection: "please rewrite this part")
        #expect(mode == .rewrite("please rewrite this part"))
    }

    @Test("selection of 3 chars or fewer does not trigger rewrite")
    func tinySelectionIgnored() {
        let mode = ReplyContextReader.classify(value: nil, placeholder: nil, selection: "hi")
        #expect(mode == .reply)
    }
}
