# Cross-engine WER

`OmWhisper --wer <corpus-dir>` (Debug build) runs every available engine over the same audio
and reports Word Error Rate. This closes the accuracy comparison M4 has owed since the start —
`NATIVE_MIGRATION_PLAN.md` lists "SpeechTranscriber accuracy is the big unknown" as risk #1.

## Corpus format

A directory of pairs. `03-code.wav` beside `03-code.txt` holding exactly what was said.

Any audio `AVAudioFile` can open works — `.wav`, `.m4a`, `.caf`, `.mp3`, `.aiff`. QuickTime
Player → File → New Audio Recording produces a usable `.m4a`.

Write references the way you would want the text pasted, and keep that consistent across
samples. There is no number/currency normalization, so a reference of "five" scores an engine
that writes "5" as wrong. That is pessimistic in absolute terms but fair between engines, which
is what the comparison turns on.

## Two kinds of corpus, two different questions

**Synthetic** — `bash scripts/make-wer-corpus.sh /tmp/wer` builds one with macOS `say` in
seconds. Answers "do these engines differ from each other?" and smoke-tests the harness.

It does **not** answer "how accurate will dictation be for me". Synthetic speech is clean,
unaccented, close-mic'd and free of disfluency; every engine scores far better on it than on
real dictation. Treat the numbers as a floor.

**Recorded** — read a prepared script aloud into your own mic, in the room you actually work
in, and save what you read as the `.txt`. Ground truth by construction, real voice, real
hardware. This is the only version whose numbers predict anything about your experience.
Include the technical vocabulary you actually dictate; that is where engines diverge most.

## Baseline run — 2026-08-01, synthetic corpus

6 samples, 38.9s, 132 reference words, on an M2 Pro.

| Engine | WER | S | D | I | RTF |
|---|---|---|---|---|---|
| Cloud · ElevenLabs Scribe | 0.0% | 0 | 0 | 0 | 0.17x |
| Whisper large-v3 turbo | 0.8% | 1 | 0 | 0 | 0.44x |
| Apple Speech *(default)* | 1.5% | 2 | 0 | 0 | 0.04x |
| Parakeet v2 | 1.5% | 2 | 0 | 0 | 0.05x |
| Parakeet v3 | 2.3% | 2 | 0 | 1 | 0.04x |
| Whisper small | 3.0% | 3 | 0 | 1 | 0.11x |
| Whisper base | 3.8% | 4 | 1 | 0 | 0.06x |

AssemblyAI, Deepgram, OpenAI and Groq were skipped — no key in the Keychain.

**Read this as a floor and a smoke test, not a ranking.** At 132 reference words one wrong word
is 0.76% WER, so the entire spread between first and third place is two words. Nothing here
separates Apple, Parakeet v2 and Whisper turbo.

**The one real signal is where the errors landed.** Almost every error in the whole run came
from a single sample, and a single word in it — "async", variously heard as "a sync", "Usync"
and "and our sync". Ordinary prose was transcribed perfectly by every engine. So on clean
speech the engines are indistinguishable, and they separate on *technical vocabulary* — exactly
the case sign-off criterion #4 exists for.

That has a direct consequence: the harness currently passes **no vocabulary** to the engines,
so it measures them with their biasing turned off. Re-running with "async" in custom vocabulary
would measure whether `contextualStrings`/keyterm biasing actually earns its place. That is
the more interesting experiment and it is not done yet.

Also worth noting: RTF says the on-device engines are not the slow option. Apple and Parakeet
run at ~0.04x — roughly 25× faster than real time — while Whisper turbo is 0.44x and the cloud
round-trip is 0.17x.

## What this does not measure

Accented speech · background noise · far-field mics · disfluency and self-correction ·
overlapping speakers · streaming partial quality (only the final text is scored) · vocabulary
biasing · punctuation and casing (normalized away before scoring).
