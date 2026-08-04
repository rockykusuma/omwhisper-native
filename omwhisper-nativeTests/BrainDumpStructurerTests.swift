import Testing
import os
@testable import OmWhisper

struct BrainDumpStructurerTests {
    /// Counts calls and echoes its input, so chunking behaviour is observable
    /// without a real model.
    final class CountingBackend: PolishBackend, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var calls: Int { lock.withLock { $0 } }
        func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
            lock.withLock { $0 += 1 }
            return text
        }
    }

    @Test("a bigger chunk limit means strictly fewer model calls")
    func largerChunkLimitMakesFewerCalls() async throws {
        // Accepting the parameter and ignoring it would still produce output and
        // pass a "did it structure something" check. Counting calls is what
        // fails if the limit is dropped on the floor. Same assertion shape as
        // Chronicler's chunk-limit test.
        let transcript = (1...200)
            .map { "Sentence number \($0) about something I need to remember later." }
            .joined(separator: " ")
        let shape = BrainDumpShapes.builtIns.first!

        let small = CountingBackend()
        _ = try await BrainDumpStructurer.structure(
            transcript: transcript, shape: shape, context: nil,
            polish: small, chunkLimit: BrainDumpStructurer.chunkCharLimit)

        let large = CountingBackend()
        _ = try await BrainDumpStructurer.structure(
            transcript: transcript, shape: shape, context: nil,
            polish: large, chunkLimit: BrainDumpStructurer.ollamaChunkLimit)

        #expect(large.calls < small.calls,
                "12k limit made \(large.calls) calls, 1.8k made \(small.calls)")
    }

    // Echoes which style processed what, so we can assert the map/reduce path.
    struct EchoBackend: PolishBackend {
        func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
            "[\(style.name)] \(text)"
        }
    }

    @Test func chunkPacksWordsUnderLimit() {
        let groups = BrainDumpStructurer.chunk("one two three four five", limit: 9)
        #expect(groups == ["one two", "three", "four five"])
    }

    @Test func chunkKeepsOversizeWordAsOwnGroup() {
        let groups = BrainDumpStructurer.chunk("hi supercalifragilistic ok", limit: 5)
        #expect(groups == ["hi", "supercalifragilistic", "ok"])
    }

    @Test func singleChunkSkipsMapAndAppliesShapeDirectly() async throws {
        let shape = BrainDumpShapes.builtIns[0]  // Email
        let out = try await BrainDumpStructurer.structure(
            transcript: "quick note", shape: shape, context: nil, polish: EchoBackend())
        // One chunk → no chunk-notes pass; shape applied to the raw transcript.
        #expect(out == "[\(shape.name)] quick note")
    }

    @Test func multiChunkMapsThenReduces() async throws {
        let shape = BrainDumpShapes.builtIns[0]
        let long = String(repeating: "word ", count: 800)  // > one 1800-char chunk
        let out = try await BrainDumpStructurer.structure(
            transcript: long, shape: shape, context: nil, polish: EchoBackend())
        // Reduce input is the joined chunk-notes, so the final output is the shape
        // applied to text containing the chunk-notes style marker.
        #expect(out.hasPrefix("[\(shape.name)] "))
        #expect(out.contains("[\(BrainDumpShapes.chunkNotesStyle.name)]"))
    }

    @Test func contextIsAppendedToReduceInput() async throws {
        let shape = BrainDumpShapes.builtIns[0]
        let out = try await BrainDumpStructurer.structure(
            transcript: "note", shape: shape, context: "Target app: Mail", polish: EchoBackend())
        #expect(out.contains("Target app: Mail"))
    }
}
