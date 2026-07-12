# Cloud Multi-Provider Transcription — Design

**Date:** 2026-07-12
**Status:** Approved (design), pending implementation plan
**Context:** Extends M4.2's single-provider CloudEngine (AssemblyAI) into a multi-provider
cloud transcription layer — directly serves the app's USP ("user choice of transcription
backends"). Local engines (Apple/Parakeet/Whisper) and the 100%-offline default are unchanged.

## Goal

Let the user choose among several cloud transcription providers, each with its own API key,
selected in Settings. AssemblyAI becomes one option among five.

## Providers (verified against live docs 2026-07-12)

Two integration shapes, both already proven in this codebase (streaming = AssemblyAI path;
batch = Whisper's transcribe-on-release path):

| Provider | Shape | Verified API |
|----------|-------|--------------|
| **AssemblyAI** (existing) | streaming | `wss://streaming.assemblyai.com/v3/ws` — raw key in `Authorization` header, `speech_model=universal-3-5-pro`, Turn `end_of_turn` events. (Unchanged from M4.2.) |
| **Deepgram** | streaming | `wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&channels=1&interim_results=true&smart_format=true[&language=<code>]` · header `Authorization: Token <key>` · send raw linear16 PCM frames · result JSON `channel.alternatives[0].transcript` + `is_final` (bool) · close by sending `{"type":"CloseStream"}` |
| **ElevenLabs Scribe** | batch | `POST https://api.elevenlabs.io/v1/speech-to-text` · header `xi-api-key: <key>` · multipart/form-data: `file` (WAV) + `model_id=scribe_v1` [+ `language_code=<iso>`] · response JSON `.text` |
| **OpenAI** | batch | `POST https://api.openai.com/v1/audio/transcriptions` · header `Authorization: Bearer <key>` · multipart: `file` (WAV) + `model=gpt-4o-transcribe` [+ `language=<iso>`] · response JSON `.text` |
| **Groq** | batch | `POST https://api.groq.com/openai/v1/audio/transcriptions` (OpenAI-compatible) · header `Authorization: Bearer <key>` · multipart: `file` (WAV) + `model=whisper-large-v3-turbo` [+ `language=<iso>`] · response JSON `.text` |

**Default model per provider (no per-provider model picker in v1 — YAGNI):** as in the table.
Exact model strings re-verified at plan-writing time.

## Non-Goals (v1)

- **Per-provider model picker** (default model each; add later if wanted).
- **Redaction of transcription audio** — cloud transcription sends *audio*, which can't be
  redacted (unlike the Cloud *polish* backend, which redacts text). Each provider shows the
  same honest "your voice goes to `<provider>`" warning; redaction stays polish-only.
- **Streaming for the batch providers** — ElevenLabs/OpenAI/Groq transcribe on key-release
  (one `.final`), exactly like the Whisper engine. Only AssemblyAI/Deepgram show live partials.
- **A language picker for cloud** — cloud providers auto-detect (batch) or take the app's
  configured language where trivial; a per-provider language UI is deferred.

## Architecture

Refactor the AssemblyAI-specific `CloudEngine` into a **dispatcher** over a `CloudProviderKind`
setting. The `TranscriptionEngine` contract is unchanged, so `AppState`/overlay/paste need no
changes — every provider produces `AsyncThrowingStream<TranscriptEvent, Error>`.

- **`CloudProviderKind`** (pure enum, `String`-raw, `CaseIterable`, app-side): `.assemblyAI`,
  `.deepgram`, `.elevenLabs`, `.openAI`, `.groq`. Carries `displayName`, `keychainAccount`,
  `isStreaming` (for the privacy/behavior copy), and a `privacyNote`. Pure (no networking) →
  unit-testable.
- **`CloudEngine`** (existing `struct`, stays `nonisolated`): `transcribe()` reads the selected
  `CloudProviderKind` + its Keychain key, and dispatches:
  - **Streaming** → `AssemblyAIProvider` (today's logic, extracted verbatim) or
    `DeepgramProvider` (new). Each runs a `URLSessionWebSocketTask`, converts mic buffers to
    16 kHz mono Int16 via the existing `BufferConverter`, sends binary frames, drains result
    messages into `.partial`/`.final`.
  - **Batch** → a shared `BatchCloudTranscriber` parameterized by a small `BatchConfig`
    (endpoint URL, auth header name+value, model form-field name+value, optional language
    field name, response text key). Accumulates the mic stream → 16 kHz mono Int16 →
    **WAV `Data`** (new `pcmToWav` helper) → multipart POST → parse `.text` → one `.final`.
    OpenAI and Groq share the exact same config shape (Bearer + `model` + `.text`), differing
    only in URL + default model; ElevenLabs differs (`xi-api-key` + `model_id` + `language_code`).

**Pure, directly-tested helpers** (no network, matching `CloudEngineTests`):
- `pcmToWav(int16:sampleRate:) -> Data` — a minimal 44-byte WAV header + PCM payload.
- `DeepgramProvider.connectionURL(apiKey-independent params)` and `parseResult(json)` (transcript + is_final).
- `BatchCloudTranscriber.multipartBody(...)` (boundary, file part, model/language fields) and
  `parseText(json, key:)`.
- `CloudProviderKind` rawValue round-trip + per-provider `keychainAccount` uniqueness.

## Keys (Keychain)

Per-provider keys, one Keychain generic-password item each, via the account-parameterized
`Keychain.load/save/delete(account:)` core already added in M3-2b. `CloudProviderKind.keychainAccount`
gives each provider its account string (e.g. `"assemblyai-api-key"` (existing, unchanged),
`"deepgram-api-key"`, `"elevenlabs-api-key"`, `"cloud-stt-openai-api-key"`, `"groq-api-key"`).
Keys never touch `UserDefaults`. The existing `loadAssemblyAIKey`/`saveAssemblyAIKey` stay
(back-compat) and are joined by generic `load/save/delete(sttProvider:)` helpers.

## AppState

- `cloudProvider: CloudProviderKind` setting — UserDefaults-backed, `access/withMutation`
  (default `.assemblyAI` — no behavior change for existing Cloud users), read by `CloudEngine`.
- `CloudEngine` gains no stored state (still a stateless `struct`); it reads `cloudProvider`
  via a value passed at construction or read from `AppState` at the call site — **decided:**
  `AppState.activeEngine` constructs `CloudEngine(provider: cloudProvider)` (mirrors how
  `whisperModel`/`parakeetModel` are read), so `CloudEngine` stays free of `AppState`.
- `SettingsKeys.cloudProvider`.

## Settings UI (`TranscriptionSettingsView`)

The current AssemblyAI-only Cloud section generalizes:
- When `engineKind == .cloud`: a **provider `Picker`** (`CloudProviderKind.allCases`), then the
  selected provider's **API-key `SecureField` + Save/Clear + Test Connection + saved status**,
  reading/writing that provider's Keychain account. One upfront privacy line per provider
  (`provider.privacyNote`), plus a streaming-vs-on-release note.
- **Test Connection** per provider: streaming providers validate the key by opening + closing
  the socket (or a token/health endpoint where one exists); batch providers POST a ~0.1 s
  silence WAV and check for HTTP 200 / an auth error. A `CloudProviderKind.testConnection`-style
  effectful static per provider, returning `nil` on success or an error string.

## Data Flow (unchanged contract)

```
mic buffers ─AsyncStream→ CloudEngine.transcribe(audio, vocabulary)
   dispatch on cloudProvider:
     streaming (AssemblyAI/Deepgram): WS send PCM ⇄ receive → .partial/.final
     batch (ElevenLabs/OpenAI/Groq): accumulate → WAV → POST → one .final
                                            → AppState → overlay → paste
```

## Error Handling

Same as the existing CloudEngine/Whisper: a transcribe failure finishes the stream throwing;
AppState surfaces the overlay error. No key saved → `CloudEngine` throws a clear "add a
`<provider>` API key in Settings" error. HTTP/auth errors from batch providers surface their
status/message.

## Testing

Extend `CloudEngineTests` (pure only, no network — matching the existing suite): `pcmToWav`
header correctness, `DeepgramProvider.parseResult`/`connectionURL`, `BatchCloudTranscriber`
multipart + `parseText` for each config (OpenAI/Groq/ElevenLabs), `CloudProviderKind` rawValue
+ account uniqueness. **Live round-trips are owed per provider** (needs real keys), exactly as
M4.2/M3-2b logged — every pure piece tested, the real network call verified separately.

## File Summary

| File | Change |
|------|--------|
| `Transcription/CloudProviderKind.swift` | **new** — pure enum + per-provider metadata |
| `Transcription/CloudEngine.swift` | refactor into a dispatcher; AssemblyAI logic extracted to `AssemblyAIProvider` |
| `Transcription/DeepgramProvider.swift` | **new** — streaming WS provider |
| `Transcription/BatchCloudTranscriber.swift` | **new** — shared batch (WAV → multipart POST) for ElevenLabs/OpenAI/Groq + `pcmToWav` |
| `Transcription/Keychain.swift` | add `load/save/delete(sttProvider:)` over the existing account-parameterized core |
| `AppState.swift` | `cloudProvider` setting, `activeEngine` builds `CloudEngine(provider:)`, SettingsKey |
| `UI/TranscriptionSettingsView.swift` | provider picker + per-provider key field / Test / privacy note |
| `omwhisper-nativeTests/CloudEngineTests.swift` | pure-helper tests for all of the above |

## Risks / Notes

- **Deepgram's doc site 404'd WebFetch** repeatedly; the WS shape here is from Deepgram's
  search-surfaced examples + established API. Re-verify the exact query params + `CloseStream`
  behavior at plan time and in the live round-trip.
- **WAV encoding** is the one genuinely new mechanic (batch providers need a file container, not
  raw PCM). Kept to a minimal PCM16 mono WAV.
- **AssemblyAI extraction must be behavior-preserving** — its `CloudEngineTests` must stay green
  after the refactor (the regression proof).
