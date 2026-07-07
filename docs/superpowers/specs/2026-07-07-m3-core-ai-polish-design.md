# Design: M3 Sub-project 1 — Core AI Polish

> Written 2026-07-07. Brainstormed via `superpowers:brainstorming`. Implements the
> first half of the "M3 — AI polish" milestone from `CLAUDE.md` (styles system,
> `SystemLLM`/Foundation Models backend, Smart Dictation, Polish Selected Text).
> Ollama/Cloud backends + Keychain key storage are a separate sub-project 2,
> deliberately deferred — mirrors how M1 shipped `AppleEngine` before M4's
> Parakeet/Cloud engines.

## Goal

Add AI text polish to the app: a library of rewrite styles (Professional, Casual,
Concise, Translate, Email Format, Meeting Notes, Smart Correct), a default
on-device backend (Apple's Foundation Models framework), and two new entry
points that use it — Smart Dictation (Cmd+Shift+B, always polishes what you just
said) and Polish Selected Text (Cmd+Shift+P, polishes whatever's selected in the
frontmost app). Regular dictation (Cmd+Shift+V) is unaffected — punctuation is
already handled in-engine by `SpeechTranscriber`, so it never needs polish.

## Reference: the old app's implementation

Investigated directly from `/Users/rakeshkusuma/Documents/PersonalProjects/omwhisper`
(Tauri/Rust, frozen, spec reference per this project's conventions — not code to
port line-by-line):

- `src-tauri/src/styles.rs` — **7** built-in styles today (the "6 built-ins" in
  some of this project's older docs is stale; Smart Correct was added later via
  PR #31). Plus an 8th, hidden `punctuate` style used only for LLM-punctuating
  regular dictation — **not ported**, since `SpeechTranscriber` already
  punctuates in-engine (see this project's "Explicitly Dropped" list).
- `src-tauri/src/ai/{mod,llm,ollama,cloud}.rs` — backend dispatch is a plain
  `match` on a `String`, not a formal trait. Four states: disabled / built-in
  (bundled llama.cpp + Qwen2.5-0.5B) / Ollama / Cloud (OpenAI-compatible). API
  keys are stored in **plaintext** in `settings.json` (a deliberate old-app
  trade-off to avoid Keychain prompts in unsigned dev builds — not appropriate
  for this project, which is properly signed; Keychain storage is already
  locked in for the Cloud backend in sub-project 2).
- Smart Dictation (Cmd+Shift+B) always applies the user's globally-configured
  default style on stop; "raw fallback" means pasting unpolished text if polish
  fails — but the old app's fallback isn't actually unconditional: one specific
  failure (`llm_not_ready`) shows a toast and pastes **nothing**, silently
  losing the user's dictated text. Fixed in this design (see Error Handling).
- Polish Selected Text (Cmd+Shift+P) — not in this project's `CLAUDE.md` or
  parity checklist at all; confirmed with the user this was an omission, not a
  deliberate cut, and is in scope here.
- Translate is not a separate feature — it's a style whose prompt is
  parameterized with a target language at request time, with a conditionally
  shown language picker (fixed list of 11 languages) in Settings.
- Custom styles are identified by their prompt text, not a stable ID — editing
  is really "add a style with the same name" (silently overwrites), and two
  styles with identical prompts collide. Fixed here with real `UUID` identity.

## Scope for this pass

In scope: `PolishStyle` model + built-in catalog + custom CRUD, `SystemLLM`
backend (Foundation Models), Smart Dictation, Polish Selected Text, a basic
Disabled/System backend toggle in a new Settings AI tab.

Explicitly **not** in scope (sub-project 2, separate spec):

- Ollama backend, Cloud (OpenAI-compatible) backend.
- Keychain API key storage (only needed once Cloud exists).
- "Test connection" UI (only meaningful for network backends).
- Per-backend config (model/endpoint/timeout) beyond what System needs.

## Architecture

### `Polish/PolishBackend.swift` (expand existing stub)

```swift
struct PolishStyle: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var prompt: String
    var isBuiltIn: Bool
    /// Only meaningful for the Translate style; nil for every other style.
    var requiresTargetLanguage: Bool = false
}

protocol PolishBackend: Sendable {
    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String
}
```

`id` moves from a hand-assigned `String` to `UUID` — built-in styles get fixed,
hardcoded UUIDs (stable across app updates so `activePolishStyleID` survives);
custom styles get a fresh UUID on creation. This replaces the old app's
identify-by-prompt-text scheme.

### `Polish/PolishStyles.swift` (new)

Hardcoded catalog of the 7 built-ins (`Professional`, `Casual`, `Concise`,
`Translate`, `Email Format`, `Meeting Notes`, `Smart Correct`), each with a
single canonical prompt. Unlike the old app, there's no separate short/blunt
prompt variant for a small on-device model — Foundation Models is a
meaningfully more capable instruction-following model than the old app's
bundled 0.5B GGUF, so one well-written prompt per style should hold. Revisit
only if live testing shows Foundation Models needs different tuning.

### `Polish/SystemLLM.swift` (new)

`PolishBackend` conformance wrapping Apple's Foundation Models framework.
Wraps the actual model call in a timeout (starting at 5s, tuned from live
testing — the old app hard-capped its call at 2.5s for the same reason: a
cold/slow inference must never stall the paste). Throws on: Apple Intelligence
disabled, the model call erroring, or the timeout firing — all three collapse
to the same fallback behavior in the caller (see Error Handling), the backend
doesn't need to distinguish them for callers beyond the one-time nudge.

### `AppState` additions

New persisted settings (`UserDefaults`, same pattern as every other setting):

```swift
enum PolishBackendKind: String, Codable, CaseIterable {
    case disabled, system
    // sub-project 2 adds: case ollama, cloud
}

var polishBackend: PolishBackendKind        // default: .disabled
var activePolishStyleID: UUID?              // default: Smart Correct's fixed UUID
var translateTargetLanguage: String         // default: "English"
var customPolishStyles: [PolishStyle]       // default: []
```

Two new `GlobalHotkey` instances (Cmd+Shift+B, Cmd+Shift+P) — `GlobalHotkey`
already takes an arbitrary keycode/modifier combo and an action closure, so
this is pure instantiation, no changes to that class.

### Polish Selected Text mechanism

No new Accessibility surface. Mirrors `PasteService.paste()`'s existing
save/restore pattern, just for reading instead of writing: simulate Cmd+C
(same `CGEventPost` approach `sendCmdV()` already uses, just key `C`), read the
resulting pasteboard string, compare against the pre-copy pasteboard content —
unchanged means nothing was selected (silent no-op). `kAXSelectedTextAttribute`
was considered and rejected: it's inconsistently supported across
third-party/cross-toolkit apps, whereas Cmd+C works everywhere copy already
works.

## Data Flow

**Smart Dictation (Cmd+Shift+B).** Identical capture → transcribe pipeline as
regular dictation. On stop: if the transcript has fewer than 3 words, skip
polish and paste raw immediately (matches the old app's near-silent/
hallucination guard — no point spending an LLM call on garbage). Otherwise,
run the active style through the current backend before pasting. The overlay
gains one new sub-phase during the polish call — reusing the existing closed
color palette (`OVERLAY_SPEC.md` §2 is explicit: "no other colors in the
overlay"), a `POLISHING` label styled like `finalizing`'s pulse rather than
the old app's ad-hoc violet treatment.

**Polish Selected Text (Cmd+Shift+P).** Capture selection via the Cmd+C
mechanism above. If something was selected: run the active style/backend,
then paste the result back via the existing `PasteService.paste()` (save/
restore semantics unchanged). Shows the same overlay `POLISHING` indicator as
Smart Dictation, even though this isn't a dictation session — otherwise a
multi-second LLM call gives the user zero feedback that anything is
happening.

**Failure paths — unified.** Any reason polish doesn't produce text —
Foundation Models unavailable, backend set to Disabled, the model call errors,
or the timeout fires — funnels into one fallback: paste the *original* text
(the raw transcript for Smart Dictation, the originally-selected text for
Polish Selected Text) unconditionally. This fixes the old app's gap where the
`llm_not_ready` failure mode specifically skipped the fallback and silently
dropped the user's dictated text. When the specific cause is Foundation
Models being unavailable (Apple Intelligence off), also show a one-time
per-session toast pointing at Settings → AI — every other failure mode stays
silent, matching the "never surface an error" pattern already used for S2's
context capture (these are expected to be rare/transient, not a fixable user
setting in the moment).

## Settings

New **AI** tab in `SettingsView`'s existing `TabView` (alongside General/
Vocabulary/Audio/About):

1. **Backend selector** — Disabled / System (Foundation Models) for this pass;
   sub-project 2 adds Ollama/Cloud rows without restructuring this.
2. **Default Style** — dropdown of built-ins + custom, backing
   `activePolishStyleID`. Shared by both Smart Dictation and Polish Selected
   Text (one setting, not two — matches the old app).
3. **Target Language** — shown only when the active style is Translate, fixed
   list of 11 languages (English, Spanish, French, German, Japanese, Chinese,
   Hindi, Portuguese, Korean, Arabic, Russian), backing
   `translateTargetLanguage`.
4. **Custom styles** — name + prompt list with add/remove, following
   `VocabularySettingsView`'s existing word-replacement list UI pattern rather
   than inventing new layout. Built-ins shown read-only alongside (name +
   one-line description), not editable/removable.

No temperature/max-tokens/timeout knobs — Foundation Models doesn't expose the
same tunables the old app's Ollama/Cloud backends did; sane internal defaults
keep this tab simple. Sub-project 2 will need explicit timeout/model/endpoint
fields for Ollama and Cloud specifically.

## Error Handling

Every failure mode (Foundation Models unavailable, model error, timeout,
backend Disabled) resolves to "paste the original text unconditionally" —
never a silent text-loss like the old app's `llm_not_ready` case. Foundation-
Models-unavailable additionally shows a one-time-per-session Settings nudge.
Min-3-words guard skips polish (and its cost) before ever calling the
backend for near-empty transcripts.

## Testing

Following this project's established convention (pure logic gets Swift
Testing unit tests; hardware/system-API-dependent code is live-verified
instead, matching `AppleEngine`/`ScreenContextReader` precedent):

- **`PolishStyles` catalog + custom CRUD** — pure, fully unit-tested: built-in
  catalog contents, custom add/edit/remove via stable `UUID` identity.
- **Fallback-selection logic** ("what text gets pasted given backend state X
  and polish result Y") and the min-3-words guard — pure decision logic,
  unit-tested independent of any real LLM call.
- **`SystemLLM` backend itself** — not unit-tested (no meaningful way to mock
  Foundation Models, same reasoning as `AppleEngine`). Live-verified: real
  Smart Dictation and Polish Selected Text sessions, confirming actual
  polished output, the Foundation-Models-disabled fallback path, and that the
  timeout doesn't false-trigger on normal calls.
- **Hotkey registration** (Cmd+Shift+B, Cmd+Shift+P) — not unit-tested,
  matching existing `GlobalHotkey`/Cmd+Shift+V precedent (NSEvent global
  monitors aren't testable in the `isRunningUnderTests`-guarded environment).
  Live-verified only.
