import Foundation
import Testing
@testable import OmWhisper

@Suite("SemanticIndexing")
struct SemanticIndexingTests {
    private typealias S = SemanticIndexing

    // MARK: boilerplate

    /// The spike's core finding: chrome must be detected WITHIN an app. A token
    /// in every snapshot of one app is boilerplate; a token in a few is content.
    @Test func boilerplateIsWhatRecursAcrossMostSnapshots() {
        let texts = [
            "Pinned Tabs Inbox Docs  quarterly revenue grew",
            "Pinned Tabs Inbox Docs  hearing aid firmware",
            "Pinned Tabs Inbox Docs  radiology appointment",
        ]
        let boiler = S.boilerplateTokens(perAppTexts: texts)
        #expect(boiler.contains("Pinned"))
        #expect(boiler.contains("Docs"))
        #expect(!boiler.contains("radiology"))
        #expect(!boiler.contains("firmware"))
    }

    @Test func stripRemovesOnlyBoilerplate() {
        let out = S.strip("Pinned Tabs radiology appointment", boilerplate: ["Pinned", "Tabs"])
        #expect(out == "radiology appointment")
    }

    @Test func boilerplateOfASingleSnapshotIsEmpty() {
        // One document: every token has 100% document frequency. Stripping them
        // all would erase the only content, so a single-doc app yields nothing.
        #expect(S.boilerplateTokens(perAppTexts: ["alpha beta gamma"]).isEmpty)
    }

    // MARK: chunking

    @Test func passagesSplitOnBoundariesAndNeverMidWord() {
        let text = Array(repeating: "alpha bravo charlie delta", count: 200).joined(separator: " ")
        let out = S.passages(text, limit: 1000)
        #expect(out.count > 1)
        #expect(out.allSatisfy { $0.count <= 1000 })
        // No passage starts or ends mid-word.
        #expect(out.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        // Nothing is lost.
        let rejoined = out.joined(separator: " ").split(separator: " ").count
        #expect(rejoined == text.split(separator: " ").count)
    }

    @Test func shortTextIsOnePassageAndEmptyIsNone() {
        #expect(S.passages("just a little text") == ["just a little text"])
        #expect(S.passages("   ").isEmpty)
    }

    // MARK: fusion

    /// RRF, not score blending: bm25 and cosine are on incompatible scales.
    /// The property RRF actually guarantees is that appearing in BOTH lists
    /// beats appearing in only one — which is the whole point of fusing.
    ///
    /// Note it does NOT mean "2nd in both beats 1st-and-last": 1/61 + 1/63 is
    /// very slightly larger than 2/62, because 1/x is convex. Ranks that far
    /// apart are within noise of each other; agreement across lists is the
    /// signal worth asserting.
    @Test func fusionRewardsAppearingInBothLists() {
        let fused = S.fuse(keyword: [1, 2], semantic: [3, 1])
        #expect(fused.first == 1)          // only id in both lists
        #expect(Set(fused) == Set([1, 2, 3]))
    }

    @Test func fusionKeepsBetterRanksAhead() {
        // Same lists, so RRF degenerates to the shared ordering.
        #expect(S.fuse(keyword: [7, 8, 9], semantic: [7, 8, 9]) == [7, 8, 9])
    }

    @Test func fusionHandlesDisjointAndEmptyLists() {
        #expect(S.fuse(keyword: [1, 2], semantic: []) == [1, 2])
        #expect(S.fuse(keyword: [], semantic: [5, 6]) == [5, 6])
        #expect(S.fuse(keyword: [], semantic: []).isEmpty)
        #expect(Set(S.fuse(keyword: [1], semantic: [2])) == Set([1, 2]))
    }

    // MARK: vector codec + cosine

    @Test func vectorRoundTripsThroughFloat16() {
        let v: [Float] = [0, 1, -1, 0.5, 0.25, 123.5]
        let back = S.decode(S.encode(v))
        #expect(back.count == v.count)
        for (a, b) in zip(v, back) { #expect(abs(a - b) < 0.01) }
    }

    @Test func cosineIsOneForIdenticalAndZeroForOrthogonal() {
        #expect(abs(S.cosine([1, 0, 0], [1, 0, 0]) - 1) < 0.0001)
        #expect(abs(S.cosine([1, 0, 0], [0, 1, 0])) < 0.0001)
        #expect(S.cosine([0, 0, 0], [1, 0, 0]) == 0)   // no NaN on a zero vector
    }
}
