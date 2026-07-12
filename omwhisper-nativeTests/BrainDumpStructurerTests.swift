import Testing
@testable import OmWhisper

struct BrainDumpStructurerTests {
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
