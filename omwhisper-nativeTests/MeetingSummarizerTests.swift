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

    /// Records every (style, text) pair so the map/reduce shape can be asserted.
    private struct CapturingPolish: PolishBackend {
        let capture: @Sendable (UUID, String) -> Void
        let reply: String
        func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
            capture(style.id, text)
            return reply
        }
    }

    @Test func answerPutsTheQuestionInBothStages() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [(UUID, String)]())
        let fake = CapturingPolish(capture: { id, text in seen.withLock { $0.append((id, text)) } },
                                   reply: "not discussed")
        _ = try await MeetingSummarizer.answer(
            question: "what did we decide about pricing",
            transcript: "**You:** [0:00]\nhello", polish: fake)
        let calls = seen.withLock { $0 }
        #expect(calls.count >= 2)
        // Extraction stage carries the question, and so does the final answer stage.
        #expect(calls.first!.1.localizedCaseInsensitiveContains("pricing"))
        #expect(calls.last!.1.localizedCaseInsensitiveContains("pricing"))
    }

    @Test func answerOnEmptyTranscriptSaysSo() async throws {
        let fake = CapturingPolish(capture: { _, _ in }, reply: "x")
        let out = try await MeetingSummarizer.answer(
            question: "anything?", transcript: "   ", polish: fake)
        #expect(out.localizedCaseInsensitiveContains("nothing"))
    }

    @Test func followUpStyleIsHiddenFromTemplates() {
        #expect(!MeetingSummarizer.builtInTemplates.contains { $0.id == MeetingSummarizer.followUpStyle.id })
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

/// Returns a fixed extract, then a fixed answer — lets answer()'s orchestration
/// be tested without a model. Reference type so the answer stage can see what
/// material it was actually handed, which is the whole point of these tests.
private final class ScriptedPolish: PolishBackend, @unchecked Sendable {
    let extractReply: String
    private let lock = OSAllocatedUnfairLock(initialState: "")
    var answerMaterial: String { lock.withLock { $0 } }

    init(extractReply: String) { self.extractReply = extractReply }

    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        if style.id == MeetingSummarizer.questionExtractStyle.id { return extractReply }
        lock.withLock { $0 = text }
        return "ANSWERED"
    }
}

@Suite("Meeting ask")
struct MeetingAskTests {
    @Test("a bare 'Nothing relevant.' is treated as no-content")
    func recognisesRefusalShapes() {
        for reply in ["NOTHING RELEVANT", "Nothing relevant.", "  nothing relevant  "] {
            #expect(MeetingSummarizer.isNothingRelevant(reply), "should discard: \(reply)")
        }
    }

    @Test("an extract that merely mentions the phrase is kept")
    func keepsSubstantiveExtractMentioningThePhrase() {
        let real = "Nothing relevant to the budget, but they discussed gratitude "
                 + "before bed at length and its effect on immunity."
        #expect(!MeetingSummarizer.isNothingRelevant(real))
    }

    @Test("a single-chunk transcript still answers when every extract is discarded")
    func fallsBackToTranscriptWhenExtractsAllRefuse() async throws {
        // Measured against llama3.2: the extract step returns "Nothing relevant."
        // for answerable questions, non-deterministically. Refusing outright made
        // the whole feature say "wasn't discussed" for content plainly present.
        let backend = ScriptedPolish(extractReply: "Nothing relevant.")
        let transcript = "**Alice:** we agreed to ship on Friday and freeze on Thursday."
        let answer = try await MeetingSummarizer.answer(
            question: "When do we ship?", transcript: transcript,
            polish: backend, chunkLimit: 12_000)

        #expect(answer == "ANSWERED")
        #expect(backend.answerMaterial.contains("ship on Friday"),
                "the answer stage should have received the transcript itself")
    }

    @Test("a multi-chunk transcript with no surviving extracts still refuses")
    func multiChunkStillRefuses() async throws {
        // The fallback is scoped to the case where the map step bought nothing.
        // Across many chunks the material genuinely can't be handed over whole.
        let backend = ScriptedPolish(extractReply: "NOTHING RELEVANT")
        let transcript = String(repeating: "word ", count: 400)
        let answer = try await MeetingSummarizer.answer(
            question: "When do we ship?", transcript: transcript,
            polish: backend, chunkLimit: 100)

        #expect(answer == "That wasn't discussed in this meeting.")
    }
}
