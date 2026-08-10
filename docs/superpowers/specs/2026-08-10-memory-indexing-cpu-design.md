# Memory indexing burns a core — design

**Date:** 2026-08-10
**Status:** approved in principle (R, 2026-08-10)

## The measurement

R's system monitor showed **OmWhisper at 175.3% CPU**, top process, top battery drain
("Top drain OmWhisper · 120.3"), on a 16 GB M2 Pro at 86°C.

Measured properly afterwards — cumulative CPU time over a 60-second wall clock, not
instantaneous `top` — the steady state is **57.7% of one core, sustained, indefinitely**.

A stack profile locates it exactly, in both Release and Debug builds:

```
AppState.indexPendingMemory()
  MemoryIndexer.processPending()
    MemoryIndexer.index(snapshot:boilerplate:in:)
      AppleEmbedder.vector(_:)
        -[NLEmbedding vectorForString:]
          libBNNS                        ← ~4,460 top-of-stack samples
```

Not audio, not the AX walks, not SwiftUI. **An early reading of "SwiftUI dominates" was wrong**
— it came from *in-stack* counts, which include the parked main thread's runloop. Top-of-stack
is the only honest measure of where CPU is, and by it nothing else comes close.

## The defect: most of the work is repeated

On the real store:

| | |
|---|---|
| passages | 70,835 |
| distinct passage texts | 30,578 |
| **redundant embeddings** | **57%** |
| most-duplicated single text | embedded **285 times** |

Memory captures the same window every 5 seconds. One line changes, so the snapshot is new and
correctly re-indexed — but **every passage is embedded again from scratch, including the ones
byte-identical to the previous capture.** `AppleEmbedder.vector(_:)` calls `NLEmbedding` every
time; there is no cache anywhere in the path.

This is inherent to how capture works, so it does not improve on its own. It gets worse as the
store grows, because repeat captures dominate over novel ones.

## Decision 1 — cache vectors by passage text

Look the vector up before embedding. Same text → same vector, always: `NLEmbedding` is
deterministic, so this is a pure memoisation with no behaviour change and no new setting.

**Keyed by a SHA-256 of the text, not the text itself.** Average passage is 882 chars and there
are 59 MB of passage text; a unique index on that column would cost tens of MB for no benefit
over a 32-byte digest.

**Never `Hasher`/`hashValue`.** Swift's standard hashing is randomly seeded per process, so a
persisted key built from it would miss on every launch — silently, looking exactly like a cache
that simply does not help. This trap gets its own test.

**A separate table, not a column on `passages`.** `passage_vectors(hash TEXT PRIMARY KEY,
vector BLOB NOT NULL)` needs no migration of the 70,835 existing rows and no backfill pass: it
starts empty and fills from live indexing. Adding a `hash` column to `passages` would mean
migrating every row before the cache did anything.

Bounded by distinct texts rather than captures — ~30 MB at today's store size. Cache rows no
longer referenced by any passage are deleted alongside the existing snapshot prune, so it
cannot outgrow the data it serves.

**Rejected — an in-memory LRU instead of a table.** It would help within one backfill run and
be empty again at every launch, which is exactly when the spike happens. A SQLite lookup is
microseconds against an `NLEmbedding` call; the round trip is not the cost.

## Decision 2 — pace the backlog instead of stampeding it

`processPending(store:batch:maxBatches:progress:)` defaults to `maxBatches: Int.max`, and
`AppState.indexPendingMemory()` passes no limit — so one invocation runs the **entire** pending
queue flat out with no yielding. That is the most likely explanation for the 175% peak (a
relaunch with a backlog), though it was not isolated and this spec does not claim it was.

The fix follows the design already in `MemoryIndexer`'s own header: incremental indexing and
the backfill are the same self-healing, resumable path. So the per-capture call takes a small
`maxBatches`, and a backlog drains over successive capture ticks instead of in one burst. No
cursor, no new state, no async rewrite of a synchronous function.

The initial catch-up at enable time keeps a larger bound — a first-run backfill is work the
user is implicitly waiting for, unlike the steady trickle.

## What this does not do

- **No policy change.** Indexing only on AC power, or only when idle, is a real option and
  deliberately not taken here. The redundancy is the defect; adding a policy on top of wasted
  work would hide it rather than fix it. Revisit if 57.7% does not fall far enough.
- **No change to what is captured or how often.** The 5s cadence and the AX capture path are
  untouched.
- **Semantic search behaviour is identical.** Same vectors, same results — this is memoisation.

## Testing

The cache is directly testable with a counting fake embedder, which is what makes this
falsifiable rather than hopeful:

- Indexing two snapshots whose passages are identical calls the embedder **once**, not twice.
  A cache that silently never hits would pass any "does it still index?" check; only a call
  count catches it.
- A genuinely new passage still calls the embedder — the half that fails if the cache returns
  something wrong for a miss.
- The stored vector for a cache hit equals the vector for a miss, byte for byte. A cache that
  returns a *different* vector would still search, just worse, and nothing else would notice.
- The hash is stable across separate computations of the same string, and differs for different
  strings. This is the `Hasher` trap; without this test a per-process-seeded hash looks like a
  working cache that never hits.
- `processPending` honours `maxBatches` — it must stop, and a later call must resume and finish.
  A bound that is accepted and ignored would pass a "did it eventually index everything?" test.

**Not unit-testable, and the number that actually matters:** the CPU cost. Verified by the same
method used to find it — cumulative CPU seconds over a 60-second wall clock, before and after,
on the same store with Memory enabled. **57.7% of a core is the baseline to beat**, and the
result is recorded whatever it turns out to be, including if the cache disappoints.

## Result (2026-08-10)

| | sustained CPU |
|---|---|
| before | **57.7%** of one core |
| after | **15.9%** of one core |

**A 72% reduction**, measured the same way on the same store, both after a 60-second settle.

Store at the time: 71,761 passages holding 30,872 distinct texts — **56% redundancy**, matching
the figure the change was designed against. So the ratio is structural, not a one-off backlog:
capture keeps producing snapshots whose passages are mostly text already embedded, and the
cache keeps absorbing them.

**15.9% is not nothing, and the remaining cost is real work**, not waste: the ~44% of passages
that are genuinely new still have to be embedded, and the AX capture walk and SQLite writes
continue regardless. The rejected power/idle policy is the lever left if that is still too
much — the argument against it (that it would hide the redundancy) has now expired, since the
redundancy is gone.

**Not yet verified:** whether this shows up as a battery-drain ranking change over a normal
working day. A 60-second measurement is not a soak test.
