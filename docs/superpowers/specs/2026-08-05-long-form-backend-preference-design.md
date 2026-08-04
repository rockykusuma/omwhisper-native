# Long-Form Backend Preference — Design

**Date:** 2026-08-05
**Status:** Approved. Pending an implementation plan.
**Area:** M3 polish backends — `AppState`'s backend selection, `BrainDumpStructurer`,
`MeetingStore`, `MemoryStore`.

## Problem

The single **AI Polish → Backend** setting has to serve two kinds of work with opposite
requirements, and no value of it is right for both.

| | Dictation polish | Meetings · chronicles · brain-dump |
|---|---|---|
| Input size | a sentence or two | a whole call, or a day |
| What matters | latency — you are waiting to paste | envelope — how much fits in one call |
| SystemLLM | ~2.1s, 1,800-char chunks | 1,800-char chunks → ~40 passes for an hour-long call |
| Ollama (qwen3.5) | 5.0s warm, 20.0s semi-warm, **36.4s cold** | 12,000-char chunks → ~6 passes, 300s timeout |

Ollama evicts a model after roughly five minutes idle, so **cold is the normal case, not an
edge case**. `Ollama.dictationTimeout` is 30 seconds. A first dictation after any gap therefore
exceeds the timeout, and M3's fail-safe pastes the raw text — correctly, and invisibly. The user
gets no polish at all most of the time and is never told.

So today's choice is:

- **Ollama selected** — good meeting summaries, dictation polish that silently does nothing
  after any idle period.
- **System selected** — fast reliable dictation polish, summaries compressed through ~40 lossy
  passes instead of ~6.

Both are measured, not hypothetical. This is a defect in the only two configurations available.

### Why this is newly worth fixing

A chronicles-only backend picker was proposed on 2026-08-01 and **rejected on the merits** — the
polish backend already expressed that choice, and a second control meant either a hidden global
change or a second concept, with Meetings, Brain-dump and Reply Assist each then wanting one.
That objection still stands and this design does not reopen it.

What changed is the premise. Apple Intelligence did not work at all on this machine then
(`supportedLanguages` excludes `en-IN`, and the app believed the model was usable — fixed
2026-08-01/02). There was one viable backend, so there was no trade to express. There are now
two, with measurably complementary strengths.

### The gap is narrower than it looks

`meetingSummaryBackends()` and `chronicleBackends()` do not pick a backend — they already build
a **preference list**, Ollama then SystemLLM. Long-form work is already treated differently from
dictation. The asymmetry is one condition:

```
polishBackend == .ollama  →  long-form: [Ollama, SystemLLM]
polishBackend == .system  →  long-form: [SystemLLM]          ← the gap
```

"Apple Intelligence for dictation, Ollama for long-form" is the one sensible configuration the
current design cannot express.

## The fix

**Long-form work prefers the backend that fits it, independent of the dictation setting.** No new
setting, no new concept — it completes a preference list the code already has.

```
any polishBackend  →  long-form: [Ollama (if a model is configured), SystemLLM (if available)]
                      dictation: activePolishBackend(), exactly as today
```

"Configured" means `!ollamaModel.isEmpty` — the same test `activePolishBackend()` and
`meetingSummaryBackends()` already use, so an empty model field remains the way to keep Ollama
out of every path. "Available" means `SystemLLM.isAvailable()`, which since 2026-08-01 checks
language support as well as availability.

Both candidates run on-device, so preferring the better-fitting one carries no privacy
consequence. `CloudLLM` is never constructed on this path, so "recordings and chronicles never
reach a cloud provider" remains enforced by code rather than by a setting.

### Scope

| Long-form — prefers Ollama, falls back to SystemLLM | Interactive — uses `activePolishBackend()` |
|---|---|
| Meeting summaries | Dictation polish |
| Meeting Ask, follow-up email | Smart Dictation |
| Chronicles | Polish Selected Text |
| Brain-dump structuring | Reply Assist |

The boundary is **large input with a deliberate wait**, not a list of feature names. That is what
keeps this from becoming the per-feature matrix the earlier proposal was rejected for.

## Architecture

### The decision is separated from the construction

`AppState` cannot be constructed in a test — its initialiser opens the real history and memory
stores, the same trap `KeychainTests` fell into when it was silently deleting real API keys. So
the decision must live outside it:

```swift
nonisolated enum LongFormBackends {
    enum Kind: Equatable { case ollama, system }

    /// Preference order for work with large inputs. Ollama first: its 12,000-character
    /// envelope turns an hour-long call into ~6 passes instead of ~40, and each extra
    /// compression pass loses detail.
    ///
    /// Deliberately NOT a function of `polishBackend` — that setting says what should
    /// polish your dictation, where latency dominates. Long-form work has the opposite
    /// shape. Cloud is absent by construction: recordings never egress.
    static func order(ollamaConfigured: Bool, systemAvailable: Bool) -> [Kind]
}
```

`AppState` maps kinds to instances and chunk limits:

```swift
private func longFormBackends(ollamaChunkLimit: Int,
                              systemChunkLimit: Int) -> [(polish: PolishBackend, chunkLimit: Int)]
```

`meetingSummaryBackends()` and `chronicleBackends()` — currently near-identical — collapse into
calls to this with their own constants. The rationale then lives in one place instead of two.

### Brain-dump joins, and gains a fallback

Brain-dump uses `activePolishBackend()` today, so it has exactly the defect being fixed: a long
ramble through a cold Ollama exceeds the 30-second dictation timeout and pastes raw. It also
never got the chunk-limit parameter its siblings have, so it would chunk at 1,800 even on Ollama.

- `BrainDumpStructurer.structure` gains `chunkLimit:`, matching `MeetingSummarizer.generate` and
  `Chronicler.generate`.
- The call site walks the same candidate list, so Ollama being down falls back to SystemLLM
  rather than straight to raw text — a small improvement it did not have before.

### Provenance is stored, not inferred

Which backend wrote a summary must be recorded at generation time; it cannot be recovered later.

- `meetings` gains `summaryBackend TEXT` (migration v3, following the v2 pattern).
- `chronicles` gains `backend TEXT`.
- Both are nullable — existing rows predate the column and must keep rendering.

Displayed as a short caption. The chronicle header already reads
*"1,436 snapshots · Written 4 Aug · on this Mac"*; it becomes
*"1,436 snapshots · Written 4 Aug · by Ollama (qwen3.5) · on this Mac"*. Meeting summaries get
the equivalent line. Model name included — "Ollama" alone does not distinguish a 3B model from a
9B one, which is the distinction that matters.

## Deliberate decisions

**Polish set to Disabled still gets long-form backends.** Today, Disabled already leaves
SystemLLM serving meetings and chronicles — "Disabled" has only ever disabled *dictation* polish.
Under this design it will also try Ollama first. Clicking *Transcribe & Summarize* is an explicit
request for AI, so this is right, but it is a behaviour change and is recorded here rather than
left to be discovered.

**Preferring Ollama is only better if the Ollama model is good.** A user with `llama3.2:3b`
configured and Apple Intelligence available would get *worse* summaries automatically — that
model was measured returning "Nothing relevant." to questions the transcript plainly answered.
The app cannot judge model quality, and adding a quality heuristic would be guesswork.

This is accepted, mitigated by provenance: a poor summary labelled *"by Ollama
(llama3.2:latest)"* tells the user exactly what to change, where today it would simply be
mysteriously bad. This is the whole reason the caption is part of the same change rather than a
follow-up.

**No new setting.** If someone wants long-form to use Apple Intelligence specifically, the lever
is clearing the Ollama model — the same lever that already controls whether Ollama is used at
all.

## Failure handling

- **Ollama configured but not running** — the connection is refused fast (not a timeout), and
  SystemLLM takes over. Costs roughly a second before the real work starts.
- **Ollama configured and running but slow** — `longFormTimeout` is already 300s on this path.
- **Neither available** — unchanged: today's "no backend" error, which distinguishes *no backend
  at all* from *every backend failed* from *nothing captured*.
- **A summary written by the fallback** is labelled as such, so a degraded result is legible
  rather than silent.

## Testing

- **`LongFormBackends.order`** across the matrix: neither available, Ollama only, System only,
  both. Pure, no `AppState`.
- **Ordering is Ollama-first when both exist** — reversing it would still return a non-empty list
  and pass a "did it pick something" test, so the assertion is on the order itself.
- **Independence from `polishBackend`** — the same order for `.system`, `.ollama`, `.cloud` and
  `.disabled`. This is the actual bug being fixed, so it gets its own test.
- **Cloud never appears**, for any input.
- **`BrainDumpStructurer.chunkLimit`** — a larger limit produces strictly fewer model calls, the
  assertion already used for `Chronicler`; accepting the parameter and ignoring it would pass a
  "did it still produce output" check.
- **Migrations** — an existing meeting and chronicle row written before the column still loads
  and renders, with the caption omitted rather than showing "by (null)".

Live: with polish set to **System**, generate a meeting summary and confirm the caption says
Ollama and the model name; stop Ollama and regenerate, and confirm it says Apple Intelligence
rather than failing. Both directions matter — the first proves the preference works, the second
proves the fallback does.

## Out of scope

A per-feature backend picker · a quality heuristic for choosing between models · changing any
timeout or chunk-limit constant · cloud backends on the long-form path · the dictation path.

## Exit criteria

With AI Polish set to System and an Ollama model configured, dictation polish uses Apple
Intelligence and completes in seconds, while meeting summaries and chronicles are written by
Ollama in its larger envelope; each stored summary records which backend wrote it and shows it;
with Ollama stopped, the same operations fall back to Apple Intelligence and say so; and no
configuration routes a recording or chronicle to a cloud provider.
