# Memory Semantic Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Memory search that finds what you meant — "book an appointment for a medical scan" surfaces the radiology page even though no word matches. Per `docs/superpowers/specs/2026-08-01-memory-semantic-search-design.md`, with the embedder settled by `docs/superpowers/specs/2026-08-01-memory-embedding-spike.md`.

**Architecture:** Four pure pieces (boilerplate filter, chunker, RRF fusion, vector codec) plus one effectful embedder behind a protocol. `memory.db` gains a `passages` table holding a float16 vector per passage. Search runs FTS5 and cosine independently and fuses the two ranked lists. Every path degrades to today's keyword-only behaviour on failure.

**Tech Stack:** Swift 6 (MainActor-by-default), GRDB, NaturalLanguage (`NLEmbedding`), Accelerate (vDSP), Swift Testing.

## Global Constraints

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: every new type here runs off the UI thread and MUST be marked `nonisolated`, matching `MemoryStore`/`Chronicler`.
- **Memory is local-only.** No network, no cloud, in any task.
- **Never regress keyword search.** If embeddings are missing, failed, or the backfill is incomplete, results must be exactly today's. A user who never notices this feature must see no change.
- Xcode groups are file-system-synced — create files on disk, never hand-edit `project.pbxproj` file references.
- Full-suite command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteName>`.
- Debug builds are `OmWhisper-Dev` with their own `memory.db` — testing can never touch real data.
- Commit style: emoji conventional commits. Work in a worktree.

---

### Task 1: The four pure pieces

**Files:**
- Create: `omwhisper-native/Memory/SemanticIndexing.swift`
- Test: `omwhisper-nativeTests/SemanticIndexingTests.swift` (create)

**Interfaces:**
- Produces, all in `nonisolated enum SemanticIndexing`:
  - `boilerplateTokens(perAppTexts: [String], threshold: Double = 0.7) -> Set<String>`
  - `strip(_ text: String, boilerplate: Set<String>) -> String`
  - `passages(_ text: String, limit: Int = 1000) -> [String]`
  - `fuse(keyword: [Int64], semantic: [Int64], k: Int = 60) -> [Int64]` — reciprocal rank fusion
  - `encode(_ v: [Float]) -> Data` / `decode(_ d: Data) -> [Float]` — float16 codec
  - `cosine(_ a: [Float], _ b: [Float]) -> Float`
- Consumes: nothing. This task has no dependencies and no I/O.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/SemanticIndexingTests.swift`:

```swift
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
    /// A row ranked well by BOTH must beat a row ranked first by only one.
    @Test func fusionRewardsAgreement() {
        let fused = S.fuse(keyword: [1, 2, 3], semantic: [3, 2, 1])
        #expect(fused.first == 2)          // 2nd in both beats 1st-and-last
        #expect(Set(fused) == Set([1, 2, 3]))
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
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/SemanticIndexingTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'SemanticIndexing' in scope`.

- [ ] **Step 3: Implement**

Create `omwhisper-native/Memory/SemanticIndexing.swift`:

```swift
//
//  SemanticIndexing.swift
//  OmWhisper
//
//  The pure half of Memory's semantic search: boilerplate detection, passage
//  chunking, rank fusion, and the vector codec. No I/O, no NaturalLanguage --
//  those live in MemoryEmbedding/MemoryStore, so everything here unit-tests
//  directly (the same split as MeetingDiarization vs MeetingDiarizer).
//
//  See docs/superpowers/specs/2026-08-01-memory-embedding-spike.md for why
//  boilerplate detection is per-app.
//

import Accelerate
import Foundation

nonisolated enum SemanticIndexing {
    // MARK: - Boilerplate

    /// Tokens appearing in more than `threshold` of one app's snapshots.
    ///
    /// Per-app is load-bearing, not an optimisation: measured on the real store,
    /// a median Arc snapshot is 58% sidebar/pinned-tab chrome, but computing
    /// document frequency across ALL apps found 32 such tokens instead of 93
    /// and barely changed retrieval. Chrome differs per app.
    ///
    /// A single document yields nothing -- every token would have 100% document
    /// frequency, and stripping them all would erase the only content there is.
    static func boilerplateTokens(perAppTexts: [String], threshold: Double = 0.7) -> Set<String> {
        guard perAppTexts.count > 1 else { return [] }
        var df: [String: Int] = [:]
        for text in perAppTexts {
            for token in Set(text.split(separator: " ").map(String.init)) {
                df[token, default: 0] += 1
            }
        }
        let cutoff = Double(perAppTexts.count) * threshold
        return Set(df.filter { Double($0.value) > cutoff }.keys)
    }

    static func strip(_ text: String, boilerplate: Set<String>) -> String {
        text.split(separator: " ")
            .map(String.init)
            .filter { !boilerplate.contains($0) }
            .joined(separator: " ")
    }

    // MARK: - Chunking

    /// ~`limit`-char passages, split on word boundaries. A whole snapshot is one
    /// vector of mush (6,350 chars on average); passages are also what lets the
    /// UI show WHICH part matched.
    static func passages(_ text: String, limit: Int = 1000) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            if !current.isEmpty, current.count + word.count + 1 > limit {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Fusion

    /// Reciprocal rank fusion. bm25 and cosine live on incompatible scales, so
    /// normalising them into one score is a tuning problem with no correct
    /// answer; RRF only needs the orderings. Rows ranked well by both win.
    static func fuse(keyword: [Int64], semantic: [Int64], k: Int = 60) -> [Int64] {
        var score: [Int64: Double] = [:]
        for (i, id) in keyword.enumerated() { score[id, default: 0] += 1.0 / Double(k + i + 1) }
        for (i, id) in semantic.enumerated() { score[id, default: 0] += 1.0 / Double(k + i + 1) }
        // Stable: ties broken by first appearance, so results don't reshuffle.
        let order = (keyword + semantic).reduce(into: [Int64: Int]()) { acc, id in
            if acc[id] == nil { acc[id] = acc.count }
        }
        return score.keys.sorted {
            score[$0]! != score[$1]! ? score[$0]! > score[$1]! : order[$0]! < order[$1]!
        }
    }

    // MARK: - Vector codec

    /// float16 halves the index (~1 KB/passage at 512 dims). Precision loss is
    /// irrelevant to cosine ranking.
    static func encode(_ v: [Float]) -> Data {
        var halves = [UInt16](repeating: 0, count: v.count)
        var src = v
        src.withUnsafeMutableBufferPointer { s in
            halves.withUnsafeMutableBufferPointer { d in
                var srcBuf = vImage_Buffer(data: s.baseAddress!, height: 1,
                                           width: vImagePixelCount(v.count), rowBytes: v.count * 4)
                var dstBuf = vImage_Buffer(data: d.baseAddress!, height: 1,
                                           width: vImagePixelCount(v.count), rowBytes: v.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, 0)
            }
        }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ d: Data) -> [Float] {
        let count = d.count / 2
        guard count > 0 else { return [] }
        var halves = [UInt16](repeating: 0, count: count)
        _ = halves.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        var out = [Float](repeating: 0, count: count)
        halves.withUnsafeMutableBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                var srcBuf = vImage_Buffer(data: s.baseAddress!, height: 1,
                                           width: vImagePixelCount(count), rowBytes: count * 2)
                var dstBuf = vImage_Buffer(data: o.baseAddress!, height: 1,
                                           width: vImagePixelCount(count), rowBytes: count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, 0)
            }
        }
        return out
    }

    /// Zero vectors return 0 rather than NaN -- a NaN would poison the sort.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/SemanticIndexingTests 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: TEST SUCCEEDED.

If the vImage float16 conversion doesn't compile, substitute Swift's own `Float16`
(`halves = v.map { Float16($0) }` and back) — same result, and the round-trip test is what
proves it either way. Do not leave both implementations in.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/SemanticIndexing.swift omwhisper-nativeTests/SemanticIndexingTests.swift
git commit -m "✨ feat(memory): pure semantic-indexing pieces — boilerplate, chunking, RRF, codec"
```

---

### Task 2: The embedder

**Files:**
- Create: `omwhisper-native/Memory/MemoryEmbedding.swift`
- Test: `omwhisper-nativeTests/MemoryEmbeddingTests.swift` (create)

**Interfaces:**
- Produces: `protocol MemoryEmbedder: Sendable { var dimension: Int { get }; func vector(_ text: String) -> [Float]? }`; `nonisolated struct AppleEmbedder: MemoryEmbedder` (wraps `NLEmbedding.sentenceEmbedding(for: .english)`); `AppleEmbedder.isAvailable() -> Bool`.
- Consumes: nothing from Task 1.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import OmWhisper

@Suite("MemoryEmbedding")
struct MemoryEmbeddingTests {
    /// Verified in the spike: this model discriminates correctly on clean text
    /// (car/automobile 0.68 vs car/banana 0.35). If this ever fails, the model
    /// changed underneath us and the whole feature's premise needs re-checking.
    @Test func embedderRanksRelatedTextAboveUnrelated() throws {
        guard AppleEmbedder.isAvailable(), let e = AppleEmbedder() else {
            return  // no model on this machine; the app degrades, so does the test
        }
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

    @Test func emptyTextDoesNotCrash() {
        guard let e = AppleEmbedder() else { return }
        _ = e.vector("")   // nil or a vector, both fine; must not trap
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MemoryEmbeddingTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'AppleEmbedder' in scope`.

- [ ] **Step 3: Implement**

```swift
//
//  MemoryEmbedding.swift
//  OmWhisper
//
//  On-device sentence embeddings for Memory search. NLEmbedding was chosen over
//  NLContextualEmbedding by measurement (see the embedding spike): comparable
//  retrieval quality, no downloadable model asset, ~4x cheaper on short text.
//
//  Behind a protocol because the evidence separating the two models is weak --
//  if real-world quality disappoints, a CoreML retrieval-trained bi-encoder
//  drops in here without touching the store or the UI.
//

import Foundation
import NaturalLanguage

nonisolated protocol MemoryEmbedder: Sendable {
    var dimension: Int { get }
    /// nil when this text cannot be embedded. Callers skip the passage rather
    /// than failing the snapshot -- partial coverage still beats none.
    func vector(_ text: String) -> [Float]?
}

nonisolated struct AppleEmbedder: MemoryEmbedder {
    private let embedding: NLEmbedding

    init?() {
        guard let e = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        embedding = e
    }

    static func isAvailable() -> Bool { NLEmbedding.sentenceEmbedding(for: .english) != nil }

    var dimension: Int { embedding.dimension }

    func vector(_ text: String) -> [Float]? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let v = embedding.vector(for: text) else { return nil }
        return v.map { Float($0) }
    }
}
```

- [ ] **Step 4: Run to verify pass, then commit**

Run the same `-only-testing` command → TEST SUCCEEDED.

```bash
git add omwhisper-native/Memory/MemoryEmbedding.swift omwhisper-nativeTests/MemoryEmbeddingTests.swift
git commit -m "✨ feat(memory): on-device sentence embedder behind a swappable protocol"
```

---

### Task 3: Schema v3 + passage storage

**Files:**
- Modify: `omwhisper-native/Memory/MemoryStore.swift`
- Test: `omwhisper-nativeTests/MemoryStoreTests.swift`

**Interfaces:**
- Produces: `MemoryPassage` record (`id`, `snapshotId`, `ordinal`, `text`, `vector: Data`); `MemoryStore.replacePassages(snapshotId:passages:) throws`; `MemoryStore.allPassageVectors() throws -> [(snapshotId: Int64, ordinal: Int, vector: Data, text: String)]`; `MemoryStore.snapshotsMissingPassages(limit:) throws -> [MemorySnapshot]`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MemoryStoreTests.swift`:

```swift
    @Test func passagesRoundTripAndReplaceCleanly() throws {
        let store = try makeStore()
        try store.upsert(appName: "Arc", bundleID: "com.arc", windowTitle: "T",
                         content: "radiology appointment booking", url: "")
        let snap = try #require(try store.fetchPage(offset: 0, limit: 1).first)
        let id = try #require(snap.id)

        try store.replacePassages(snapshotId: id, passages: [("first", Data([1, 2])), ("second", Data([3, 4]))])
        #expect(try store.allPassageVectors().count == 2)

        // Replacing is not appending — re-indexing a snapshot must not duplicate.
        try store.replacePassages(snapshotId: id, passages: [("only", Data([5, 6]))])
        let rows = try store.allPassageVectors()
        #expect(rows.count == 1)
        #expect(rows.first?.text == "only")
    }

    /// Deleting a snapshot must take its passages: the prune runs daily and an
    /// orphaned vector index would grow without bound.
    @Test func deletingASnapshotDeletesItsPassages() throws {
        let store = try makeStore()
        try store.upsert(appName: "Arc", bundleID: "com.arc", windowTitle: "T",
                         content: "some content", url: "")
        let id = try #require(try store.fetchPage(offset: 0, limit: 1).first?.id)
        try store.replacePassages(snapshotId: id, passages: [("p", Data([1, 2]))])
        try store.delete(id: id)
        #expect(try store.allPassageVectors().isEmpty)
    }

    @Test func snapshotsMissingPassagesDrivesBackfill() throws {
        let store = try makeStore()
        try store.upsert(appName: "A", bundleID: "a", windowTitle: "1", content: "one", url: "")
        try store.upsert(appName: "A", bundleID: "a", windowTitle: "2", content: "two", url: "")
        #expect(try store.snapshotsMissingPassages(limit: 10).count == 2)

        let first = try #require(try store.snapshotsMissingPassages(limit: 10).first?.id)
        try store.replacePassages(snapshotId: first, passages: [("p", Data([1, 2]))])
        #expect(try store.snapshotsMissingPassages(limit: 10).count == 1)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MemoryStoreTests 2>&1 | grep -E "error:" | head -3`
Expected: no member `replacePassages`.

- [ ] **Step 3: Implement**

Add the record above `MemoryStore`:

```swift
nonisolated struct MemoryPassage: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "passages"
    var id: Int64?
    var snapshotId: Int64
    var ordinal: Int
    var text: String
    var vector: Data          // float16, see SemanticIndexing.encode

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

Register a third migration after `createChronicles`:

```swift
        migrator.registerMigration("createPassages") { db in
            try db.create(table: MemoryPassage.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                // Cascade: prune() deletes snapshots directly, and an orphaned
                // vector index would grow forever.
                t.column("snapshotId", .integer).notNull()
                    .references(MemorySnapshot.databaseTableName, onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("vector", .blob).notNull()
            }
            try db.create(index: "passages_snapshot", on: MemoryPassage.databaseTableName,
                          columns: ["snapshotId"])
        }
```

**Foreign keys must be on** for the cascade to fire. GRDB enables them by default; the
`deletingASnapshotDeletesItsPassages` test is what proves it — if that test fails, add a
`Configuration` with `foreignKeysEnabled = true` to the `DatabaseQueue` rather than deleting
passages by hand at every call site.

Add the three methods:

```swift
    /// Replace every passage for a snapshot. Replace, not append: re-indexing
    /// after a content change must not leave the old vectors behind.
    func replacePassages(snapshotId: Int64, passages: [(text: String, vector: Data)]) throws {
        try dbQueue.write { db in
            try MemoryPassage.filter(Column("snapshotId") == snapshotId).deleteAll(db)
            for (i, p) in passages.enumerated() {
                var row = MemoryPassage(id: nil, snapshotId: snapshotId, ordinal: i,
                                        text: p.text, vector: p.vector)
                try row.insert(db)
            }
        }
    }

    /// Every vector, for the in-memory cosine scan. At ~40k passages this is a
    /// few tens of MB and a few million float ops -- an ANN index would be
    /// complexity for no measurable gain at this scale.
    func allPassageVectors() throws -> [(snapshotId: Int64, ordinal: Int, vector: Data, text: String)] {
        try dbQueue.read { db in
            try MemoryPassage.fetchAll(db).map {
                ($0.snapshotId, $0.ordinal, $0.vector, $0.text)
            }
        }
    }

    /// Backfill driver: snapshots with no passages yet, oldest first.
    func snapshotsMissingPassages(limit: Int) throws -> [MemorySnapshot] {
        try dbQueue.read { db in
            try MemorySnapshot.fetchAll(db, sql: """
                SELECT snapshots.* FROM snapshots
                LEFT JOIN passages ON passages.snapshotId = snapshots.id
                WHERE passages.id IS NULL
                ORDER BY snapshots.id ASC
                LIMIT ?
                """, arguments: [limit])
        }
    }
```

- [ ] **Step 4: Run to verify pass, then the FULL suite** (a migration touches every existing test that opens a store)

`-only-testing:omwhisper-nativeTests/MemoryStoreTests` → PASS, then the full-suite command → TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/MemoryStore.swift omwhisper-nativeTests/MemoryStoreTests.swift
git commit -m "✨ feat(memory): passages table with cascade delete + backfill query"
```

---

### Task 4: Hybrid search

**Files:**
- Modify: `omwhisper-native/Memory/MemoryStore.swift`
- Test: `omwhisper-nativeTests/MemoryStoreTests.swift`

**Interfaces:**
- Produces: `MemoryStore.hybridSearch(_ query: String, embedder: MemoryEmbedder?, limit: Int) throws -> [(snapshot: MemorySnapshot, matchedPassage: String?)]`.
- Consumes: Task 1's `cosine`/`decode`/`fuse`, Task 2's `MemoryEmbedder`, Task 3's `allPassageVectors`.

- [ ] **Step 1: Write the failing tests**

```swift
    /// A stub embedder makes semantic ranking deterministic and model-free:
    /// the vector is just term-presence, so "cost" and "pricing" can be made
    /// to look alike without shipping a model into the test.
    private struct StubEmbedder: MemoryEmbedder {
        var dimension: Int { 3 }
        func vector(_ text: String) -> [Float]? {
            let t = text.lowercased()
            return [t.contains("cost") || t.contains("pricing") ? 1 : 0,
                    t.contains("hearing") ? 1 : 0,
                    t.contains("build") ? 1 : 0]
        }
    }

    @Test func hybridFindsAParaphraseKeywordSearchCannot() throws {
        let store = try makeStore()
        try store.upsert(appName: "Arc", bundleID: "a", windowTitle: "Costs",
                         content: "our cost structure for next year", url: "")
        try store.upsert(appName: "Arc", bundleID: "a", windowTitle: "Aids",
                         content: "hearing aid firmware notes", url: "")
        let emb = StubEmbedder()
        for s in try store.snapshotsMissingPassages(limit: 10) {
            guard let id = s.id else { continue }
            let vecs = SemanticIndexing.passages(s.content).compactMap { p -> (String, Data)? in
                guard let v = emb.vector(p) else { return nil }
                return (p, SemanticIndexing.encode(v))
            }
            try store.replacePassages(snapshotId: id, passages: vecs)
        }

        // "pricing" appears nowhere in the corpus -- keyword search finds nothing.
        #expect(try store.search("pricing").isEmpty)
        let hits = try store.hybridSearch("pricing", embedder: emb, limit: 5)
        #expect(hits.first?.snapshot.windowTitle == "Costs")
        #expect(hits.first?.matchedPassage?.contains("cost structure") == true)
    }

    /// The non-negotiable: with no embedder, behaviour is exactly today's.
    @Test func hybridWithoutEmbedderEqualsKeywordSearch() throws {
        let store = try makeStore()
        try store.upsert(appName: "Arc", bundleID: "a", windowTitle: "T",
                         content: "quarterly revenue report", url: "")
        let hybrid = try store.hybridSearch("revenue", embedder: nil, limit: 5).map(\.snapshot.id)
        let keyword = try store.search("revenue").map(\.id)
        #expect(hybrid == keyword)
        #expect(!hybrid.isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure** — no member `hybridSearch`.

- [ ] **Step 3: Implement**

```swift
    /// Keyword and semantic ranked independently, then fused. `embedder == nil`,
    /// an unembeddable query, or an empty passage table all fall through to
    /// exactly today's keyword behaviour -- a user who never enables this must
    /// see no change.
    func hybridSearch(_ query: String, embedder: MemoryEmbedder?, limit: Int = 20) throws
        -> [(snapshot: MemorySnapshot, matchedPassage: String?)] {
        let keywordHits = try search(query, limit: limit)
        let keywordIDs = keywordHits.compactMap(\.id)

        guard let embedder, let qv = embedder.vector(query) else {
            return keywordHits.map { ($0, nil) }
        }

        // Best-scoring passage per snapshot.
        var best: [Int64: (score: Float, text: String)] = [:]
        for row in try allPassageVectors() {
            let score = SemanticIndexing.cosine(qv, SemanticIndexing.decode(row.vector))
            if score > (best[row.snapshotId]?.score ?? -1) {
                best[row.snapshotId] = (score, row.text)
            }
        }
        guard !best.isEmpty else { return keywordHits.map { ($0, nil) } }

        let semanticIDs = best.sorted { $0.value.score > $1.value.score }
            .prefix(limit).map(\.key)
        let fused = SemanticIndexing.fuse(keyword: keywordIDs, semantic: Array(semanticIDs))

        var byID = Dictionary(uniqueKeysWithValues: keywordHits.compactMap { s in s.id.map { ($0, s) } })
        let missing = fused.filter { byID[$0] == nil }
        if !missing.isEmpty {
            try dbQueue.read { db in
                for s in try MemorySnapshot.fetchAll(db, keys: missing) {
                    if let id = s.id { byID[id] = s }
                }
            }
        }
        return fused.prefix(limit).compactMap { id in
            byID[id].map { ($0, best[id]?.text) }
        }
    }
```

- [ ] **Step 4: Run to verify pass, then full suite, then commit**

```bash
git add omwhisper-native/Memory/MemoryStore.swift omwhisper-nativeTests/MemoryStoreTests.swift
git commit -m "✨ feat(memory): hybrid keyword + semantic search fused by RRF"
```

---

### Task 5: Indexing on capture + backfill

**Files:**
- Create: `omwhisper-native/Memory/MemoryIndexer.swift`
- Modify: `omwhisper-native/AppState.swift` (start the backfill where `memoryEnabled` wires its collaborators)

**Interfaces:**
- Produces: `MemoryIndexer` — `index(snapshot:in:)` for one snapshot, and `runBackfill(store:progress:)` processing in batches.
- Consumes: Tasks 1–3.

No new unit tests: this is orchestration over already-tested pieces, verified live in Task 7 (project convention — `MemoryCapture` and `ChronicleScheduler` are covered the same way).

- [ ] **Step 1: Implement the indexer**

```swift
//
//  MemoryIndexer.swift
//  OmWhisper
//
//  Turns snapshots into passage vectors: strip per-app boilerplate, chunk,
//  embed, store. Runs off the UI thread; never blocks capture or search.
//

import Foundation

nonisolated final class MemoryIndexer: Sendable {
    private let embedder: MemoryEmbedder

    init?(embedder: MemoryEmbedder? = AppleEmbedder()) {
        guard let embedder else { return nil }
        self.embedder = embedder
    }

    /// Boilerplate is computed per app from a sample of that app's snapshots --
    /// globally it finds a third as many tokens and barely helps (see the spike).
    func index(snapshot: MemorySnapshot, boilerplate: Set<String>, in store: MemoryStore) throws {
        guard let id = snapshot.id else { return }
        let cleaned = SemanticIndexing.strip(snapshot.content, boilerplate: boilerplate)
        let rows = SemanticIndexing.passages(cleaned).compactMap { p -> (text: String, vector: Data)? in
            guard let v = embedder.vector(p) else { return nil }
            return (p, SemanticIndexing.encode(v))
        }
        try store.replacePassages(snapshotId: id, passages: rows)
    }

    /// One-time catch-up for snapshots captured before this feature existed.
    /// Batched and resumable: `snapshotsMissingPassages` IS the cursor, so an
    /// interrupted run simply continues. ~20 minutes for 6,000 snapshots.
    func runBackfill(store: MemoryStore, batch: Int = 50,
                     progress: @Sendable (Int) -> Void = { _ in }) throws {
        var done = 0
        while true {
            let pending = try store.snapshotsMissingPassages(limit: batch)
            guard !pending.isEmpty else { return }
            let byApp = Dictionary(grouping: pending, by: \.appName)
            for (_, group) in byApp {
                let boilerplate = SemanticIndexing.boilerplateTokens(perAppTexts: group.map(\.content))
                for snapshot in group {
                    try index(snapshot: snapshot, boilerplate: boilerplate, in: store)
                    done += 1
                }
            }
            progress(done)
        }
    }
}
```

- [ ] **Step 2: Wire it in `AppState`**

Add `@ObservationIgnored private let memoryIndexer = MemoryIndexer()` beside the other memory
collaborators, and in the `memoryEnabled` setter's `if newValue` branch — after
`memoryCapture.start()` — kick the backfill off the main thread exactly as the history
importer does:

```swift
                startMemoryBackfillIfNeeded()
```

with:

```swift
    /// Fire-and-forget: search works in keyword-only mode until this finishes,
    /// so a failure here degrades quality rather than breaking the feature.
    private func startMemoryBackfillIfNeeded() {
        guard let store = memoryStore, let indexer = memoryIndexer else { return }
        Task.detached(priority: .utility) {
            do { try indexer.runBackfill(store: store) }
            catch { log.error("memory backfill failed: \(error)") }
        }
    }
```

Also index each new snapshot as it is captured: in the same place `MemoryCapture` writes a
snapshot, index it. **Read `MemoryCapture` first** — if it has no post-write hook, add one
closure (`onSnapshotStored`) rather than reaching into the store from two places.

- [ ] **Step 3: Full build + suite, then commit**

```bash
git add omwhisper-native/Memory/MemoryIndexer.swift omwhisper-native/AppState.swift
git commit -m "✨ feat(memory): index on capture, with a resumable one-time backfill"
```

---

### Task 6: Wire the UI

**Files:**
- Modify: `omwhisper-native/UI/HubMemorySectionView.swift`

**Interfaces:** consumes `hybridSearch`. No new API; pure SwiftUI, no unit tests (project convention).

- [ ] **Step 1: Use hybrid search and show the matched passage**

In the Snapshots tab's reload path, replace the `store.search(...)` call with
`store.hybridSearch(trimmed, embedder: appState.memoryEmbedder, limit: 100)` and keep the
snapshot rows rendering as they do — but when a row has a `matchedPassage`, show that instead
of the generic content preview. Expose the embedder from `AppState` as a stored
`@ObservationIgnored let memoryEmbedder: MemoryEmbedder? = AppleEmbedder()`.

Diversity, per the spike: when consecutive results share an `appName`, keep at most **3 in a
row** before preferring the next different app — one query in the spike returned three
near-identical windows of the same app.

- [ ] **Step 2: Full build + suite, then commit**

```bash
git add omwhisper-native/UI/HubMemorySectionView.swift omwhisper-native/AppState.swift
git commit -m "✨ feat(memory): semantic results in the hub, showing the matching passage"
```

---

### Task 7: Verification

- [ ] **Step 1: Rebuild and relaunch the dev app**

```bash
osascript -e 'tell application id "com.omwhisper.mac.dev" to quit' 2>/dev/null
DD=$(xcodebuild -showBuildSettings -scheme omwhisper-native -project omwhisper-native.xcodeproj -configuration Debug 2>/dev/null | grep -m1 "  BUILT_PRODUCTS_DIR" | sed 's/.*= //')
open "$DD/OmWhisper-Dev.app"
```

The dev build has its **own** `memory.db`, so it starts nearly empty. To exercise this against
real data, copy the production store into the dev container **once**, deliberately:

```bash
cp ~/Library/Application\ Support/com.omwhisper.mac/memory.db \
   ~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
```

- [ ] **Step 2: Live checklist (user)**

1. **The headline case** — search something you remember by *meaning*, not wording. The spike's
   example: "book an appointment for a medical scan" should surface the diagnostic/radiology
   pages even though none of those words appear in them.
2. **Matched passage** — a result shows the part that matched, not a generic preview.
3. **Exact search is no worse** — search a distinctive literal string (an error code, a name)
   and confirm it still lands.
4. **Diversity** — no query returns three near-identical windows of the same app.
5. **Degradation** — the feature must be invisible when it can't work. Hardest to check
   directly; the proxy is that search works normally *during* the backfill, before every
   snapshot has vectors.
6. **Backfill** — after enabling Memory on the copied store, the index fills in the background
   (~20 min for 6,000 snapshots) without the UI stuttering.
