import Foundation
import GRDB
import Testing
import os
@testable import OmWhisper

@Suite("Memory indexing reuses vectors")
struct MemoryIndexerCacheTests {
    /// Counts calls, so "did the cache actually prevent work?" is answerable.
    /// A cache that never hits still produces correct output — only a call
    /// count can tell the difference.
    private final class CountingEmbedder: MemoryEmbedder, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var calls: Int { lock.withLock { $0 } }
        var dimension: Int { 4 }
        func vector(_ text: String) -> [Float]? {
            lock.withLock { $0 += 1 }
            // Deterministic per text, like NLEmbedding.
            let n = Float(text.count)
            return [n, n + 1, n + 2, n + 3]
        }
    }

    private func makeStore() throws -> MemoryStore { try MemoryStore(DatabaseQueue()) }

    /// upsert() returns Void, so the id comes back through the pending query.
    private func storeSnapshot(_ store: MemoryStore, content: String, title: String) throws -> MemorySnapshot {
        try store.upsert(appName: "Test", bundleID: "com.test", windowTitle: title,
                         content: content, url: "")
        return try #require(store.snapshotsMissingPassages(limit: 100).last)
    }

    private func body(_ phrase: String) -> String {
        String(repeating: phrase + " ", count: 40)
    }

    @Test("identical passage text is embedded once, not twice")
    func repeatedTextIsEmbeddedOnce() throws {
        // The whole point of the change. Capture takes the same window every
        // 5s; one line changes; every passage used to be redone from scratch.
        let store = try makeStore()
        let embedder = CountingEmbedder()
        let indexer = try #require(MemoryIndexer(embedder: embedder))
        let text = body("the quarterly report is attached for review")

        let a = try storeSnapshot(store, content: text, title: "w1")
        try indexer.index(snapshot: a, boilerplate: [], in: store)
        let afterFirst = embedder.calls
        #expect(afterFirst > 0, "nothing was embedded at all")

        let b = try storeSnapshot(store, content: text, title: "w2")
        try indexer.index(snapshot: b, boilerplate: [], in: store)

        #expect(embedder.calls == afterFirst, "the second snapshot re-embedded identical text")
    }

    @Test("new text is still embedded")
    func newTextIsEmbedded() throws {
        // The half that fails if the lookup returns something for everything.
        let store = try makeStore()
        let embedder = CountingEmbedder()
        let indexer = try #require(MemoryIndexer(embedder: embedder))

        let a = try storeSnapshot(store, content: body("alpha beta gamma delta"), title: "w1")
        try indexer.index(snapshot: a, boilerplate: [], in: store)
        let afterFirst = embedder.calls

        let b = try storeSnapshot(store, content: body("entirely different words here"), title: "w2")
        try indexer.index(snapshot: b, boilerplate: [], in: store)

        #expect(embedder.calls > afterFirst, "genuinely new text was not embedded")
    }

    @Test("a reused vector is byte-identical to a freshly embedded one")
    func reusedVectorMatches() throws {
        // A cache returning a DIFFERENT vector would still search, just worse,
        // and nothing else in the suite would notice.
        let store = try makeStore()
        let indexer = try #require(MemoryIndexer(embedder: CountingEmbedder()))
        let text = body("identical content for both snapshots")

        let a = try storeSnapshot(store, content: text, title: "w1")
        try indexer.index(snapshot: a, boilerplate: [], in: store)
        let b = try storeSnapshot(store, content: text, title: "w2")
        try indexer.index(snapshot: b, boilerplate: [], in: store)

        let vectors = try store.allPassageVectors()
        let forA = vectors.filter { $0.snapshotId == a.id }.sorted { $0.ordinal < $1.ordinal }
        let forB = vectors.filter { $0.snapshotId == b.id }.sorted { $0.ordinal < $1.ordinal }
        #expect(!forA.isEmpty)
        #expect(forA.map(\.vector) == forB.map(\.vector))
    }

    @Test("maxBatches is honoured, and a later call resumes")
    func batchBoundIsHonoured() throws {
        // A bound accepted and ignored would pass "did everything get indexed
        // eventually?" — this asserts it STOPS, then finishes later.
        let store = try makeStore()
        let indexer = try #require(MemoryIndexer(embedder: CountingEmbedder()))
        for i in 0..<7 {
            try store.upsert(appName: "Test", bundleID: "com.test", windowTitle: "w\(i)",
                             content: body("body number \(i) with enough words"), url: "")
        }

        let first = try indexer.processPending(store: store, batch: 2, maxBatches: 1)
        #expect(first == 2, "the batch bound was ignored")
        #expect(try store.snapshotsMissingPassages(limit: 100).count == 5)

        var total = first
        while true {
            let n = try indexer.processPending(store: store, batch: 2, maxBatches: 1)
            if n == 0 { break }
            total += n
        }
        #expect(total == 7, "later calls did not resume and finish")
        #expect(try store.snapshotsMissingPassages(limit: 100).isEmpty)
    }
}
