# Cross-engine WER

`OmWhisper --wer <corpus-dir>` (Debug build) runs every available engine over the same audio
and reports Word Error Rate. This closes the accuracy comparison M4 owed from the start:
how good is each engine, actually, rather than by reputation.

## Corpus format

A directory of pairs: `03-code.wav` beside `03-code.txt` holding exactly what was said. Any
audio `AVAudioFile` can open works — `.wav`, `.m4a`, `.caf`, `.mp3`, `.aiff`. QuickTime Player →
File → New Audio Recording produces a usable `.m4a`.

Add an optional `vocabulary.txt` (one term per line, `#` comments allowed) and every engine runs
**twice** — biasing off, then on. Without it, engines are measured with their biasing switched
off, which is not what a user with a vocabulary list experiences.

Add an optional `replacements.txt` (`from -> to` per line, `#` comments allowed) to measure the
hand-authored replacement rules too. With either file present every engine is scored **twice
from one transcription**: raw, and after the post-processing a real dictation receives
(`applyReplacements`, then `fuzzyCorrect`). The `+fix` columns are the only ones that describe
what a user actually sees — **every number published here before 2026-08-07 is a raw-engine
number**, because the harness did not apply post-processing at all until then.

There is no number/currency normalization, so a reference of "five" scores an engine that writes
"5" as wrong. Pessimistic in absolute terms, fair between engines.

## Two kinds of corpus, two different questions

**Synthetic** — `bash scripts/make-wer-corpus.sh /tmp/wer` builds one with macOS `say` in
seconds. Answers "do these engines differ?" and smoke-tests the harness. It does **not** predict
your dictation accuracy: synthetic speech is clean, unaccented, close-mic'd and free of
disfluency. Treat the numbers as a floor.

**Recorded** — read a prepared script into your own mic, in your room, and save what you read as
the `.txt`. The only version whose numbers predict your experience.

## Run — 2026-08-07, synthetic corpus + jargon samples, M2 Pro

9 samples, 50.7s, 168 reference words, 10-term `vocabulary.txt`. **The first run to measure
post-processing**, so the `+fix` columns are the first user-visible numbers this project has
ever had.

| Engine | off | off+fix | on | on+fix | on+wide |
|---|---|---|---|---|---|
| Whisper large-v3 turbo | 6.0% | 1.8% | 2.4% | **1.2%** | 1.2% |
| Parakeet v2 | 8.3% | 2.4% | 8.3% | **2.4%** | 2.4% |
| Whisper base | 7.1% | 3.0% | 3.6% | **2.4%** | 2.4% |
| Whisper small | 7.7% | 3.6% | 3.6% | **2.4%** | 2.4% |
| **Apple Speech** *(default)* | 8.3% | 5.4% | 8.3% | **5.4%** | 5.4% |
| Parakeet v3 | 7.7% | 3.6% | 31.0% | 26.8% | 26.2% |

### Post-processing helps every engine, substantially

This is what was never measured before. On the **default** engine, Apple Speech, correction
takes 8.3% → 5.4% — a 35% relative reduction — and it does so where biasing does nothing at
all. Parakeet v2 goes 8.3% → 2.4%, a 71% relative reduction.

The corrections are visible in the transcripts, not just the totals:

```
Apple      … I pushed the app cast of her cell …   → … I pushed the appcast of her cell …
Parakeet   … We swapped Whisper Kit for Parakeet   → … We swapped WhisperKit for Parakeet
Parakeet   … The Swift UI Settings pane …          → … The SwiftUI Settings pane …
Parakeet   … before Omwisper starts.               → … before OmWhisper starts.
Whisper    … app cast of Vercell …                 → … appcast of Vercel …
```

**So "the vocabulary list does nothing" was only ever true of engine biasing.** It is false of
the pipeline — but only for a user who has turned `fuzzyVocabCorrection` on, and it defaults
to **off**. That default is the single biggest reason the Vocabulary tab appears inert.

### Biasing is still inert on Apple and Parakeet v2

8.3% → 8.3% on both, confirming the 2026-08-01 finding on a larger corpus.

### Parakeet v3 + a vocabulary list returns an EMPTY transcript

The 31.0% is not a general accuracy regression, and reporting it as one would be wrong. It is
**one sample** — `04-longer`, the longest at 41 reference words — coming back `<empty>` with
biasing on, in both runs of this session. Every other sample is normal. The likely suspect is
the CTC vocabulary-boosting path FluidAudio needs for `configureVocabularyBoosting`.

Users on Parakeet v3 with a custom vocabulary can silently lose a whole long dictation. **Not
yet filed or fixed** — recorded here so it is not rediscovered from scratch.

**ROOT-CAUSED AND FIXED 2026-08-10.** Reproduced three times across two corpora: 11.8s and
13.1s clips came back empty, and a 22.4s clip lost 28 of 70 words, where the same audio
unbiased scored 4.9%, 2.2% and 1.4%. Not a length threshold — a **window-boundary condition**,
which is why it is intermittent.

The cause is in FluidAudio, not in our call. Enabling boosting switches
`SlidingWindowAsrManager.finish()` onto a different reconstruction path that rebuilds the text
from `confirmedTranscript`/`volatileTranscript` instead of decoding `accumulatedTokens` — and
`updateTranscriptionState` does `volatileTranscript = result.text`, an **overwrite, not an
append**. A window whose rescored result is empty, before anything has been confirmed, discards
the whole dictation.

**`configureVocabularyBoosting` is no longer called at all** (`ParakeetEngine`), because it
bought nothing: across both corpora every sample was byte-identical with and without boosting,
on v3 *and* v2. Zero measured benefit, occasional total loss. The `CtcModels` download went
with it. Custom vocabulary still reaches these users through `joinSplitTerms` + `fuzzyCorrect`.
Verified by re-running both reproductions — `04-longer` 100% → 4.9%, `len-70` 40.0% → 1.4%,
each matching its unbiased score exactly.

**Method note, and it nearly produced a false finding.** The first duration sweep built its
samples by repeating one sentence. Repetitive audio is pathological for ASR — every engine
looked dramatically worse with biasing, and v3 appeared to truncate long audio in general.
Rebuilt with non-repeating prose, that disappeared: `len-110` (38s) scores 0.0% unbiased.
**A fixture that makes every engine fail is measuring the fixture.**

### The wide distance gate earns nothing

`on+fix` and `on+wide` are identical on five of six engines, and differ by 0.6% only on the one
engine that is already broken. **No evidence to loosen the gate; `.standard` stays.** Written
down so this is not re-litigated by taste.

### Method note — the corpus decided the answer, twice

The first run of this benchmark scored `+fix` identical to raw on every engine, which read as
"the corrections do nothing". They were fine; the corpus `make-wer-corpus.sh` generates contains
none of the terms in `vocabulary.txt`, so nothing could fire. Three jargon samples (`07`–`09`)
were added, and `async` — which appears in `02-technical` and had been left out of the
vocabulary file — was added too.

This is the identical mistake recorded against the 2026-08-01 run, where the A/B used a term
the engines already got right. **A vocabulary benchmark measures nothing unless the corpus
contains words the engine actually gets wrong.**

## Run — 2026-08-01, synthetic corpus, M2 Pro

8 samples, ~55s, 168 reference words, with a 10-term `vocabulary.txt`.

| Engine | WER (biasing off) | WER (on) | Δ |
|---|---|---|---|
| Whisper large-v3 turbo | 2.4% | **0.6%** | −1.8 better |
| Cloud · ElevenLabs Scribe | 3.0% | 3.0% | no change |
| Whisper small | 4.2% | 3.6% | −0.6 better |
| Whisper base | 8.3% | 4.2% | −4.2 better |
| Parakeet v3 | 4.2% | 4.8% | +0.6 |
| Parakeet v2 | 4.8% | 4.8% | no change |
| Apple Speech *(default)* | 6.0% | 6.0% | no change |

RTF: Apple 0.04x, Parakeet 0.05x, Whisper base 0.06x, small 0.12x, turbo 0.45x, ElevenLabs 0.18x.

AssemblyAI, Deepgram, OpenAI and Groq skipped — no key in the Keychain.

### The finding: custom vocabulary does nothing on two of the three on-device engines

**Apple Speech and both Parakeet variants produce byte-identical transcripts with and without a
vocabulary list.** Not "a small effect" — character-for-character the same text, with the listed
terms still wrong:

```
reference   … I pushed the appcast to Vercel … notarize … SwiftUI settings pane shipped.
Apple, off  … I pushed the app cast to Versal … notarise … SwiftUI settings pain ship.
Apple, on   … I pushed the app cast to Versal … notarise … SwiftUI settings pain ship.
```

`appcast`, `notarize`, `SwiftUI`, `WhisperKit`, `Parakeet`, `Keychain` and `GRDB` were all in
`vocabulary.txt`. Apple heard "app cast" and "whisper kit" both times.

**This is not a plumbing bug, and that was checked rather than assumed.** A `log.debug` inside
`AppleEngine`'s biasing branch (kept, deliberately) fires `contextualStrings applied: 10 term(s)`
on every biased run — so the branch executes and `AnalysisContext.contextualStrings` is set
before `start()`, exactly as the API documents. The transcript simply does not change.

The control that makes it conclusive: **the same vocabulary array, on the same audio, through
the same call site, measurably changes Whisper** — base improves 8.3% → 4.2%. So the value
reaches the engines; two of them ignore it.

**What this calls into question:**

- **Sign-off criterion #4** ("technical vocabulary respected via context hints") is recorded in
  `CLAUDE.md` as shipped 2026-07-07. It was recorded on the strength of the code being written
  and the mechanism being confirmed against the SDK — never on an observed change in a
  transcript. This is the same shape as the items in `CLAUDE.md` § Verification.
- **S2 context-aware dictation** routes auto-extracted screen terms through this same
  `contextualStrings` path. If biasing has no effect, neither does S2.
- The **Vocabulary settings tab**'s custom-words list is inert on the default engine. Word
  replacements and fuzzy correction are unaffected — those are post-processing in `AppState`,
  not engine biasing.

**Before treating it as settled**, note the corpus is synthetic and small. Biasing may only move
a decision the model is already uncertain about, and TTS audio is unusually unambiguous. The
cheap next test is a recorded corpus of the same jargon in a real voice. But byte-identical
output across 8 samples is a strong prior, and Whisper responding on identical input rules out
the easy explanations.

Parakeet's boosting needs a second CTC model that downloads lazily on first use with a
non-empty vocabulary; whether that download completed here was not separately confirmed, so
Parakeet's "no change" is weaker evidence than Apple's.

## What this does not measure

Accented speech · background noise · far-field mics · disfluency and self-correction ·
overlapping speakers · streaming partial quality (only final text is scored) · punctuation and
casing (normalized away before scoring).

## Recording one in your own voice — 2026-09-09

`bash scripts/record-wer-corpus.sh <out-dir> [device]` prints a sentence, you read it, it saves
the audio beside exactly what you read. Re-running skips takes you already have, so a session
can be stopped and resumed. List your inputs by running it with no arguments.

Every take is classified before it is accepted. A corpus of silence scores catastrophically on
every engine at once and reads as an engine bug, which is the expensive way to discover the mic
was muted or the device flag was wrong. `--self-check` proves that guard both directions with no
microphone:

```
ok   silent.wav → silent (-91.0 dB)
ok   speech.wav → speech (-4.6 dB)
ok   missing file → unreadable
```

Three properties of the sentence set, each one a lesson already paid for here:

- **They contain the words engines get wrong** — `appcast`, `Vercel`, `notarize`, `SwiftUI`,
  `WhisperKit`, `Parakeet`, `OmWhisper`, `async`, plus `GATT` and `Auracast`. A vocabulary
  benchmark whose corpus lacks the failing words measures nothing; that mistake was made on
  2026-08-01 and again on 2026-08-07.
- **Non-repeating prose.** The duration sweep that built samples by repeating one sentence
  measured the fixture, not the engine.
- **One deliberately disfluent sample**, with a filled pause and a mid-sentence restart. `say`
  cannot produce either, and real dictation is full of both.

### Synthetic floor for these exact sentences

Run the same ten sentences through `say` and you get the floor to compare a voice recording
against — same references, same vocabulary, only the speech is different. 10 samples, 234
reference words, M2 Pro:

| Engine | off | off+fix | on | on+fix | RTF |
|---|---|---|---|---|---|
| Whisper large-v3 turbo | 2.6% | 0.9% | 1.7% | **0.4%** | 0.46x |
| Whisper small | 5.1% | 2.6% | 1.7% | **1.3%** | 0.10x |
| Parakeet v2 | 5.1% | 1.7% | 5.1% | **1.7%** | 0.04x |
| Whisper base | 6.8% | 4.3% | 1.7% | **1.7%** | 0.05x |
| Parakeet v3 | 5.6% | 2.6% | 5.6% | **2.6%** | 0.04x |
| **Apple Speech** *(default)* | 6.4% | 4.3% | 6.4% | **4.3%** | 0.04x |

Two prior findings reproduce on this new corpus, which is worth more than either did alone:
post-processing helps every engine (Apple 6.4% → 4.3%), and **engine biasing remains exactly
inert on Apple Speech and both Parakeet variants** — identical to the third decimal, off and on.

**A number in this table is not a claim about your dictation.** Synthetic speech is clean,
unaccented, close-mic'd and disfluency-free. Recording the same sentences in a real voice is the
only way to learn what your own accuracy is, and it should score worse.

### A sample that measured the fixture

The first version of sample 08 read "…runs six hundred and thirty eight tests in ninety five
suites". Every engine scored **33–37%** on it, all with the same five deletions, because they
all correctly wrote "638" and "95" and there is no number normalization here. It penalised
correct output uniformly and inflated every engine's pooled WER by roughly three points — Apple
Speech read 9.8% with it and 6.4% without. Replaced with an editing-request sentence, which
scores 0.0–4.2%. **A fixture that makes every engine fail is measuring the fixture.**

### Cloud streaming cannot be benchmarked this way — AssemblyAI returns empty

AssemblyAI scored **87.6%** with biasing off and **100%** with it on, because most samples came
back `<empty>` while three were transcribed perfectly. Not a dead key, which would fail all ten,
and not a length threshold — the pattern is a race.

The suspect is `CloudEngine.swift`'s fixed one-second drain after `Terminate`, which carries a
`ponytail` note reading "revisit if endings clip". The harness pushes a whole file in
milliseconds, so the server still has seconds of audio queued when the socket closes. Live
dictation never hits this because audio arrives in real time and the server is nearly caught up
when you stop speaking.

So the cloud columns here measure the harness's feed rate, not the provider. **Not fixed** —
fixing it means waiting for the `Termination` message rather than sleeping, and whether the same
race can clip a real dictation's final sentence is untested either way.
