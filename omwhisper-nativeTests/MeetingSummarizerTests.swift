import Testing
@testable import OmWhisper

struct MeetingSummarizerTests {
    @Test func shortTextIsOneChunk() {
        #expect(MeetingSummarizer.chunk("hello world", limit: 100) == ["hello world"])
    }

    @Test func packsWordsUnderLimitWithoutLosingContent() {
        let text = Array(repeating: "word", count: 50).joined(separator: " ")  // 50 words
        let chunks = MeetingSummarizer.chunk(text, limit: 40)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 40 })
        let rejoinedWordCount = chunks.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).count
        #expect(rejoinedWordCount == 50)
    }

    @Test func emptyGivesNoChunks() {
        #expect(MeetingSummarizer.chunk("   ", limit: 100).isEmpty)
    }
}
