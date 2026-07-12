# Cross-Lingual Dictation (F4) — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorming), pending implementation plan
**Roadmap:** Phase F, wave 2.2, feature F4 — "Speak your language, write in English."

## Overview

Let the user speak in their mother tongue — Telugu, Hindi, Tenglish/Hinglish
(mid-sentence code-switching), etc. — and get polished **English** out, through
their normal dictation hotkey. The hero case is any-source → English. This is a
persistent, opt-in profile, not a per-utterance mode.

Most of the machinery already exists (the multilingual Whisper engine, a per-
language decode setting, polish backends, the paste pipeline). F4 is about
turning the buried manual combination into one clean, well-tuned decision that
survives code-switching.

## Decisions (from brainstorming, 2026-07-13)

1. **Trigger: persistent "I speak…" profile.** Set the spoken language once;
   from then on the normal dictation hotkey (⌘⇧V / Fn) outputs polished English.
   No separate gesture.
2. **Backend: follow the user's active polish backend** (`activePolishBackend()`
   — System / Ollama / Cloud). No special routing; if on-device Hinglish is
   rough, the user switches to Cloud themselves (Cloud already redacts PII).
3. **Pipeline: lane (a) — transcribe-then-LLM.** Multilingual Whisper ASR in the
   spoken language → a **single combined LLM pass** that translates, normalizes
   the code-switching, and applies the active polish style's tone. One backend
   call, so latency stays at "dictation + one polish pass."
4. **Composition, not replacement.** Cross-lingual composes *with* the user's
   active polish style (Professional/Concise/…), unlike the manual "Translate"
   style today which replaces it.
5. **Graceful degradation to lane (b).** When no polish backend is available,
   fall back to Whisper's built-in `.translate` task (raw English, no LLM) —
   never drop the user's dictated text.

## Architecture / data flow

```
dictation stop (normal / smart / brain-dump)
        │  crossLingualEnabled == true?
        ▼
 Whisper engine (forced), decode language = spokenLanguage
        │  → raw transcript (may be mixed source+English)
        ▼
 activePolishBackend()?
   ├─ yes → backend.polish(transcript, style: crossLingualStyle(spoken, activeStyle))   ← lane (a), primary
   └─ no  → Whisper `.translate` task result (English)                                    ← lane (b), fallback
        ▼
 paste (existing path)
```

Only the transcription engine and the polish prompt change; capture, overlay,
and paste are unchanged.

## New / changed state

- `AppState.crossLingualEnabled: Bool` (default **false**), UserDefaults-backed
  with `access`/`withMutation` (per the M3 Observation-instrumentation rule).
- **Spoken language reuses `whisperLanguage`** — the "I speak…" picker is the
  existing Whisper language setting surfaced in the cross-lingual section. No new
  language state.
- No new engine state: when `crossLingualEnabled`, `activeEngine` resolves to the
  Whisper engine regardless of `engineKind` (see Engine override).

## The combined prompt

A builder (pure, testable) produces a `PolishStyle` whose prompt combines
translation + code-switch normalization + the active style's tone:

> The following was dictated in {spokenLanguage} mixed with English. Translate and
> normalize it into fluent, natural English — fix the code-switching, do not
> translate word-for-word. Then write it in {activeStyleToneClause}. Output only
> the English text, nothing else.

- `{spokenLanguage}` = the human-readable name of `whisperLanguage` (e.g.
  "Telugu"); if `whisperLanguage == auto`, phrase as "another language mixed with
  English."
- `{activeStyleToneClause}` = the active `PolishStyle`'s own `prompt` text,
  appended verbatim as trailing guidance ("Additionally, follow this style
  instruction: <activeStyle.prompt>"). This works uniformly for built-in styles
  (their prompts read naturally after a translate instruction) and custom styles
  (whatever the user wrote), so there's no per-style tone-phrase mapping to
  maintain. **Exceptions:** if the active style is the built-in **Translate**
  style, cross-lingual supersedes it entirely (no double translation, no appended
  clause) and uses a neutral "clear, natural English" tone; if polish is off /
  no style is active, same neutral tone.
- `targetLanguage` is fixed to **English** (baked into the prompt; the
  `crossLingualStyle` does not set `requiresTargetLanguage`). Arbitrary target is
  out of scope — see Out of scope.

## Engine override & degradation

- **Force Whisper when on.** `activeEngine` returns the Whisper engine whenever
  `crossLingualEnabled`, even if the user's `engineKind` is Apple/Parakeet/Cloud
  (they cannot do Indic). A one-time-per-launch nudge (`errorMessage`) explains:
  "Cross-lingual dictation uses the Whisper engine." Same nudge pattern as the
  Foundation-Models-unavailable notice.
- **Whisper model not downloaded.** If no Whisper model is present, nudge the
  user to download it (existing Transcription-tab flow) and fall back to normal
  (non-cross-lingual) dictation for that session rather than failing silently.
- **No polish backend.** Fall back to Whisper's `.translate` task → raw English.
  This is a decode-option change on the same model (no second model), so it's
  cheap. Honors "never drop dictated text."

## Scope

- **Applies to:** normal dictation and Smart Dictation (⌘⇧B). Both transcribe
  the user's voice and end in the shared `polishedText(for:)` pass, where the
  cross-lingual style cleanly substitutes.
- **Deferred:** Brain-dump (⌘⇧D). It transcribes voice too, but runs its own
  `BrainDumpStructurer` prompt instead of `polishedText`, so cross-lingual would
  need the transcript translated *before* structuring (or the structurer taught
  to handle mixed input) — a separate, larger change. The Whisper engine
  override still gives brain-dump source-language transcription, but the
  translate step is not wired there in v1. Noted as a follow-up.
- **Does NOT apply to:** Polish Selected Text and Reply Assist — they operate on
  already-typed text, not the user's voice, so there's no source language to
  translate.

## UI (per `omwhisper-design`)

- **Overlay:** no new styles or colors. Whisper doesn't stream, so recording
  shows the usual listening orb (no live words — already Whisper's behavior).
  After stop, the translate pass reuses the **existing `POLISHING` sub-phase**;
  then the final English pill lands. Reassurance that "it heard you" is the clean
  English appearing (source partials aren't available with Whisper).
- **Settings:** a `PorcelainSection` in the **Transcription** tab — a
  "Cross-lingual dictation" toggle (off by default), an "I speak…" picker
  (reusing the Whisper language list), and one calm explainer line: "Speak
  another language; polished English comes out. Uses the Whisper engine."
  Porcelain tokens, native controls, emerald tint.

## Testing

Pure unit tests (logic tested, UI/Canvas verified live — project convention):

- Combined-prompt builder: (spokenLanguage, activeStyle) → prompt string;
  covers the Translate-supersede case and the `auto` phrasing.
- Engine-override decision: `crossLingualEnabled → Whisper` regardless of
  `engineKind`.
- No-backend fallback decision: backend nil → `.translate` lane.

Live verification (user, native Tenglish/Hinglish speaker): F4 exit criteria —
Tenglish/Hinglish → clean English, usable-without-edits on ~20 real utterances
≥ 80%; latency ≤ dictation + one polish pass.

## Exit criteria (F4)

- Hinglish/Tenglish → clean English, ≥ 80% usable without edits on 20 real-world
  samples.
- Latency ≤ dictation + one polish pass.
- Off by default; no regression to English-only dictation when the toggle is off.

## Out of scope (YAGNI)

- Arbitrary source→target pairs (only → English for now).
- Live source-language partials in the overlay (Whisper can't stream; not worth a
  streaming multilingual engine yet).
- Per-app / per-document output-language selection.
- Cross-lingual for Polish-Selected-Text / Reply Assist.
- A curated benchmark harness (live human judging against the exit bar instead).
