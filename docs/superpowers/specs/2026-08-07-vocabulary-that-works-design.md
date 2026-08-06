# Vocabulary that actually changes the transcript — design

**Date:** 2026-08-07
**Status:** approved in principle (R, 2026-08-07 — "go with your recommendation")

## The problem, stated as narrowly as the evidence supports

Adding a term to the Vocabulary tab does **nothing on the default configuration**. Three
independent facts compose to that:

1. **Engine biasing is measured inert.** `--wer` on 2026-08-01 showed Apple Speech and both
   Parakeet variants emit byte-identical transcripts with and without a vocabulary list. Apple
   is the default engine.
2. **Fuzzy correction is off by default** — `fuzzyVocabCorrection` reads `?? false`. So the one
   mechanism that *does* consume `customVocabulary` post-hoc is not running.
3. **Replacement rules are hand-authored.** They work, but the user has to predict the
   misrecognition and type both sides: to fix `appcast` you must already know the engine writes
   "app cast".

So a user who types `appcast`, `WhisperKit` and `Vercel` into the vocabulary list, changes
nothing else, and dictates gets exactly the same text as a user who left it empty.

### What is NOT established

The tracker and the `vocabulary-biasing-does-nothing-on-apple` memory are correct about
biasing. They do not establish that the *feature* does nothing, and this spec must not repeat
that error in the other direction.

**`WERBenchmark` never applies `applyReplacements` or `fuzzyCorrect`.** It calls
`MeetingTranscriber.transcribeFile` and scores raw engine output. So the user-visible pipeline
has never been measured at all — not with fuzzy on, not with fuzzy off. Any claim about how
much correction helps is currently unmeasured in both directions.

This is the same shape as criterion #4 being recorded as met on the strength of code existing.
The first sub-project therefore measures before anything is changed.

## The failures, from the real corpus

```
reference   … I pushed the appcast to Vercel … notarize … settings pane shipped.
Apple, off  … I pushed the app cast to Versal … notarise … settings pain ship.
```

| Failure | Kind | Reachable by today's post-processing? |
|---|---|---|
| `appcast` → "app cast" | compound split | **No.** `fuzzyCorrect` walks whitespace-delimited tokens and never joins across them. Structurally unreachable at any threshold. |
| `Vercel` → "Versal" | phonetic near-miss | **No.** Distance 2 on a 6-char token; `maxDistance(forTokenLength:)` allows 1 for 4...6. |
| `notarize` → "notarise" | spelling variant | **Yes** — distance 1, 8 chars, allowed 2. Already corrected for a user with fuzzy on. |
| `pane` → "pain" | homophone, both real words | No, and out of scope. Not a vocabulary term; fixing it needs context, not a word list. |

Two of the four are tractable. One already works and has simply never been counted.

## Design

Three sub-projects, strictly ordered. The first has to land before the others can be judged.

### SP1 — measure the pipeline the user actually gets

`WERBenchmark` scores each hypothesis **twice from one transcription pass**: raw, and after the
real post-processing (`applyReplacements` then `fuzzyCorrect`, using the corpus `vocabulary.txt`
as the dictionary). Post-processing is pure text, so this costs no extra transcription — a
second `WER.compare` on the same string.

Output gains a `corrected` column beside the existing raw ones. The headline claim in
`docs/wer-corpus/README.md` is then a measured number rather than an inference.

**A `replacements.txt` in the corpus** (`from → to` per line, optional) so the hand-authored
path is measurable too. Without it that path stays as unmeasured as fuzzy correction is today.

This sub-project changes no app behaviour. It exists so the next two can be judged, and so a
regression in them is visible.

### SP2 — join split terms

New pure function beside `applyReplacements`/`fuzzyCorrect`:

```swift
nonisolated func joinSplitTerms(_ text: String, dictionary: [String]) -> String
```

Slides a window of 2 and 3 adjacent whitespace-delimited tokens, joins them with the whitespace
removed, and replaces the run when the joined form matches a dictionary term **exactly**
(case-insensitively). Case is carried onto the replacement the way `fuzzyCorrect` already does
via `matchCase`, so `WhisperKit` comes back correctly cased rather than as `whisperkit`.

**Exact match only, no fuzziness.** "app cast" → `appcast` fires only because `appcast` is a
term the user typed. This is a strictly narrower rewrite than `fuzzyCorrect` already performs.

Width 3 is included because the terms that get split into three pieces are exactly the
CamelCase product names a vocabulary list is full of (`OmWhisper`, `SwiftUI`). Widths beyond 3
are not, and the risk grows with the window.

**The accepted cost, stated as a cost:** "the app cast a shadow" becomes "the appcast a shadow"
for a user who has `appcast` in their list. It requires both the term and the phrase, and the
user opted in by typing the term. SP1's corpus is what tells us whether this class of damage
shows up in practice, and a phrase like this belongs in the corpus as a deliberate trap.

### SP3 — decide the distance gate and the default by measurement

Two questions, both currently answered by taste, both answerable by SP1's harness:

**The gate.** `maxDistance(forTokenLength:)` is `0...3 → nil, 4...6 → 1, 7+ → 2`. A candidate
policy of `0...3 → nil, 4 → 1, 5...7 → 2, 8+ → 3` catches `Versal` → `Vercel`. The benchmark
reports corrected WER under both policies on the same hypotheses — again free, since it is pure
text — and the number decides. If the loose policy corrupts ordinary words, it scores worse and
we keep the tight one.

**The default.** `fuzzyVocabCorrection` defaults to `false`, which is why the feature is inert
out of the box. Flipping it is a product change and needs evidence, not preference: if corrected
WER beats raw on the corpus under the chosen gate, that is the argument for turning it on.
`joinSplitTerms` is a separate question — it is exact-match and strictly safer than fuzzy
correction, so it is a candidate for running unconditionally.

**No decision on either is made in this spec.** SP3 is where they get made, from SP1's table.
Recording a threshold here would be exactly the "measure thresholds, never taste them" mistake.

## What this does not attempt

- **Making engine biasing work.** It is measured inert on Apple and Parakeet and the mechanism
  is Apple's, not ours. Post-processing is the lever we actually control.
- **Homophones** (`pane`/`pain`). Needs sentence context, not a word list. A different feature.
- **Auto-learning vocabulary from corrections.** That is T3 in the Digital Twin phase.
- **Changing the Vocabulary UI.** If SP3 turns a default on, the copy describing it changes;
  nothing else does.

## Testing

Pure and directly testable:

- `joinSplitTerms` — joins a 2-token and a 3-token split; preserves casing; leaves a run alone
  when the joined form is **not** in the dictionary (the half that makes it a real check — a
  function that joins everything passes the first case); does not join across a sentence
  boundary or punctuation; leaves text unchanged with an empty dictionary.
- The deliberate false positive ("the app cast a shadow" with `appcast` in the dictionary) is
  asserted as the **documented current behaviour**, so the day someone narrows it the test says
  what changed rather than silently passing.
- SP1's corrected scoring — a hypothesis with a known correctable error must score strictly
  better corrected than raw, or the post-processing is not being applied at all. A test that
  only asserts "corrected ≤ raw" would pass if the pipeline were skipped entirely.

Not unit-testable, owed live: whether a real dictation of "I pushed the appcast to Vercel"
comes out right on the default engine. **The synthetic corpus is a floor, not a prediction** —
`say` produces clean, unaccented, close-mic'd speech. A recorded corpus of the same script in
R's own voice is worth more than any threshold tuning, and is owed before any claim about real
accuracy.

## Copy constraint, unchanged

Until SP3 produces a measured improvement, the website must still not say vocabulary "learns
your jargon". If SP2/SP3 land with numbers behind them, what becomes sayable is narrow and
specific: OmWhisper fixes the terms you list when the engine splits or misspells them. Not that
the engine learns anything.
