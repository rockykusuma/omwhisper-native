# M3 Sub-project 2b — Cloud (OpenAI-compatible) Polish Backend — Design

**Date:** 2026-07-10
**Milestone:** M3 (AI polish), sub-project 2, part b — the second half of the "Ollama + Cloud
backends" milestone. 2a (Ollama, local) shipped 2026-07-10; **this part adds the Cloud
(OpenAI-compatible) backend + its egress-privacy layer.** With 2b, M3 sub-project 2 is complete.

## Goal

Let the user choose a hosted OpenAI-compatible LLM as the polish backend, alongside `Disabled`,
`System`, and `Ollama`. Because this is the one place dictated **text** leaves the device,
egress is gated by a redactor that scrubs secrets/PII before the request and re-hydrates the
response — decided 2026-07-10 (user chose "port the redactor" over warn-only).

## Background (verified against current code + the old Tauri app)

- **Contract**: `PolishBackend.polish(_:style:targetLanguage:) async throws -> String`.
  `SystemLLM` and `Ollama` already conform.
- **Dispatch (from 2a)**: `AppState.activePolishBackend() -> PolishBackend?` is the single
  selection point; both `polishedText(for:)` (dictation stop-paste, Smart Dictation, Polish
  Selected, Re-polish) and Reply Assist's `draftAndStream` route through it. Adding a `.cloud`
  case wires Cloud into every one of those paths — **including Reply Assist, whose drafts are
  therefore auto-redacted too.** The fail-safe (any failure → return original text) is preserved.
- **Shared pieces (from 2a)**: `PolishStyle.systemPrompt(targetLanguage:)` builds the prompt;
  `stripLLMWrapper(_:)` (`Polish/PolishPostProcessing.swift`) trims model preamble/postamble —
  reused here.
- **Keychain (from M4.2)**: `Transcription/Keychain.swift` — a generic-password wrapper scoped
  to `assemblyAIAccount = "assemblyai-api-key"` (`loadAssemblyAIKey`/`save`/`delete`). This
  generalizes here to also hold the cloud-LLM key; the AssemblyAI path stays working.
- **Old Tauri app (functional spec)**:
  - `ai/cloud.rs`: `POST {api_url}/chat/completions`, `Authorization: Bearer {key}`, body
    `{model, messages:[{system},{user}], temperature:0.3}`, response `.choices[0].message.content`
    trimmed. Redaction gated here (`prepare_outbound(true, text)`); when anything was redacted,
    the system prompt is extended to tell the model to keep `[REDACTED_…]` placeholders verbatim;
    the response is `rehydrate`d. `test_connection` sends `"Hello."` with system `"Reply with
    exactly: OK"`. Defaults (`settings.rs`): `ai_cloud_api_url = https://api.openai.com/v1`,
    `ai_cloud_model = gpt-4o-mini`, `ai_timeout_seconds = 30`.
  - `ai/redactor.rs`: a 10-detector registry (PRIVATE_KEY PEM, AWS/Slack/GitHub/Google/OpenAI
    keys, Bearer tokens, EMAIL, Luhn-validated CARD, PHONE heuristic, high-entropy SECRET),
    overlap resolution (earliest-start wins, ties by detector priority), stable typed
    placeholders (`[REDACTED_<TYPE>_<n>]`, same value → same placeholder), `rehydrate`, and the
    `prepare_outbound(is_cloud:)` fail-closed gate.

## Architecture

### 1. `Polish/Redactor.swift` (new) — faithful port of `redactor.rs`

`nonisolated`. Uses `NSRegularExpression` (ICU regex — compatible with the Rust patterns,
including `(?s)` dotall and `\b`) rather than Swift `Regex` literals, so the exact patterns port
verbatim with predictable behavior.

```
nonisolated struct Redaction {
    let text: String                    // input with sensitive spans replaced by placeholders
    let mapping: [String: String]       // placeholder -> original (in-memory only; never logged)
    func rehydrate(_ text: String) -> String   // restore placeholders the response echoed back
}
nonisolated func redact(_ text: String) -> Redaction
```

- **Detector registry** (a `private let detectors: [Detector]`, highest priority first — same
  order as the Rust): each `Detector { kind, regex: NSRegularExpression, validate: ((String) -> Bool)? }`.
  Patterns copied verbatim from the Rust.
- **Validators** (pure Swift): `luhnValid`, `isPhone`, `isHighEntropySecret`, `shannonEntropy` —
  ported line-for-line.
- **Algorithm** (same three passes): collect accepted candidates (regex match + optional
  validator), resolve overlaps greedily (sort by start then priority, keep non-overlapping),
  assign stable typed placeholders while building the output in one pass.
- **No `prepare_outbound` gate**: `CloudLLM.polish` is the *only* cloud text path in this app
  (System/Ollama are local), and it calls `redact` as its first step. A separate is-cloud gate
  would be an abstraction over a single call site — YAGNI. The fail-closed guarantee is met by
  `redact` being total (it cannot throw; it always returns a `Redaction`) and unconditional in
  `CloudLLM.polish`.
- **Rehydrate is order-independent**: placeholders are bracket-delimited, so
  `[REDACTED_EMAIL_1]` (ending in `]`) is *not* a substring of `[REDACTED_EMAIL_11]` — a plain
  per-entry `replacingOccurrences` in any `mapping` order is safe, exactly as the Rust does. No
  ordering trick needed. (Original values are real secrets/PII, never `[REDACTED_…]` strings, so
  a replacement can't introduce a new false placeholder.)

### 2. `Polish/CloudLLM.swift` (new) — `PolishBackend` conformer

`nonisolated struct CloudLLM: PolishBackend`. Stored: `apiURL: String`, `model: String`,
`apiKey: String` (AppState reads the key from Keychain and passes it in — the type never touches
the Keychain itself, keeping it pure/testable).

Pure helpers (directly tested, no network — mirrors `Ollama`/`CloudEngine`):
- `static func completionsURL(apiURL: String) -> URL?` — `{trimmedTrailingSlash}/chat/completions`.
- `static func requestBody(model:systemPrompt:userText:) -> Data` — `{model, messages:[{role:"system",…},{role:"user",…}], temperature:0.3}`.
- `static func parseContent(_ data: Data) -> String?` — decode `.choices[0].message.content`, trimmed (nil on malformed/empty choices).
- `static func placeholderInstruction(_ base: String, redactedAny: Bool) -> String` — when
  `redactedAny`, append the "keep every `[REDACTED_TYPE_N]` placeholder exactly as-is" clause
  (ported verbatim from the Rust); else return `base`. (Pure → tested.)

Effectful:
- `func polish(_ text:style:targetLanguage:) async throws -> String`:
  1. `let redaction = redact(text)` — scrub first, always.
  2. `let system = Self.placeholderInstruction(style.systemPrompt(targetLanguage:), redactedAny: !redaction.mapping.isEmpty)`.
  3. `POST completionsURL`, header `Authorization: Bearer \(apiKey)`, body `requestBody(model:, systemPrompt: system, userText: redaction.text)`, `timeoutInterval = 30`.
  4. Non-2xx → `throw CloudLLMError.httpStatus(code)`; transport error → `.unreachable`.
  5. `guard let content = parseContent(data), !content.isEmpty else { throw .emptyResponse }`.
  6. `return redaction.rehydrate(stripLLMWrapper(content))`.
- `CloudLLMError: LocalizedError { badURL, unreachable, httpStatus(Int), emptyResponse }`.
- `static func testConnection(apiURL:model:apiKey:) async -> String?` — sends `"Hello."` with
  system `"Reply with exactly: OK"` (10s timeout); returns `nil` on success or a human error
  string on failure, for the Settings UI. (Reuses `completionsURL`/`requestBody`/`parseContent`.)

### 3. `Transcription/Keychain.swift` — generalize (M4.2 path unaffected)

Extract private `load(account:)` / `save(_:account:)` / `delete(account:)` (the current
AssemblyAI bodies, parameterized on `account`). Keep the existing
`loadAssemblyAIKey`/`saveAssemblyAIKey`/`deleteAssemblyAIKey` as thin delegators (so M4.2's
`CloudEngine` is untouched). Add `cloudLLMAccount = "cloud-llm-api-key"` and
`loadCloudLLMKey`/`saveCloudLLMKey`/`deleteCloudLLMKey` delegators. The full suite (incl.
`KeychainTests`) staying green proves the refactor is behavior-preserving.

### 4. `AppState`

- `PolishBackendKind` → `case disabled, system, ollama, cloud` (drop the "2b adds cloud" marker).
- New settings (UserDefaults, `access`/`withMutation`): `cloudAPIURL` (default
  `"https://api.openai.com/v1"`), `cloudModel` (default `"gpt-4o-mini"`). The **key is not a
  setting** — it lives in Keychain, read on demand.
- `activePolishBackend()` gains:
  ```
  case .cloud:
      guard let key = Keychain.loadCloudLLMKey(), !key.isEmpty else { return nil }
      return CloudLLM(apiURL: cloudAPIURL, model: cloudModel, apiKey: key)
  ```
  (No key saved → nil → the raw-text fallback fires, same as Ollama with no model.)
- `SettingsKeys` += `cloudAPIURL`, `cloudModel`.
- `polishedText(for:)` and `draftAndStream(...)` are **unchanged** — they already route through
  `activePolishBackend()` (2a). Reply Assist via Cloud is therefore redacted for free.

### 5. `UI/AISettingsView.swift`

Add a Cloud radio tag (`Text("Cloud (OpenAI-compatible)").tag(PolishBackendKind.cloud)`), and,
when selected, a `PorcelainSection(eyebrow: "Cloud")`:
- An upfront privacy line (always visible, never behind a disclosure): "Your dictated text is
  sent to this provider while polishing. Secrets and PII (emails, keys, cards) are redacted
  before it leaves your Mac. Requires your own API key."
- API URL `TextField` (`.porcelainField()`, bound to `state.cloudAPIURL`).
- Model `TextField` (`.porcelainField()`, bound to `state.cloudModel`) — free text (any
  OpenAI-compatible model id).
- `SecureField` for the key + Save / Clear buttons backed directly by
  `Keychain.saveCloudLLMKey`/`deleteCloudLLMKey` (local `@State keyInput`/`hasSavedKey`), plus a
  saved/not-saved status line — the exact pattern M4.2's `TranscriptionSettingsView` cloud
  section uses.
- A **Test Connection** button → `CloudLLM.testConnection(...)`, driving local `@State`
  (`testing`/`testResult`), same shape as 2a's Ollama test-connection.

### 6. Tests (`omwhisper-nativeTests/`)

- `RedactorTests` — port the Rust tests: email; OpenAI `sk-` key; Bearer; Slack/AWS/GitHub/Google
  keys; PEM private-key block; Luhn-valid-card-only; phone-but-not-year-range; high-entropy
  secret (and plain long word not flagged); stable/typed placeholders (same value reused,
  distinct value → new number); `rehydrate` restores originals; clean text unchanged. Fixtures
  build secret-looking values by concatenation so secret scanners don't flag the test source
  (same trick the Rust uses).
- `CloudLLMTests` — `completionsURL` (+ trailing-slash trim); `requestBody` (model, temperature
  0.3, system+user roles via `JSONSerialization`); `parseContent` (valid, missing choices,
  malformed); `placeholderInstruction` (appends the clause iff redactedAny).
- `KeychainTests` — add a cloud-LLM key round-trip (save → load → overwrite → delete → load nil),
  independent of the AssemblyAI item; a real Keychain round-trip in the test host, matching the
  existing `KeychainTests` precedent.
- Full suite stays green (234 → ~262).

## Live verification (owed, needs a real API key)

Pure pieces are all unit-tested; the actual `/chat/completions` round-trip is **not** (no
network in tests). Before calling this done end-to-end: with a real OpenAI-compatible key saved,
select Cloud, Test Connection succeeds, a real Smart Dictation / Polish Selected produces
cloud-polished text, a sentence containing an email + fake card comes back correctly polished
**with the real values intact** (redact → rehydrate round-trips), and clearing the key falls
back to raw text. Matches M4.1/M4.2/2a's "pure pieces tested, live round-trip separate" status.

## Out of scope (explicit)

- **Chronicler on Cloud** — stays System-only (its map-reduce is `SystemLLM`-tuned), same
  boundary as 2a. With `.cloud` selected, chronicle auto-generation is inactive.
- **Streaming** — one-shot, matching the atomic stop-and-paste model.
- **Non-OpenAI-shaped providers**, temperature/timeout UI, multiple saved provider profiles —
  fixed sane defaults; the tab stays simple.
- **Redacting the System/Ollama paths** — they are on-device; redaction is cloud-only by design.
