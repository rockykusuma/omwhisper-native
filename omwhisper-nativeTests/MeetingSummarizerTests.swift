import Foundation
import Testing
import os
@testable import OmWhisper

struct MeetingSummarizerTests {
    /// Records which style each polish() call received; returns canned text.
    private struct RecordingPolish: PolishBackend {
        let record: @Sendable (UUID) -> Void
        func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
            record(style.id)
            return "out"
        }
    }

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

    @Test func templateLookupFallsBackToStandard() {
        let custom = PolishStyle(id: UUID(), name: "Mine", prompt: "p", isBuiltIn: false)
        #expect(MeetingSummarizer.template(id: custom.id, custom: [custom]).id == custom.id)
        #expect(MeetingSummarizer.template(id: nil, custom: []).id == MeetingSummarizer.meetingWriteStyle.id)
        #expect(MeetingSummarizer.template(id: UUID(), custom: []).id == MeetingSummarizer.meetingWriteStyle.id)
    }

    @Test func builtInTemplatesAreFixedAndStandardIsFirst() {
        let ids = MeetingSummarizer.builtInTemplates.map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(MeetingSummarizer.builtInTemplates.first?.id == MeetingSummarizer.meetingWriteStyle.id)
    }

    @Test func generateUsesTheGivenTemplateForTheReduceCall() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [UUID]())
        let fake = RecordingPolish { id in seen.withLock { $0.append(id) } }
        let standup = MeetingSummarizer.builtInTemplates[1]
        _ = try await MeetingSummarizer.generate(
            transcript: "**You:** [0:00]\nhello world", polish: fake, template: standup)
        let ids = seen.withLock { $0 }
        // map call(s) use the chunk style; the final reduce call uses the template.
        #expect(ids.first == MeetingSummarizer.chunkSummaryStyle.id)
        #expect(ids.last == standup.id)
    }

    /// The reduce stage used to `prefix(1_800)` the joined chunk summaries, so a
    /// long meeting's later material was silently dropped before the summary was
    /// written — the same bug Chronicler already fixed. Traced end-to-end here:
    /// the fake summarizer keeps each group's first and last word, so the final
    /// reduce input must still mention the transcript's LAST word. Truncation
    /// fails this; collapsing preserves it.
    @Test func longTranscriptKeepsItsEndingInTheReduceInput() async throws {
        let reduceInput = OSAllocatedUnfairLock(initialState: "")
        let fake = EdgeKeepingPolish { text in reduceInput.withLock { $0 = text } }
        let words = (0..<200).map { "w\($0)" }.joined(separator: " ")
        _ = try await MeetingSummarizer.generate(transcript: words, polish: fake, chunkLimit: 60)
        #expect(reduceInput.withLock { $0 }.contains("w199"))
    }

    /// Chunk calls return "<first> <last>" of what they were given (so material
    /// from the end survives each collapse round); the reduce call reports the
    /// text it received.
    private struct EdgeKeepingPolish: PolishBackend {
        let onReduce: @Sendable (String) -> Void
        func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
            guard style.id == MeetingSummarizer.chunkSummaryStyle.id else {
                onReduce(text)
                return "final"
            }
            let words = text.split(whereSeparator: { $0.isWhitespace })
            return [words.first, words.last].compactMap { $0 }.joined(separator: " ")
        }
    }

    @Test func chunkLimitParameterIsHonored() {
        // 12k-limit chunking packs a long transcript into far fewer groups.
        let words = Array(repeating: "word", count: 4_000).joined(separator: " ")
        let small = MeetingSummarizer.chunk(words, limit: MeetingSummarizer.chunkCharLimit).count
        let large = MeetingSummarizer.chunk(words, limit: MeetingSummarizer.ollamaChunkLimit).count
        #expect(large < small)
        #expect(large == 2)  // 4,000 words ≈ 20k chars → 2 groups at 12k
    }
}
