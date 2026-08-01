# Memory — Semantic Search — Design

**Date:** 2026-08-01
**Status:** Approved (brainstorming), pending the embedding spike, then an implementation plan
**Area:** S1/S5 Memory. First of two sub-projects; the unified timeline across memory /
history / meetings is a separate spec, not designed here.

## Problem

Memory search is FTS5 keyword matching over window-text snapshots. You must remember a word
that actually appeared: search "pricing" and a page that said "cost structure" is invisible.
That is the difference between a searchable log and something that finds what you meant, and
it is the single biggest gap between this feature and the products it competes with.

Measured on the real store (2026-08-01): **6,076 snapshots, 6,350 chars average, 20,502 max,
38.6 MB of text** — roughly three weeks of use, so plan for ~100k snapshots/year with the
existing 90-day retention bounding steady state near 26k.

## Decisions (brainstorming, 2026-08-01)

1. **A better results list, not answers.** Semantic ranking over the same snapshot list.
   **No LLM at query time** — fast, self-contained, and quality doesn't depend on a local
   model. An "ask Memory" box could sit on top later; it is out of scope here.
2. **Passages of ~1,000 chars**, not whole snapshots. A 6,350-char page collapsed to one
   vector is mush, and chunking is what lets the UI show *which* passage matched.
   ~6 passages/snapshot → ~40k vectors today.
3. **Embedder: `NLEmbedding.sentenceEmbedding`** — settled by the spike
   (`2026-08-01-memory-embedding-spike.md`, run 2026-08-01 on a copy of the real store).
   Comparable quality to `NLContextualEmbedding`, no model asset to download, and far cheaper
   on short text. ~218 ms/snapshot for full content; backfill of the existing 6,076 snapshots
   ≈ 20 minutes in the background. **Model choice is weakly evidenced** — if real-world
   quality disappoints, try a CoreML retrieval-trained bi-encoder before concluding semantic
   search cannot work; Apple's APIs are general-purpose similarity, not retrieval-trained.
4. **Hybrid, never a replacement.** Keyword search stays and still wins for names, error
   codes and IDs. If embeddings are unavailable or fail, search degrades silently to exactly
   today's behaviour.

## Architecture

| Piece | Responsibility |
|---|---|
| `BoilerplateFilter` | Pure. Strips tokens that recur across snapshots **of the same app**. The spike measured 58% of a median Arc snapshot as sidebar/pinned-tab chrome, and Arc is 59% of the corpus. Computing this globally instead of per-app found 32 tokens instead of 93 and barely helped — so per-app is load-bearing, not an optimisation. |
| `PassageChunker` | Pure. Snapshot text → ~1,000-char passages split on paragraph/sentence boundaries, never mid-word. Where the real logic lives; fully unit-tested. |
| `MemoryEmbedding` | Protocol with one method, text → `[Float]?`. The spike's winner implements it; the loser stays swappable. Returns nil on failure rather than throwing. |
| `MemoryStore` v2 | New `passages` table — `snapshotId`, `ordinal`, `text`, `vector BLOB` — with cascade delete so pruning a snapshot takes its passages. |
| `semanticSearch(query:limit:)` | Embed the query, cosine against stored vectors, return snapshots ranked, each carrying its best-matching passage. |

**No ANN index, deliberately.** ~40k dot products of 512 dims is a few million operations —
single-digit milliseconds with Accelerate's vDSP. An index would add real complexity for no
measurable gain at this scale. Revisit only if the corpus grows ~10×.

## Ranking

**Reciprocal rank fusion**, not a blended score. bm25 and cosine live on incompatible scales
and normalising them is a tuning rabbit hole with no correct answer. RRF merges two ranked
lists, needs no tuning, and is a pure function that tests exactly.

The result row shows the **matching passage** rather than a generic preview — the
quality-of-life win that only chunking makes possible.

**Results must be diversified.** The spike found one query whose entire top 3 was the same app
(`Claude` windows): plausible content, but three near-identical rows are a worse answer than
three distinct sources. Cap consecutive hits from the same app/window, or collapse
near-duplicates before display.

## Indexing

New snapshots are chunked and embedded on capture. Existing content-hash dedup means an
unchanged window costs nothing, which matters at a 5-second poll.

A one-time **backfill** processes the existing 6,076 snapshots in the background: resumable,
progress surfaced, never blocking the UI, and never blocking search — which keeps working in
keyword-only mode until the backfill completes.

## Storage

~1 KB per passage at 512 dims in float16. The existing 90-day retention bounds steady state
at roughly **160 MB**, collected by the prune that already runs. Int8 quantisation halves it
again if that ever matters; not worth doing pre-emptively.

## Failure handling

Every path degrades rather than breaks:

- Embedding unavailable at startup → semantic ranking is skipped, keyword search unchanged.
- A single passage fails to embed → that passage is skipped; the snapshot is still keyword-searchable.
- Backfill interrupted → resumes; partial coverage simply means partial semantic recall.
- Migration on an existing database must leave every current row searchable exactly as before.

## Testing

Pure and directly testable — the project's convention:

- `PassageChunker`: boundary splitting, no mid-word breaks, a single oversized paragraph, text
  shorter than one passage, empty input.
- RRF fusion: known input rankings → known merged order.
- Cosine similarity and the float16 vector serialisation round-trip.
- Migration: a v1 database with rows survives, stays keyword-searchable, gains empty passages.
- `semanticSearch` against an in-memory store with stub vectors — deterministic, no model.

The embedding model is settled by the **spike**, not by unit tests, and its result is written
back into this spec before implementation starts.

## The spike (runs first)

Measured on the real `memory.db` copy, both candidates, same passages, same queries:

1. **Retrieval quality** — a set of real queries where the wanted snapshot is known, including
   the paraphrase cases keyword search fails ("pricing" → "cost structure"). Report whether
   the target appears in the top 5.
2. **Cost per snapshot** — embedding ~6 passages must be comfortable inside a 5-second poll.
3. **Model availability** — whether `NLContextualEmbedding` needs an asset download, and what
   happens on a machine that lacks it.

Written up like `HOTWORD_SPIKE.md`: a named winner, the numbers behind it, and any
configuration that silently does nothing if set wrong.

## Out of scope

Answers/RAG over Memory · the unified timeline across memory, history and meetings · OCR or
screenshots · event-driven capture · entity extraction · importance-weighted retention ·
re-ranking models · any cloud path (Memory is local-only and stays that way).

## Exit criteria

A query whose wording never appears in the snapshot finds it anyway; the result shows the
passage that matched; exact-term search is no worse than today; the index survives a restart;
and with embeddings disabled or failed, Memory behaves exactly as it does now.
