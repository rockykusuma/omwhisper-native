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
