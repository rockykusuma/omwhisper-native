import Foundation
import Testing
@testable import OmWhisper

@Suite("MemoryEmbedding")
struct MemoryEmbeddingTests {
    /// Verified in the spike: this model discriminates correctly on clean text
    /// (car/automobile 0.68 vs car/banana 0.35). If this ever fails, the model
    /// changed underneath us and the whole feature's premise needs re-checking.
    @Test func embedderRanksRelatedTextAboveUnrelated() throws {
        guard let e = AppleEmbedder() else { return }  // no model here; app degrades, so does this
        let car = try #require(e.vector("a car"))
        let auto = try #require(e.vector("an automobile"))
        let fruit = try #require(e.vector("a banana"))
        #expect(SemanticIndexing.cosine(car, auto) > SemanticIndexing.cosine(car, fruit))
    }

    @Test func vectorHasTheAdvertisedDimension() throws {
        guard let e = AppleEmbedder() else { return }
        let v = try #require(e.vector("hello world"))
        #expect(v.count == e.dimension)
    }

    @Test func emptyTextYieldsNoVector() {
        guard let e = AppleEmbedder() else { return }
        #expect(e.vector("") == nil)
        #expect(e.vector("   \n ") == nil)
    }
}
