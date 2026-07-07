import Testing
@testable import OmWhisper

@Suite("ReplyStreamTypist.sentinelMatch")
struct ReplyStreamTypistSentinelTests {
    @Test("a known failure sentinel in the prefix is detected")
    func detectsSentinel() {
        #expect(ReplyStreamTypist.sentinelMatch(in: "Invalid API key, please check") == "Invalid API key")
        #expect(ReplyStreamTypist.sentinelMatch(in: "NO_REPLY_CONTEXT") == "NO_REPLY_CONTEXT")
    }

    @Test("ordinary drafted text has no sentinel match")
    func noFalsePositive() {
        #expect(ReplyStreamTypist.sentinelMatch(in: "Sounds good, see you at 3pm!") == nil)
    }

    @Test("every sentinel string is shorter than the buffer threshold")
    func sentinelsFitInBuffer() {
        for sentinel in ReplyStreamTypist.sentinels {
            #expect(sentinel.count <= ReplyStreamTypist.bufferThreshold)
        }
    }
}
