# Sarvam Saaras Cross-Lingual Engine — Design

**Date:** 2026-07-14
**Status:** Approved (brainstorming), pending implementation plan
**Context:** Cross-lingual dictation (F4) with on-device Whisper + a local/cloud LLM translate produced poor Telugu results — Whisper Small transcribed Telugu as garbage, and the LLM translate step was slow/flaky (Ollama cold-load timeouts). Sarvam's **Saaras** model is purpose-built for Indic speech and does **speech → English in one call**, code-switch-aware (Tenglish). This wires it in as the cross-lingual engine when the user provides a Sarvam key.

## Overview

Add `SarvamEngine`, a `TranscriptionEngine` that sends dictation audio to Sarvam's Saaras `speech-to-text` API in **`mode=translate`** and gets **English text** back directly. It is **auto-selected by the existing cross-lingual toggle**: when `crossLingualEnabled` and a Sarvam key is saved, dictation routes to Sarvam (speech→English, one call, no LLM); otherwise the current `crossLingual → Whisper + LLM-translate` path is unchanged.

Net effect for the user: turn on "Cross-lingual dictation", paste a Sarvam key, speak Telugu → clean English. No polish backend required, and none of the Whisper-transcription-quality or LLM-timeout problems.

## Decisions (brainstorming, 2026-07-14)

1. **Invocation = wired into the cross-lingual toggle** (not a standalone Cloud provider). One concept; auto-picks the best engine.
2. **`SarvamEngine` is a dedicated `TranscriptionEngine`**, NOT a `CloudProviderKind`. It isn't in the AssemblyAI/Deepgram/… picker; it's selected only for cross-lingual.
3. **Sarvam does the whole job** — `mode=translate` returns English; the cross-lingual **LLM translate/polish step is skipped** for this path. **No polish backend needed.**
4. **Language: auto-detect** (Saaras handles mixed Indic+English). The "I speak" picker keeps driving the Whisper fallback only.
5. **Tone:** v1 pastes Sarvam's English verbatim (no applying the active polish style on top). Optional tone-polish is a future add.
6. **Privacy:** honest audio-egress note. Dictation only; recorded meetings stay on-device (S3 rule untouched).

## Architecture / data flow

```
dictation stop, crossLingualEnabled == true
        │  Sarvam key saved?
        ├─ yes → SarvamEngine: mic → 16kHz mono WAV → POST Saaras (mode=translate) → English text → paste
        │        (polishedText skips the cross-lingual LLM step; no backend needed)
        └─ no  → Whisper (forced) → LLM translate via active polish backend → paste   (unchanged)
```

Only the engine-selection and the cross-lingual polish branch change; capture, overlay, and paste are unchanged.

## Components

### `SarvamEngine` (new — `Transcription/SarvamEngine.swift`)

`nonisolated struct SarvamEngine: TranscriptionEngine` (stateless, like `AppleEngine`/`CloudEngine`). `kind` reuses `.cloud` (it is a cloud engine; no new `EngineKind` case — Sarvam is never user-picked, only auto-selected).

- `transcribe(_ audio:vocabulary:)`: reads the Sarvam key from Keychain (throws a clear "add your Sarvam key" error if missing), accumulates the mic `AsyncStream` inline (same pattern as `CloudEngine` — a `sending` stream is consumed here, never forwarded), converts to 16 kHz mono Int16 PCM via `BufferConverter`, wraps it in a WAV container via the existing `pcmToWav` helper, and POSTs it.
- Pure, directly-tested helpers (mirroring `CloudEngine`/`BatchCloudTranscriber` helper style):
  - `endpoint` → the Saaras STT URL.
  - `buildRequest(wav:apiKey:) -> URLRequest` → multipart body with header `api-subscription-key: <key>`, fields `model=saaras:v3`, `mode=translate`, `file=<wav>` (and `language_code` only if we decide to send one — default omit for auto-detect).
  - `parseTranscript(_ data: Data) -> String?` → extracts the English text field from the JSON response.
- Emits one `.final(english)`; empty/failed → finishes with an error surfaced in the overlay (same as other engines).

### `Keychain` (extend — `Transcription/Keychain.swift`)

Add `sarvamAccount = "sarvam-api-key"` + `loadSarvamKey`/`saveSarvamKey`/`deleteSarvamKey`, delegating to the existing account-parameterized `load/save/delete(account:)` core (unchanged behavior for the M4.2 STT keys).

### `AppState` (modify)

- `activeEngine`: before the `CrossLingual.engineKind` switch, add: `if crossLingualEnabled, Keychain.loadSarvamKey() != nil { return SarvamEngine() }`. Also account for it in `startDictation`'s `effectiveEngineKind` (vocab merge) — Sarvam takes no vocabulary; it can be treated like the cloud case (screen terms excluded) or simply passed empty vocab (Sarvam ignores it).
- `polishedText(for:)`: in the `crossLingualEnabled` branch, if `Keychain.loadSarvamKey() != nil` (the Sarvam path already produced English), **return `original` as-is** (no LLM translate). Else keep the current `CrossLingual.style` path.
- No new setting flag — presence of a Sarvam key is the switch.

### `TranscriptionSettingsView` (modify)

In the existing **Cross-Lingual** `PorcelainSection`: add a Sarvam API-key `SecureField` + Save/Clear (Keychain-backed, mirroring the Cloud provider key field), a live status line ("Using Sarvam for translation" when a key is saved, else "Using on-device Whisper + your polish backend"), and the privacy note.

## API (verify-first at build time)

From Sarvam docs/search (JS SPA, not fully scrapable — treat as unconfirmed until a live call):
- Endpoint: `POST https://api.sarvam.ai/speech-to-text` (with `mode=translate`); legacy alias `/speech-to-text-translate`.
- Auth header: `api-subscription-key: <key>` (NOT Bearer).
- Content-type: `multipart/form-data`; fields `model` (`saaras:v3`), `mode` (`translate`), `file` (audio; WAV supported), optional `language_code` (BCP-47; omit for auto-detect).
- Response: JSON containing the output text (field name to confirm — likely `transcript`) and a detected `language_code`.

**The plan's first task is to confirm the exact endpoint, request field names, response field name, and language handling against a real key** (curl), then encode them — the "unverified API shape = live-only failure" rule (AssemblyAI auth, WhisperKit checkpoint, FluidAudio tag all bit us).

## Privacy

- `SarvamEngine` sends the user's **dictation audio** to Sarvam (sarvam.ai), a third-party service. This is a larger egress than the Cloud polish backend's text, and the text redactor cannot scrub audio. The settings note states this plainly.
- Scope: dictation only. `MeetingRecorder`/`MeetingTranscriber` are untouched — recorded meetings remain fully on-device.

## Testing

Pure unit tests (no network, like `CloudEngineTests`):
- `buildRequest` — URL, `api-subscription-key` header present, multipart contains `model=saaras:v3` + `mode=translate` + the file part.
- `parseTranscript` — extracts English text from a sample response JSON; returns nil for malformed/empty.

Live verification (user, needs a Sarvam key):
- API shape confirmed by a real curl (endpoint/fields/response) before/while implementing.
- End to end: cross-lingual ON + Sarvam key → speak Telugu/Tenglish → clean English pasted, no polish backend set; clearing the key falls back to Whisper+LLM.

## Exit criteria

- With a Sarvam key + cross-lingual ON, Telugu/Tenglish speech pastes usable English (F4 bar: ≥80% usable without edits), in one network call, with **no** polish backend configured.
- No Sarvam key → behavior identical to today (Whisper + LLM translate).
- Dictation audio egress is disclosed; meetings remain on-device.

## Out of scope (YAGNI)

- Sarvam as a general Cloud STT provider (transcribe mode / Indic→Indic) in the provider picker.
- Applying the user's polish style/tone on top of Sarvam output.
- Streaming/partials (Saaras STT here is batch, one `.final`).
- Sarvam TTS / translate-text / other Sarvam models.
- Mapping the "I speak" picker to Sarvam `language_code` (auto-detect is used).
