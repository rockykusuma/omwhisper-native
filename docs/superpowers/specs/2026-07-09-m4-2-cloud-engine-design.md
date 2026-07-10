# Design: M4.2 — CloudEngine (AssemblyAI streaming)

> Written 2026-07-09. Brainstormed via `superpowers:brainstorming`. Second
> and final sub-project implementing M4 ("Backend flexibility — the USP")
> from `docs/NATIVE_MIGRATION_PLAN.md`, following M4.1 (ParakeetEngine).
> This is the actual differentiator this project's North Star names:
> "user choice of local vs. cloud transcription... not 'always local.'"

## Goal

A third `TranscriptionEngine` backed by a real cloud streaming ASR
provider, selectable from the existing Transcription Settings tab
alongside Apple and Parakeet (both fully local). Requires the user's own
API key, stored in Keychain — the first real cloud-egress feature this
app ships.

## Reference: provider research (verified directly against docs, not assumed)

Both **AssemblyAI** and **Deepgram Flux** were named as open candidates in
`docs/NATIVE_MIGRATION_PLAN.md` ("pick one provider first"). Fetched both
providers' current docs directly before choosing:

- **AssemblyAI Universal Streaming** — `wss://streaming.assemblyai.com/v3/ws?speech_model=...&sample_rate=16000`.
  Auth: permanent API key via `Authorization` header (no `Bearer` prefix),
  **plus a genuine ephemeral/temporary-token endpoint**
  (`/streaming/authenticate-with-a-temporary-token`) specifically for
  client apps that shouldn't embed a permanent secret in every connection.
  Message format: `{"type": "Turn", "end_of_turn": bool, "transcript": "...", "words": [...]}` —
  `end_of_turn` maps directly onto this app's `.final`/`.partial` split, no
  reconciliation needed. "Keyterms prompting": up to 100 terms, 50 chars
  each, passed as connection query params, dynamically updatable mid-session
  via an `UpdateConfiguration` message — maps directly onto this app's
  existing `vocabulary: [String]` parameter. Audio: mono 16-bit PCM,
  sample rate matching the connection param (16kHz), ~50ms chunks.
  Pricing: $0.15/hr (Universal Streaming) or $0.45/hr (Universal-3 Pro).
- **Deepgram Flux** — `wss://api.deepgram.com/v2/listen?model=flux-general-en`.
  Auth: permanent API key via `Authorization: Token` header only — no
  ephemeral-token option found for client apps. Built around conversational
  **turn detection** (`eot_threshold`/`eot_timeout_ms` tuning, `TurnInfo`
  messages, `TurnResumed` events) rather than a simple partial/final
  split — designed for voice-agent phone-call-style interaction, where the
  *model* infers when the user stopped talking. This app's own PTT
  release/stop button already defines the end of a segment explicitly;
  layering Flux's own turn-inference on top would mean either fighting it
  or awkwardly leaving it unused. Some keyterm support exists
  (`STTUpdateSettingsFrame`) but is less clearly documented as a direct
  vocabulary-list mechanism than AssemblyAI's.

**Chose AssemblyAI**: its API shape requires no semantic reconciliation
with this app's existing `TranscriptEvent`/`vocabulary` contract, and its
ephemeral-token flow is a meaningfully better security fit for a native
client storing a long-lived secret in Keychain.

## Architecture

### CloudEngine — stateless, like AppleEngine

Unlike `ParakeetEngine` (a persistent class amortizing expensive CoreML
model loads), a streaming ASR *connection* has no comparable warm-up cost
to preserve across sessions — each dictation session opens a fresh
WebSocket and closes it at the end. `CloudEngine` is a `struct`, matching
`AppleEngine`'s shape:

```swift
struct CloudEngine: TranscriptionEngine {
    let kind: EngineKind = .cloud

    enum EngineError: Error, LocalizedError {
        case missingAPIKey
        case tokenRequestFailed
        case connectionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "Add your AssemblyAI API key in Settings → Transcription to use Cloud."
            case .tokenRequestFailed: "Couldn't authenticate with AssemblyAI."
            case .connectionFailed: "Couldn't connect to AssemblyAI."
            }
        }
    }

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        // 1. Read API key from Keychain; throw .missingAPIKey if absent.
        // 2. POST to AssemblyAI's temporary-token endpoint with the
        //    permanent key; throw .tokenRequestFailed on failure.
        // 3. Open URLSessionWebSocketTask to the v3/ws endpoint with the
        //    temporary token + sample_rate query params. Keyterms limited
        //    to vocabulary.prefix(100), each truncated to 50 chars (the
        //    documented AssemblyAI limits) -- not this app's own limit,
        //    a hard constraint of the provider.
        // 4. Task A: convert each incoming buffer via the existing
        //    BufferConverter to 16kHz mono Int16 PCM, send as a binary
        //    WebSocket frame.
        // 5. Task B: receive JSON messages, decode Turn events, yield
        //    .final(transcript) when end_of_turn, else .partial(transcript).
        // 6. On audio stream end: send AssemblyAI's documented
        //    session-termination message, await final Termination event,
        //    close the socket, finish the continuation.
    }
}
```

(Exact `URLSessionWebSocketTask` delegate/continuation wiring, and the two
concurrent tasks' cancellation/error-propagation shape, is a plan-writing
concern — the contract above is what matters at design time.)

### Keychain storage — new, first use in this codebase

No Keychain wrapper exists anywhere in this project yet (`CloudLLM`, the
only prior mention, was never built — M3 sub-project 2 deferred). New
`omwhisper-native/Transcription/Keychain.swift`: a small wrapper over
Security framework calls (`SecItemAdd`/`SecItemCopyMatching`/
`SecItemUpdate`/`SecItemDelete`) scoped to one named generic-password item
(service = this app's bundle ID, account = `"assemblyai-api-key"`). Native
platform feature, no new dependency. `CloudEngine.swift` itself also lives
in `Transcription/`, alongside `AppleEngine.swift`/`ParakeetEngine.swift`/
`BufferConverter.swift`/`TranscriptionEngine.swift` — no new directory.

### Vocabulary redaction on cloud egress

The real, narrow gap S2's design spec flagged ("redaction until M4's
CloudEngine starts consuming vocabulary") is specifically about **S2's
auto-extracted screen terms** — proper nouns/code identifiers/rare words
pulled from whatever's on screen at dictation start, merged into
`engineVocabulary` without the user ever explicitly reviewing or approving
that specific list. The user's own manually-typed custom vocabulary
(`customVocabulary` in Settings) is different — the user chose those terms
deliberately, and by selecting Cloud at all they've already accepted their
*spoken audio* leaving the device, which is a strictly larger exposure than
a short keyterm list. So: when `engineKind == .cloud`, `AppState`'s
existing vocabulary-assembly step sends **only** `customVocabulary` as
keyterms, never merging in S2's `screenTerms` — a small, targeted
conditional at the one call site that already exists (`AppState.swift`'s
`engineVocabulary` construction), not a new redaction subsystem.

### Settings UI

`UI/TranscriptionSettingsView.swift` (extended, not replaced): the "Cloud"
picker row — currently present but disabled with "coming in a future
update" — becomes selectable. Selecting it reveals a new section: a
`SecureField` for the AssemblyAI API key (backed by Keychain, not
`UserDefaults` — read/write go through `Keychain.swift` directly, no
`AppState` setting for the key itself, matching the "keys in Keychain, not
plaintext settings" principle already documented in this project's Tech
Stack table), Save/Clear buttons, and a status line ("Key saved." /
"No key saved yet."). A clear, upfront warning line: "Streams your voice
live to AssemblyAI (a third-party service) while dictating. Requires your
own API key — see assemblyai.com for pricing." No silent cloud selection —
the cost/privacy trade-off is stated plainly before the radio button, not
buried in a tooltip.

## Global Constraints

- `CloudEngine` is a stateless `struct` — no persistent connection or
  loaded state kept between dictation sessions, unlike `ParakeetEngine`.
- No new SPM dependency — `URLSessionWebSocketTask` (Foundation, native)
  handles the WebSocket; `Keychain.swift` wraps the native Security
  framework. Matches this project's "ladder" convention: native platform
  feature before a third-party package.
- The API key never touches `UserDefaults` or any other plaintext
  storage — Keychain only, read fresh each time `CloudEngine.transcribe()`
  is called (matching how `vocabulary` itself is read fresh per call, not
  cached).
- Every WebSocket connection uses AssemblyAI's ephemeral-token flow, never
  the permanent key directly on the streaming connection.
- When `engineKind == .cloud`, S2's auto-extracted screen terms are
  excluded from the vocabulary sent as keyterms — only the user's own
  explicitly-configured `customVocabulary` goes to the cloud provider.
  This is the one behavioral difference from Apple/Parakeet's vocabulary
  handling, and it's conditional on the active engine, not a global change
  to `engineVocabulary`'s construction for the other two engines.
- Keyterms sent to AssemblyAI are capped at the provider's own documented
  limits (100 terms, 50 chars each) — a hard external constraint truncated
  at the query-construction boundary, not a design choice of this app's.
- Cloud must never be silently selectable without the warning copy being
  visible — the UI shows the privacy/cost statement in the same view as
  the radio button, not gated behind a separate disclosure step.

## Error Handling & Permissions

- No API key saved → `CloudEngine.transcribe()` throws
  `EngineError.missingAPIKey` immediately (before opening any connection),
  surfaced via this app's existing "engine error → toast, not crash"
  convention (same pattern `AppleEngine`/`ParakeetEngine` already use).
- Ephemeral-token request failure (bad key, network down, AssemblyAI
  outage) → `EngineError.tokenRequestFailed`, same toast path.
- WebSocket connection/auth failure after a token was obtained →
  `EngineError.connectionFailed(underlying)`, same toast path.
- Mid-session network drop → the receive loop's error propagates through
  the `AsyncThrowingStream`, ending the session the same way any other
  engine failure does today — no silent hang, no partial-only session with
  no final text (matches this app's existing unified-fallback principle
  from M3: something always happens, never a silently dropped session).

## Testing

Pure-logic pieces (Swift Testing): keyterm truncation/capping (100 terms
max, 50 chars each) as an extracted, directly-testable pure function;
AssemblyAI's `Turn` JSON decoding → `TranscriptEvent` mapping (same
"extract the pure decision from the effectful wrapper" pattern as
`ParakeetEngine.mapUpdate`); the vocabulary-exclusion-for-cloud logic at
`AppState`'s `engineVocabulary` call site (already an existing, pure-ish
computation — add a case for `.cloud` and test it directly). `Keychain.swift`'s
read/write round-trip is testable against the real Keychain in a unit
test (Security framework calls work fine in a test host process; no
mocking needed, same "not scary, just I/O" reasoning `HistoryStore`/
`MemoryStore` tests already use against real GRDB). The actual WebSocket
connection, AssemblyAI's real API responses, and end-to-end audio
streaming are **not unit-testable** (no live network access from tests,
no AssemblyAI sandbox/mock documented) — verified live instead, requiring
a real AssemblyAI account and API key from the user.

**Exit criteria**: Cloud appears as a selectable engine with clear warning
copy; an API key can be saved/cleared via Keychain; with a real key saved,
a live dictation session with Cloud active produces live partials and a
correct final transcript; a custom vocabulary term is respected; screen-
auto-extracted terms are confirmed absent from what's sent to AssemblyAI
when Cloud is active (verifiable via a debug log line, not a UI element);
missing/invalid key produces a clear error rather than a silent failure.
