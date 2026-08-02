# Chronicles — Input Reduction and Progress — Design

**Date:** 2026-08-02
**Status:** Approved. Pending an implementation plan.
**Area:** S5.1 Chronicler. Follows `2026-08-01-chronicles-ollama-design.md`, which made
chronicles reachable on Ollama; this makes them affordable.

## Problem

`Chronicler.generate` feeds **every snapshot of the day** to the model. Measured on the real
store, 2026-08-02:

| | 2026-08-01 |
|---|---|
| Snapshots | 1,429 |
| Distinct apps | 17 |
| Distinct windows | 117 |
| 15-minute buckets with activity | 26 |
| Orca + Arc alone | 1,151 (**80%**) |

At `perSnapshotLimit = 500` that is ~715,000 characters, which at `ollamaChunkLimit = 12,000`
is **~60 sequential model calls** plus the collapse loop — for one paragraph of output. A live
run with qwen3.5 **did not finish in 20 minutes** and drove swap from 10.6 GB to 25 GB on a
16 GB Mac. (Two `xcodebuild` runs overlapped that window, so some of the pressure was not the
chronicle's — but it had not completed regardless.)

Volume roughly doubled when visible-windows capture shipped the same day, so this gets worse,
not better.

**The collapse loop already discards information** — it re-summarises summaries when they
overflow. So the app is paying an 8B model, at ~20 s per call, to throw away duplicates that a
cheap heuristic can throw away better.

Two further faults surfaced by the same run:

- **Generation is silent.** No progress, no cancel. Twenty minutes of unexplained Ollama load
  is indistinguishable from a hang.
- **The automatic run gives no indication at all**, and it fires *on launch* — so a heavy day
  is retried at the worst possible moment, every launch, until it succeeds.

## Decisions

1. **Reduce input by time + app bucketing**, before anything reaches the model. Keep the most
   substantial snapshot per (15-minute bucket, app). Predictable, cheap, and preserves the
   day's *shape* — which apps, in what order, for how long — which is what a chronicle is for.
2. **Progress and cancel**, covering the automatic run as well as the button.

Rejected: **semantic clustering** over the passage vectors — principled, and it reuses the
embeddings shipped today, but it needs threshold tuning (a rabbit hole with no correct answer),
loses time ordering, and makes chronicles depend on the semantic index being complete.
Rejected: **a flat cap with even sampling** — constant cost, but it weights a five-minute task
that produced 40 captures the same as an hour of focused work, and can miss a short but
important activity entirely.

## Architecture

| Piece | Responsibility |
|---|---|
| `Chronicler.select(_:bucketMinutes:cap:)` | **Pure.** Day's snapshots → the representative subset, chronologically ordered. Where all the new logic lives, and the only part worth unit-testing hard. |
| `Chronicler.formatBlock` | Gains the other window titles seen in the same (bucket, app) group. |
| `Chronicler.generate` | Calls `select` before `formatBlock`; gains a progress callback and cancellation checks. Chunking, the collapse loop and storage are **unchanged**. |
| `AppState` | Owns the running `Task`, exposes progress and `cancelChronicle()`. |
| `MemoryChroniclesView` | Renders progress; offers Cancel. |

### Selection

Group by `(bucket, appName)` where the bucket is the snapshot's local time floored to
`bucketMinutes` (default 15). Within a group keep the snapshot with the longest `content` —
the most substantial capture, not an arbitrary one. Emit chronologically, then apply `cap`
(default 400) as a backstop for a pathological day, keeping an even spread across the day
rather than truncating the tail.

Expected effect on 2026-08-01: 1,429 → roughly 100–150, so ~60 model calls become ~4.

**Window titles are preserved even when their bodies are not.** Titles are the highest-signal
content per character in a snapshot — file names, page titles, PR names. The kept block lists
the other titles seen in its group, so the chronicle still knows you were in those windows even
though only one body survives.

### Progress and cancellation

`generate` takes an optional `(completed: Int, total: Int) -> Void`, invoked before each model
call, where `total` is known once chunks are computed. It checks `Task.isCancelled` between
calls, so cancelling lands within one call rather than at the end of the run.

`AppState` holds the `Task` and the latest progress; the scheduler routes through the same
path, so the nightly run is visible too. **Cancelling writes nothing** — a partial chronicle is
worse than none, and the day can simply be regenerated.

## Failure handling

- Cancelled → no chronicle written, no error surfaced. Cancelling is not a failure.
- `select` returning empty for a day that *has* snapshots is a bug, not an empty day, and must
  stay distinguishable from `ChroniclerError.noSnapshots`.
- Backend selection, timeouts and the Ollama/SystemLLM fallback are untouched.

## Testing

`select` is pure, so it carries the real tests:

- Snapshots spanning a bucket boundary land in different buckets.
- Two apps in one bucket both survive; two snapshots of one app in one bucket collapse to one.
- The kept snapshot is the one with the longest content.
- Chronological order is preserved.
- The cap is enforced, and drops from across the day rather than only the tail.
- Empty input returns empty.
- **The test that fails if selection is a no-op:** a synthetic day of 1,429 snapshots across 17
  apps and 26 buckets must reduce to a bounded count. Asserting "it returns something" would
  pass whether or not selection did anything.
- Other window titles from a group appear in the kept block.

Progress: monotonic, and the final value equals the total. Cancellation is verified live — a
timing-dependent async cancel is exactly the kind of test that passes for the wrong reason.

## The accepted cost

A genuine burst of distinct work inside one 15-minute window in one app collapses to a single
entry. Preserved titles soften this; they do not remove it. Stated plainly because it is a real
loss of fidelity, not a free win — accepted because the alternative is ~60 sequential model
calls and a swap storm.

## Out of scope

Semantic clustering · changing capture volume or the 5-second poll · chronicle templates ·
changing the daily schedule or the local-day boundary · regenerating past days · streaming
partial chronicles.

## Exit criteria

A day of ~1,400 snapshots produces a chronicle in a small number of model calls rather than
~60; the chronicle still names the apps and windows the day was spent in; progress is visible
for both the button and the automatic run; Cancel stops a run within one model call and writes
nothing; and a day of ~50 snapshots behaves exactly as it does today.
