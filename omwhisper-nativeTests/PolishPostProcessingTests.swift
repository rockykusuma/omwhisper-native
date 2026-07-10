import Testing
@testable import OmWhisper

struct PolishPostProcessingTests {
    @Test func stripsOutputPrefix() {
        #expect(stripLLMWrapper("Output: Hello world") == "Hello world")
    }

    @Test func stripsHereIsPreamble() {
        #expect(stripLLMWrapper("Here is the polished text:\n\nHello world") == "Hello world")
    }

    @Test func stripsTrailingParentheticalCommentary() {
        #expect(stripLLMWrapper("Hello world\n\n(I removed the filler words)") == "Hello world")
    }

    @Test func stripsInlineTrailingCommentary() {
        #expect(stripLLMWrapper("I went back home. I made some minor adjustments to it.") == "I went back home.")
    }

    @Test func leavesCleanTextUnchanged() {
        #expect(stripLLMWrapper("Just normal text.") == "Just normal text.")
    }

    @Test func leavesMultiParagraphContentUnchanged() {
        let t = "First paragraph here.\n\nSecond paragraph with more detail follows."
        #expect(stripLLMWrapper(t) == t)
    }
}
