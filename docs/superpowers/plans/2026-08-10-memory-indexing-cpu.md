# Memory indexing CPU — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop re-embedding text the app has already embedded. Baseline to beat: **57.7% of one core, sustained**.

**Architecture:** Passage vectors are a pure function of passage text, so embedding is memoisable. Rather than a separate cache table, `passages` gains an indexed `textHash` column — the 70,835 rows already in the store then *are* the cache, and pruning stays free because the cascade already deletes them. `MemoryIndexer` looks a vector up by hash before calling `NLEmbedding`. Separately, the per-capture call gets a batch bound so a backlog drains over ticks instead of stampeding.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), GRDB migrations, Swift Testing, CryptoKit (already imported in `MemoryStore`).

## Deviation from the spec, made during planning

The spec chose a **separate `passage_vectors` table**, reasoning that it "needs no migration of the 70,835 existing rows". That reasoning was wrong on the economics, and this plan does the opposite: **add an indexed `textHash` column to `passages`.**

Why the change:

- **The migration is cheap.** It hashes text; it does not embed. SHA-256 over 70k × ~882 chars is well under a second — nothing like the ML work being avoided.
- **It makes the existing corpus the cache immediately.** A separate table starts empty, so every already-seen passage gets embedded once more before the cache helps. With a column, the 30,578 distinct vectors already stored are hits from the first indexing pass.
- **No duplicate vector storage.** A separate table would hold a second copy of ~30 MB of vectors. A hash column costs 64 bytes per row plus an index (~5–7 MB total).
- **Pruning stays free.** The spec had to invent cache eviction. Passages already cascade-delete with their snapshot, so there is nothing new to prune and no way for the cache to outlive its data.

Everything else in the spec stands, including the SHA-256-not-`Hasher` rule and the measurement protocol.

## Global Constraints

- **`MemoryStore.contentHash(_:)` already exists** and is SHA-256 hex. Reuse it. Do not add a second hashing helper, and never use `Hasher`/`hashValue` for a persisted key — Swift's standard hashing is randomly seeded per process, so it would miss on every launch and look exactly like a cache that merely does not help much.
- **Semantic search results must not change.** This is memoisation: same text → same vector. Any change in search behaviour is a bug in this work.
- **`MemoryStore` and `MemoryIndexer` are `nonisolated`/`Sendable`** — they run off the UI thread. New members follow suit, as every existing one does.
- **Constructing `AppState` in a test opens the real stores.** No test here may construct it.
- Full suite before this work: **556 tests in 83 suites**. Run `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test` after every task; it must stay green and grow.

---

### Task 1: Give passages an indexed content hash

**Files:**
- Modify: `omwhisper-native/Memory/MemoryStore.swift`
- Test: `omwhisper-nativeTests/MemoryStoreTests.swift`

**Interfaces:**
- Consumes: `MemoryStore.contentHash(_:)` (exists).
- Produces:
  - `MemoryPassage.textHash: String`
  - `MemoryStore.vectorForText(hash: String) throws -> Data?`

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MemoryStoreTests.swift`:

```swift
@Suite("Passage vector reuse")
struct PassageVectorReuseTests {
    private func store() throws -> MemoryStore {
        try MemoryStore.open(atPath: ":memory:")
    }

    @Test("a stored passage's vector is findable by its text hash")
    func vectorIsFindableByHash() throws {
        let s = try store()
        let id = try s.upsert(MemorySnapshot(
            id: nil, bundleID: "com.test", appName: "Test", windowTitle: "w",
            url: nil, content: "body", contentHash: "h1",
            capturedAt: "2026-08-10T00:00:00Z", lastSeenAt: "2026-08-10T00:00:00Z"))
        let vector = Data([1, 2, 3, 4])
        try s.replacePassages(snapshotId: id, passages: [(text: "hello world", vector: vector)])

        #expect(try s.vectorForText(hash: MemoryStore.contentHash("hello world")) == vector)
    }

    @Test("unknown text has no vector")
    func unknownTextMisses() throws {
        // The half that makes this real: a lookup that returned *some* vector
        // for anything would pass the test above and silently corrupt search.
        let s = try store()
        #expect(try s.vectorForText(hash: MemoryStore.contentHash("never seen")) == nil)
    }

    @Test("the hash is stable across separate computations")
    func hashIsStable() {
        // The Hasher trap. Swift's hashValue is randomly seeded per process, so
        // a persisted key built from it would miss on every launch — silently,
        // looking exactly like a cache that just doesn't help much.
        #expect(MemoryStore.contentHash("same text") == MemoryStore.contentHash("same text"))
        #expect(MemoryStore.contentHash("a") != MemoryStore.contentHash("b"))
    }

    @Test("deleting a snapshot takes its cached vectors with it")
    func pruneRemovesVectors() throws {
        // Passages cascade with their snapshot, so there is no separate cache
        // to evict. This pins that, because the day it stops being true the
        // store grows forever.
        let s = try store()
        let id = try s.upsert(MemorySnapshot(
            id: nil, bundleID: "com.test", appName: "Test", windowTitle: "w",
            url: nil, content: "body", contentHash: "h2",
            capturedAt: "2026-08-10T00:00:00Z", lastSeenAt: "2026-08-10T00:00:00Z"))
        try s.replacePassages(snapshotId: id, passages: [(text: "doomed", vector: Data([9]))])
        #expect(try s.vectorForText(hash: MemoryStore.contentHash("doomed")) != nil)

        try s.delete(id: id)
        #expect(try s.vectorForText(hash: MemoryStore.contentHash("doomed")) == nil)
    }
}
```

If `MemoryStore.open(atPath:)`, `upsert`, or `delete(id:)` have different names or signatures in
this file, use whatever the existing `MemoryStoreTests` helpers already use — do not invent new
store APIs for the test.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED"`
Expected: compile failure — `vectorForText(hash:)` does not exist.

- [ ] **Step 3: Add the column, index, backfill and lookup**

In `omwhisper-native/Memory/MemoryStore.swift`, add `textHash` to the record:

```swift
nonisolated struct MemoryPassage: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "passages"
    var id: Int64?
    var snapshotId: Int64
    var ordinal: Int
    var text: String
    var vector: Data          // float16, see SemanticIndexing.encode
    /// SHA-256 of `text`, so an identical passage can reuse an existing vector
    /// instead of being embedded again. 57% of all passages were duplicates of
    /// text already embedded — one of them 285 times over.
    var textHash: String = ""

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

Register a migration after `chronicleProvenance`:

```swift
        migrator.registerMigration("passageTextHash") { db in
            try db.alter(table: MemoryPassage.databaseTableName) { t in
                t.add(column: "textHash", .text).notNull().defaults(to: "")
            }
            // Backfill in SQL-driven batches rather than fetching every row:
            // this runs on a store that already holds ~70k passages and ~59 MB
            // of text. Hashing is cheap (SHA-256, not embedding) but loading it
            // all at once is not.
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM passages")
            for chunk in stride(from: 0, to: ids.count, by: 500) {
                let slice = Array(ids[chunk..<min(chunk + 500, ids.count)])
                let rows = try Row.fetchAll(
                    db, sql: "SELECT id, text FROM passages WHERE id IN (\(slice.map { _ in "?" }.joined(separator: ",")))",
                    arguments: StatementArguments(slice))
                for row in rows {
                    let id: Int64 = row["id"]
                    let text: String = row["text"]
                    try db.execute(sql: "UPDATE passages SET textHash = ? WHERE id = ?",
                                   arguments: [contentHash(text), id])
                }
            }
            try db.create(index: "passages_text_hash", on: MemoryPassage.databaseTableName,
                          columns: ["textHash"])
        }
```

Set the hash on write, in `replacePassages`:

```swift
            for (i, p) in passages.enumerated() {
                var row = MemoryPassage(id: nil, snapshotId: snapshotId, ordinal: i,
                                        text: p.text, vector: p.vector,
                                        textHash: Self.contentHash(p.text))
                try row.insert(db)
            }
```

Add the lookup beside `snapshotsMissingPassages`:

```swift
    /// Any previously stored vector for this exact passage text.
    ///
    /// Embedding is deterministic, so any row with the same text carries the
    /// same vector and the first one found is as good as any. This is what
    /// turns the passages already in the store into the embedding cache —
    /// there is no separate cache table to fill, prune, or get out of step.
    func vectorForText(hash: String) throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT vector FROM passages WHERE textHash = ? LIMIT 1",
                              arguments: [hash])
        }
    }
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, count above 556.

- [ ] **Step 5: Run the migration against the REAL dev store**

Unit tests only ever see a fresh in-memory database, so they cannot catch a migration that
fails on real data — the lesson from the meetings v2 migration.

```bash
pkill -f "OmWhisper-Dev"; sleep 2      # SQLite writes fail while the app holds the file
DB=~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
cp "$DB" /tmp/memory-backup.db
sqlite3 "$DB" "SELECT COUNT(*) FROM passages;"          # note this number
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build
open ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/Build/Products/Debug/OmWhisper-Dev.app
sleep 30
sqlite3 "$DB" "SELECT COUNT(*) FROM passages;"                        # unchanged
sqlite3 "$DB" "SELECT COUNT(*) FROM passages WHERE textHash = '';"    # must be 0
sqlite3 "$DB" "SELECT COUNT(DISTINCT textHash) FROM passages;"        # ≈ 30,578
```

The third query is the one that can fail: a backfill that silently skipped rows leaves empty
hashes, and every one of those is a permanent cache miss.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Memory/MemoryStore.swift omwhisper-nativeTests/MemoryStoreTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(memory): index passages by content hash so vectors can be reused

Embedding is a pure function of passage text, so it is memoisable —
and 57% of all passages hold text that was already embedded, one of
them 285 times over.

A hash COLUMN rather than the separate cache table the spec proposed:
the migration only hashes text (cheap — SHA-256, not inference), and
in exchange the 70,835 rows already in the store become the cache
immediately instead of a new table starting cold. It also avoids a
second copy of ~30 MB of vectors, and pruning stays free because
passages already cascade with their snapshot.

SHA-256 via the existing contentHash, never Hasher: Swift's standard
hashing is randomly seeded per process, so a persisted key from it
would miss on every launch and look exactly like a cache that just
doesn't help much. Pinned by a test.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 2: Reuse the vector instead of embedding again

**Files:**
- Modify: `omwhisper-native/Memory/MemoryIndexer.swift`
- Test: `omwhisper-nativeTests/MemoryIndexerTests.swift` (create if absent)

**Interfaces:**
- Consumes: `MemoryStore.vectorForText(hash:)`, `MemoryStore.contentHash(_:)` (Task 1).
- Produces: no new API — `index(snapshot:boilerplate:in:)` gains the lookup.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
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

    private func snapshot(_ content: String, hash: String) -> MemorySnapshot {
        MemorySnapshot(id: nil, bundleID: "com.test", appName: "Test", windowTitle: "w",
                       url: nil, content: content, contentHash: hash,
                       capturedAt: "2026-08-10T00:00:00Z", lastSeenAt: "2026-08-10T00:00:00Z")
    }

    @Test("identical passage text is embedded once, not twice")
    func repeatedTextIsEmbeddedOnce() throws {
        // The whole point of the change. Capture takes the same window every
        // 5s; one line changes; every passage used to be redone from scratch.
        let store = try MemoryStore.open(atPath: ":memory:")
        let embedder = CountingEmbedder()
        let indexer = MemoryIndexer(embedder: embedder)!
        let body = String(repeating: "the quarterly report is attached for review. ", count: 20)

        let a = try store.upsert(snapshot(body, hash: "h1"))
        try indexer.index(snapshot: try #require(store.get(id: a)), boilerplate: [], in: store)
        let afterFirst = embedder.calls
        #expect(afterFirst > 0, "nothing was embedded at all")

        let b = try store.upsert(snapshot(body, hash: "h2"))
        try indexer.index(snapshot: try #require(store.get(id: b)), boilerplate: [], in: store)

        #expect(embedder.calls == afterFirst, "the second snapshot re-embedded identical text")
    }

    @Test("new text is still embedded")
    func newTextIsEmbedded() throws {
        // The half that fails if the lookup returns something for everything.
        let store = try MemoryStore.open(atPath: ":memory:")
        let embedder = CountingEmbedder()
        let indexer = MemoryIndexer(embedder: embedder)!

        let a = try store.upsert(snapshot(String(repeating: "alpha beta gamma delta. ", count: 20), hash: "h1"))
        try indexer.index(snapshot: try #require(store.get(id: a)), boilerplate: [], in: store)
        let afterFirst = embedder.calls

        let b = try store.upsert(snapshot(String(repeating: "entirely different words here. ", count: 20), hash: "h2"))
        try indexer.index(snapshot: try #require(store.get(id: b)), boilerplate: [], in: store)

        #expect(embedder.calls > afterFirst, "genuinely new text was not embedded")
    }

    @Test("a reused vector is byte-identical to a freshly embedded one")
    func reusedVectorMatches() throws {
        // A cache returning a DIFFERENT vector would still search, just worse,
        // and nothing else in the suite would notice.
        let store = try MemoryStore.open(atPath: ":memory:")
        let indexer = MemoryIndexer(embedder: CountingEmbedder())!
        let body = String(repeating: "identical content for both snapshots. ", count: 20)

        let a = try store.upsert(snapshot(body, hash: "h1"))
        try indexer.index(snapshot: try #require(store.get(id: a)), boilerplate: [], in: store)
        let b = try store.upsert(snapshot(body, hash: "h2"))
        try indexer.index(snapshot: try #require(store.get(id: b)), boilerplate: [], in: store)

        let vectors = try store.allPassageVectors()
        let forA = vectors.filter { $0.snapshotId == a }.sorted { $0.ordinal < $1.ordinal }
        let forB = vectors.filter { $0.snapshotId == b }.sorted { $0.ordinal < $1.ordinal }
        #expect(!forA.isEmpty)
        #expect(forA.map(\.vector) == forB.map(\.vector))
    }
}
```

`MemoryIndexer.index` and `MemoryStore.get(id:)` must be reachable from the test target. If
`get(id:)` does not exist, fetch the snapshot with whatever accessor `MemoryStoreTests` already
uses rather than adding one.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|recorded an issue|Test run with"`
Expected: `repeatedTextIsEmbeddedOnce` fails — the second snapshot re-embeds, so the call count doubles.

- [ ] **Step 3: Implement**

In `omwhisper-native/Memory/MemoryIndexer.swift`, replace the body of `index`:

```swift
    func index(snapshot: MemorySnapshot, boilerplate: Set<String>, in store: MemoryStore) throws {
        guard let id = snapshot.id else { return }
        let cleaned = SemanticIndexing.strip(snapshot.content, boilerplate: boilerplate)
        var rows: [(text: String, vector: Data)] = []
        for p in SemanticIndexing.passages(cleaned) {
            // Reuse before embedding. Capture takes the same window every few
            // seconds and one line changes, so most passages of a "new"
            // snapshot are byte-identical to ones already embedded — measured
            // at 57% of all passages, one text 285 times over.
            if let cached = try store.vectorForText(hash: MemoryStore.contentHash(p)) {
                rows.append((p, cached))
                continue
            }
            guard let v = embedder.vector(p) else { continue }
            rows.append((p, SemanticIndexing.encode(v)))
        }
        // Even with no embeddable passages, write the (empty) result so this
        // snapshot leaves the pending set -- otherwise one unembeddable row
        // would be retried forever and block the backfill behind it.
        try store.replacePassages(snapshotId: id, passages: rows)
    }
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Prove the cache is load-bearing**

Temporarily change the lookup to `if false, let cached = …`, run the suite, and confirm
`repeatedTextIsEmbeddedOnce` fails. Restore it. A cache that never hits produces identical
output, so without this the test could be passing for the wrong reason.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Memory/MemoryIndexer.swift omwhisper-nativeTests/MemoryIndexerTests.swift
git commit -m "$(cat <<'EOF'
⚡️ perf(memory): reuse a stored vector instead of embedding the same text again

Memory indexing was burning 57.7% of one core, sustained, and was the
machine's top battery drain — measured by cumulative CPU seconds over
a 60s wall clock, and located by stack profile to NLEmbedding under
MemoryIndexer in both Release and Debug.

Most of that work was repetition, not volume: 70,835 passages held
30,578 distinct texts, so 57% of every embedding redid text already
embedded. Capture takes the same window every 5s, one line changes,
and the identical passages were redone from scratch.

Tested with a counting embedder, because a cache that never hits
produces byte-identical output — only a call count can tell the
difference. Proven load-bearing by disabling the lookup and watching
the test go red.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 3: Pace the backlog, then measure the result

**Files:**
- Modify: `omwhisper-native/AppState.swift`
- Modify: `docs/superpowers/specs/2026-08-10-memory-indexing-cpu-design.md`
- Test: `omwhisper-nativeTests/MemoryIndexerTests.swift`

**Interfaces:**
- Consumes: everything above. No new API.

- [ ] **Step 1: Write the failing test**

```swift
    @Test("maxBatches is honoured, and a later call resumes")
    func batchBoundIsHonoured() throws {
        // A bound that is accepted and ignored would pass "did everything get
        // indexed eventually?" — this asserts it STOPS, then finishes later.
        let store = try MemoryStore.open(atPath: ":memory:")
        let indexer = MemoryIndexer(embedder: CountingEmbedder())!
        for i in 0..<7 {
            _ = try store.upsert(snapshot("body number \(i) with enough words to make a passage",
                                          hash: "h\(i)"))
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
```

- [ ] **Step 2: Run it and verify it passes or fails honestly**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "recorded an issue|Test run with|TEST SUCCEEDED"`

`processPending` already implements `maxBatches`, so this test may pass immediately. That is
fine and worth having: it pins behaviour Task 3 is about to depend on. If it fails, the bound
is broken and must be fixed before continuing.

- [ ] **Step 3: Bound the per-capture call**

In `omwhisper-native/AppState.swift`, `indexPendingMemory()` currently passes no bound, so one
invocation drains the entire queue flat out — the most likely source of the 175% spike after a
relaunch with a backlog.

```swift
    /// Embed whatever snapshots don't have passages yet — the same call serves
    /// the one-time backfill and the per-capture trickle. Fire-and-forget: while
    /// it runs, and if it fails, Memory search simply stays keyword-only, which
    /// is exactly the behaviour before this feature existed.
    ///
    /// `maxBatches` bounds ONE invocation. A backlog therefore drains across
    /// successive capture ticks instead of monopolising the machine in a single
    /// burst — which is what MemoryIndexer's own header already describes as a
    /// self-healing, resumable design, so it needs no cursor and no new state.
    /// `catchUp` is the enable-time and launch-time call, where the user is
    /// implicitly waiting for a first index and a larger bound is right.
    private func indexPendingMemory(catchUp: Bool = false) {
        guard !isIndexingMemory, let store = memoryStore, let indexer = memoryIndexer else { return }
        isIndexingMemory = true
        let maxBatches = catchUp ? 20 : 1
        Task.detached(priority: .utility) { [weak self] in
            do { _ = try indexer.processPending(store: store, maxBatches: maxBatches) }
            catch { log.error("memory indexing failed: \(error)") }
            await MainActor.run { self?.isIndexingMemory = false }
        }
    }
```

and at the enable-time call site, `indexPendingMemory(catchUp: true)`. The per-capture site
(`memoryCapture.onSnapshotStored`) keeps the default.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Measure, and record whatever it says**

This is the number the whole plan exists for, and it is recorded honestly even if the cache
disappoints. Use the same method that produced the baseline — cumulative CPU seconds over a
fixed wall clock, because instantaneous `top` swings wildly enough to support any conclusion.

```bash
open ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/Build/Products/Debug/OmWhisper-Dev.app
sleep 60      # let launch-time indexing settle
DEV=$(pgrep -f "OmWhisper-Dev" | head -1)
secs() { ps -o time= -p "$1" | tr -d ' ' | awk -F: '{n=NF;s=0;m=1;for(i=n;i>=1;i--){s+=$i*m;m*=60} print s}'; }
A=$(secs "$DEV"); sleep 60; B=$(secs "$DEV")
echo "$(echo "scale=1; ($B - $A) * 100 / 60" | bc)% of one core, sustained"
```

Also record the cache hit rate, which explains the CPU number either way:

```bash
DB=~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
sqlite3 "$DB" "SELECT 'passages: '||COUNT(*)||'  distinct texts: '||COUNT(DISTINCT textHash) FROM passages;"
```

Write both into the design doc under a **Result** heading: the before (57.7%), the after, and
the hit rate. **If the after is not meaningfully better, say so plainly** — that is the signal
to reconsider the rejected power/idle policy, and burying it would waste the measurement.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-nativeTests/MemoryIndexerTests.swift docs/superpowers/specs/2026-08-10-memory-indexing-cpu-design.md
git commit -m "$(cat <<'EOF'
⚡️ perf(memory): drain the indexing backlog over ticks, not in one burst

indexPendingMemory passed no bound, so a single invocation ran the
entire pending queue flat out — the most likely source of the 175%
spike after a relaunch with a backlog, though that was never isolated
and this does not claim it was.

The per-capture call now does one batch and lets the next tick
continue, which is exactly the self-healing resumable design
MemoryIndexer's own header describes. The enable-time catch-up keeps a
larger bound, since a first index is work the user is waiting for.

Measured result recorded in the design doc.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

## After this plan

- **If CPU is still high**, the rejected option becomes live: index only on AC power or when the
  machine is idle. It was rejected because the redundancy was the defect and a policy would
  hide it — that argument expires once the redundancy is gone.
- **The Release build's 175% was never isolated.** It is attributed to an unbounded backlog on
  relaunch, which Task 3 addresses, but the A/B that would have proved it (window open vs
  closed) came back inside the noise. If spikes persist on 2.0.10, that thread is still open.
- **Whatever lands here wants a real-usage soak**, not a 60-second measurement: leave the app
  running a normal working day and check the battery-drain ranking again.
