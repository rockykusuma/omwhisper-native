# Memory — Embedding Spike Results

**Date:** 2026-08-01 · **Status:** ANSWERED — build it, with two design changes.
**Measured on:** a copy of the real `memory.db` (6,076 snapshots), never production.
**Companion to:** `2026-08-01-memory-semantic-search-design.md`.

## Verdict

**Semantic search works and is worth building.** Recommended embedder:
**`NLEmbedding.sentenceEmbedding`** — comparable retrieval quality to the contextual model,
no model asset to download, and far cheaper on short text (3 ms vs 12 ms per title).

Two design changes fall out of the measurements, both in §"What must change" below.

## The result that matters

For the query **"book an appointment for a medical scan"** — which shares no distinctive
keyword with any target — the top hits across conditions were:

- `medplus diagnostic gachibowli`
- `3 Tesla MRI in Hyderabad – High-Resolution Scans`
- `Book Advanced Radiology Scans & Lab Tests Online`

That is exactly the capability the feature exists for, and exactly what today's FTS5 keyword
search cannot do.

Model sanity was verified independently — cosine on clean pairs behaves correctly:

| Pair | Cosine |
|---|---|
| "a car" ↔ "an automobile" | 0.679 |
| "a car" ↔ "a banana" | 0.354 |
| "medical scan appointment" ↔ "radiology centre for MRI and CT" | 0.533 |
| "medical scan appointment" ↔ "azure devops pipeline build logs" | 0.322 |
| "reviewing code changes" ↔ "pull request code review comments" | 0.695 |

## Cost

| Condition | Per snapshot |
|---|---|
| NLEmbedding, full content (~6 passages) | ~218 ms |
| NLContextual, full content | ~173 ms |
| NLEmbedding, title only | ~3 ms |
| NLContextual, title only | ~12 ms |

Comfortable inside a 5-second capture poll. Backfilling 6,076 snapshots ≈ **20 minutes** in
the background — acceptable for a one-time job, but it must be resumable and must not block
search, which the design already requires.

`NLContextualEmbedding` reported `hasAvailableAssets = true` and loaded without a download on
this machine. That is **not** proof it is present everywhere — a reason to prefer the static
model, which has no asset dependency at all.

## What must change in the design

### 1. Boilerplate stripping must be per-app, not global

**58% of a typical Arc snapshot (median) is boilerplate** — the sidebar and pinned-tab list,
identical across snapshots. Arc is 3,582 of 6,076 snapshots, so this affects the majority of
the corpus. Even 900 characters into a snapshot the text is still tab titles and
"Back to Pinned URL", not page content.

Critically, computing boilerplate **globally across all apps found only 32 tokens**, while
computing it **within Arc alone found 93** covering that 58%. Chrome differs per app, so the
document-frequency threshold must be computed **per `appName`**, or the stripping does almost
nothing — which is what the "stripped" rows in the results table show.

### 2. Results need diversity, or one app swamps the list

For "reviewing code changes someone submitted", the entire top 3 was `Claude` windows —
plausible content, but a list of three near-identical snapshots is a worse answer than three
different sources. The result list should cap consecutive hits from the same app/window, or
collapse near-duplicates before display.

## Where this spike was wrong, and why it matters

The first metric was **top-5 recall of one specific snapshot ID**, which produced 0–1 out of 5
across every condition and looked like a flat failure. It was the *metric* that was broken:

- **Substring markers were meaningless.** `dev.azure.com` appears in **175 of 600** sampled
  snapshots because it is a pinned tab; `steveridgway` appeared in **zero**. Any "did the
  target appear" check built on them measures nothing.
- **The exact ID is not the only correct answer.** With 175 near-identical Azure DevOps pages,
  demanding one specific ID rank top-5 marks a correct topical result as a miss.

Both were caught only by printing the actual top-3 titles and reading them. **A number that
says 0/5 while the top hit is "medplus diagnostic gachibowli" for a medical-scan query is a
broken metric, not a broken feature** — the same trap as the truncated hypotheses that caused
a real misreading in the cross-engine WER work.

## Honest limits

- **Model choice is weakly evidenced.** Neither model clearly beat the other on quality; the
  recommendation rests mainly on cost and the absence of an asset dependency. If retrieval
  quality disappoints in real use, re-run with a CoreML retrieval-trained bi-encoder
  (e5-small / MiniLM class) before concluding semantic search cannot work — Apple's APIs are
  general-purpose similarity models, not retrieval-trained ones.
- Five queries, 400-snapshot sample, one machine. Direction is solid; the numbers are not
  precise.
- Mean-pooling 1,000-char passages is a blunt instrument. Smaller passages may retrieve
  better; that is a tuning question for implementation, not a blocker.

## Reproducing

`swift spike2.swift corpus.tsv` where the TSV is `id⇥title⇥text`, exported from a **copy** of
`memory.db`. The script compares both embedders across raw / stripped / title-only conditions
and prints the top-3 titles per query, which is the output worth reading.
