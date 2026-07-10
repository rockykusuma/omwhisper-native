# M3 Sub-project 2a — Ollama Polish Backend — Design

**Date:** 2026-07-10
**Milestone:** M3 (AI polish), sub-project 2, part a. Splits the planned "Ollama + Cloud
backends" milestone: **this part ships Ollama only** (fully local, no egress). The Cloud
(OpenAI-compatible) backend + its egress-privacy decision (redact vs. warn-only) are a
separate follow-up (2b), deliberately deferred (user decision 2026-07-10).

## Goal

Let the user choose a local **Ollama** model as the AI-polish backend, alongside the existing
`Disabled` and `System (Apple Intelligence)` options — so polish flexibility mirrors what M4
did for transcription. Ollama runs on the user's own machine, so nothing leaves the device and
there is no new privacy surface.

## Background (verified against current code + the old Tauri app)

- **Contract** (`Polish/PolishBackend.swift`): `protocol PolishBackend: Sendable { func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String }`.
  `SystemLLM` already conforms. Adding an `Ollama` conformer is additive.
- **Prompt building**: `SystemLLM.instructions(for:targetLanguage:)` does one thing — if the
  style `requiresTargetLanguage`, substitute `{language}` in `style.prompt`; else use
  `style.prompt` verbatim. This must be shared, not duplicated.
- **Dispatch today** (`AppState.polishedText(for:)`): hard-checks `polishBackend == .system`
  and calls `systemLLM.polish(...)` directly, with a fail-safe fallback (any failure — disabled,
  unavailable, error, timeout — returns the *original* text so dictated text is never dropped).
  `beginReplyAssist`/`draftAndStream` similarly gate on `SystemLLM.isAvailable(), polishBackend == .system`
  then make a single `systemLLM.polish(...)` call (it streams the *result* via keystrokes, not
  the model tokens — so it works with any `PolishBackend`).
- **`PolishBackendKind`** (`AppState.swift`): `enum { case disabled, system }` with the marker
  `// Sub-project 2 adds: case ollama, cloud`.
- **Old Tauri app reference** (`src-tauri/src/ai/ollama.rs`, `mod.rs`):
  - `POST {baseURL}/api/chat` body `{model, stream:false, messages:[{role:"system",content:prompt},{role:"user",content:text}]}`; response `{message:{content:String}}`, trimmed.
  - `GET {baseURL}/api/tags` → `{models:[{name:String}]}` for reachability (`check_status`) and the model list (`list_models`).
  - `strip_llm_wrapper` post-processes **all** backends' output — trims "Output:"/"Here is …:"
    preambles and trailing meta-commentary ("I removed the filler…", parenthesized asides).
  - Default base URL `http://localhost:11434`; timeout was a user-configurable
    `ai_timeout_seconds`.
- **Settings UI**: `UI/AISettingsView.swift` (rendered as the hub's "AI Polish" section) is a
  `PorcelainPage` of `PorcelainSection`s with a `.radioGroup` backend `Picker`. The
  `TranscriptionSettingsView` engine picker is the exact precedent for "radio row reveals a
  config section with a reachability/test button" (it does this for Parakeet's model download).

## Architecture

### 1. `Polish/Ollama.swift` (new)

`nonisolated struct Ollama: PolishBackend` (nonisolated for the same reason as `SystemLLM`/
`CloudEngine` — the project's MainActor-by-default would otherwise pin it, breaking the
`nonisolated` protocol requirement and the pure-function tests).

Stored: `baseURL: String`, `model: String`.

Pure, directly-tested helpers (no network — mirrors `CloudEngine`'s helper style):
- `static func chatURL(baseURL: String) -> URL?` — `{trimmedTrailingSlash}/api/chat`.
- `static func tagsURL(baseURL: String) -> URL?` — `{trimmedTrailingSlash}/api/tags`.
- `static func requestBody(model: String, systemPrompt: String, text: String) -> Data` — the
  `{model, stream:false, messages:[…]}` JSON (Encodable structs, `stream:false`).
- `static func parseChatContent(_ data: Data) -> String?` — decode `{message:{content}}`,
  return trimmed content (nil on malformed / missing).
- `static func parseModelNames(_ data: Data) -> [String]` — decode `{models:[{name}]}` → names
  (empty on malformed).

Effectful methods:
- `func polish(_ text:style:targetLanguage:) async throws -> String` — builds the system prompt
  via `style.systemPrompt(targetLanguage:)` (see §2), POSTs to `chatURL`, decodes via
  `parseChatContent`, then returns `stripLLMWrapper(content)` (see §3). Throws
  `OllamaError.unreachable` / `.httpStatus(Int)` / `.emptyResponse` with `LocalizedError`
  messages. Uses a `URLSession` with `request.timeoutInterval = 30` (a fixed constant, not a
  user setting — keeps the tab simple per the M3 spec; the paste path's raw-text fallback
  already covers a timeout). `ponytail:` comment marks the fixed timeout + upgrade path.
- `static func checkStatus(baseURL: String) async -> Bool` — `GET tagsURL`, true iff 2xx
  (3s timeout). Never throws (returns false).
- `static func listModels(baseURL: String) async -> [String]` — `GET tagsURL` → `parseModelNames`
  (5s timeout, `[]` on any failure).

### 2. Shared prompt building — `PolishStyle.systemPrompt(targetLanguage:)`

Add to `PolishBackend.swift` (where `PolishStyle` lives):

```swift
nonisolated extension PolishStyle {
    /// The system prompt for this style. Substitutes `{language}` when the style
    /// needs a target language, else returns `prompt` verbatim. Shared by every backend.
    func systemPrompt(targetLanguage: String?) -> String {
        guard requiresTargetLanguage, let targetLanguage else { return prompt }
        return prompt.replacingOccurrences(of: "{language}", with: targetLanguage)
    }
}
```

`SystemLLM.instructions(for:targetLanguage:)` is replaced by a call to this (behavior identical
— confirmed by the existing SystemLLM tests staying green).

### 3. `stripLLMWrapper` — `Polish/PolishPostProcessing.swift` (new)

Port the old app's `strip_llm_wrapper` / `is_meta_commentary` / `strip_inline_commentary` as a
pure `nonisolated func stripLLMWrapper(_ text: String) -> String`. Applied to **Ollama output
only** — `SystemLLM` is left byte-for-byte unchanged (Foundation Models is well-behaved and
already shipped/verified; re-processing it is unrequested risk). Directly unit-tested against
the old app's documented cases ("Output:" prefix, "Here is …:" preamble + blank line, trailing
"(I removed the filler words)", inline "…back home. I made some minor adjustments").

### 4. `AppState` changes

- `PolishBackendKind` → `case disabled, system, ollama` (Cloud still deferred).
- New settings (UserDefaults-backed, `access`/`withMutation` pattern — both back Pickers/fields
  that must re-render on change):
  - `ollamaBaseURL: String` (default `"http://localhost:11434"`).
  - `ollamaModel: String` (default `""` — empty until the user picks one; polish falls back to
    raw text if empty, same as any other failure).
  - `SettingsKeys` += `ollamaBaseURL`, `ollamaModel`.
- New `func activePolishBackend() -> PolishBackend?` — the single dispatch point:
  ```
  switch polishBackend {
  case .disabled: nil
  case .system:   SystemLLM.isAvailable() ? systemLLM : nil   // nudge handled by caller
  case .ollama:   ollamaModel.isEmpty ? nil : Ollama(baseURL: ollamaBaseURL, model: ollamaModel)
  }
  ```
- `polishedText(for:)` rewritten to use `activePolishBackend()`: if nil → return original (with
  the existing Foundation-Models-unavailable one-time nudge kept, fired only for the
  `.system`-but-unavailable case); else `try await backend.polish(...)` inside the existing
  do/catch that falls back to the original text on any throw. Net behavior for `.system` is
  identical to today; `.ollama` is the new path; `.disabled` unchanged.
- `draftAndStream(...)` (Reply Assist): swap the `SystemLLM.isAvailable(), polishBackend == .system`
  guard + `systemLLM.polish(...)` for `activePolishBackend()` (nil → the existing "backend
  unavailable" bail). Reply Assist now honors Ollama too.
- **Unchanged, deliberately**: `ChronicleScheduler`'s `polishBackend == .system && SystemLLM.isAvailable()`
  gate and `Chronicler` stay System-only — its map-reduce chunking is tuned to SystemLLM's
  5s/2000-char envelope; Ollama support there is a separate follow-up. With `.ollama` selected,
  chronicle auto-generation is inactive (same as when the backend is `.disabled` today). A
  `ponytail:` note records this.

### 5. `UI/AISettingsView.swift`

Extend the Backend `PorcelainSection`:
- Add a third radio tag: `Text("Ollama (local)").tag(PolishBackendKind.ollama)`.
- When `state.polishBackend == .ollama`, reveal a new `PorcelainSection(eyebrow: "Ollama")`:
  - A base-URL `TextField` (`.porcelainField()`), bound to `state.ollamaBaseURL`.
  - A **Test Connection** button → `Task { reachable = await Ollama.checkStatus(baseURL:); models = reachable ? await Ollama.listModels(baseURL:) : [] }`, driving local `@State` (`reachable`/`models`/`isChecking`), same pattern as `TranscriptionSettingsView`'s Parakeet download.
  - Status line: "Connected — N models" / "Couldn't reach Ollama at <url>. Is it running?".
  - A model `Picker` bound to `state.ollamaModel`, populated from `models`; if the list is empty
    but reachable, a hint: "No models installed — run `ollama pull <model>`." The currently-saved
    `ollamaModel` is shown even before a check (so a returning user sees their choice).
  - A one-line note: "Runs entirely on your Mac via Ollama. Nothing leaves this device."

### 6. Tests (`omwhisper-nativeTests/`)

New `OllamaTests` (pure, no network — matching `CloudEngineTests`):
- `chatURL`/`tagsURL` build + trailing-slash trimming.
- `requestBody` encodes `stream:false` + system/user messages (decode-back assertion).
- `parseChatContent` — valid, missing `message`, malformed JSON, whitespace trimming.
- `parseModelNames` — valid list, empty, malformed.
`PolishPostProcessingTests` — the `stripLLMWrapper` cases above.
`PolishStyleTests` (or extend an existing) — `systemPrompt(targetLanguage:)`: Translate
substitutes `{language}`, non-translate returns `prompt` verbatim, nil language on a
translate style returns `prompt` unchanged.
The full suite must stay green; `SystemLLM`'s existing tests prove the prompt-extraction
refactor is behavior-preserving.

## Live verification (owed, needs a real Ollama)

Automated tests cover every pure piece; the actual localhost round-trip is **not** unit-tested
(no network in tests). Before calling this done end-to-end: with Ollama installed and a model
pulled, select Ollama in Settings, Test Connection populates the model list, then a real
Smart Dictation / Polish Selected cycle produces Ollama-polished text; stopping with Ollama
unreachable falls back to raw text (the fail-safe). This mirrors M4.1/M4.2's "pure pieces
tested, live round-trip verified separately" status.

## Out of scope (explicit)

- **Cloud (OpenAI-compatible) backend** and its egress-privacy decision (redact vs. warn-only) —
  sub-project 2b, deferred.
- **Keychain** changes — Ollama needs no API key; the `Keychain` generalization waits for 2b.
- **Chronicler on Ollama** — stays System-only (see §4).
- **Configurable timeout / temperature** UI — fixed sane defaults; the M3 spec's "sane internal
  defaults keep this tab simple" holds.
- **Streaming model tokens** — one-shot (`stream:false`), matching the atomic stop-and-paste
  model and the old app.
