# Whisper Engine — Design

**Date:** 2026-07-11
**Status:** Approved (design), pending implementation plan
**Milestone context:** Reverses the documented "Whisper/Moonshine engines" scope-drop
(CLAUDE.md → "Explicitly Dropped vs. the Tauri App"). Justified by the one motivation
the three existing engines can't cover: **broad language coverage** (99 languages incl.
strong Indic — Telugu/Hindi — where Apple SpeechTranscriber and Parakeet v3 are weak).
Overlaps the planned **F4 cross-lingual dictation** but does not implement it.

---

## Goal

Add a fourth, opt-in on-device transcription engine — **Whisper via WhisperKit** — with a
user-selectable model (speed↔accuracy) and language, so a user who dictates in a language
the other engines handle poorly can pick "which model is perfect for him."

## Non-Goals (v1, YAGNI)

- **Live partials.** Whisper is chunk-based; it transcribes on key-release in one pass. Live
  word-streaming is what Apple/Parakeet already do well — not duplicated here.
- **Translate-to-English** (`task: .translate`). A real WhisperKit capability and an obvious
  future toggle, but it overlaps F4 and the existing polish-layer translate style; documented
  as a follow-up, not built now.
- **Extra model tiers** (tiny / medium / large-v3 / distil). Only `base` / `small` /
  `large-v3-turbo` ship. `medium` is dominated by turbo; `tiny` is rarely worth it.
- **No WER benchmark.** The cross-engine WER comparison remains the separately-owed M4 item.

## Success Criteria

1. Selecting Whisper + a downloaded model + speaking, then releasing the hotkey, pastes an
   accurate transcript.
2. A language pinned in Settings (e.g. Telugu) is honored; "Auto-detect" (default) also works.
3. Custom vocabulary biases the result (sign-off #4 holds for this engine too).
4. Apple stays the default engine; existing Apple/Parakeet/Cloud behavior is unchanged.
5. All pure helpers unit-tested; WhisperKit stays app-target-only (no test-target link),
   matching FluidAudio.

---

## Architecture

One new `TranscriptionEngine` conformer, `WhisperEngine`, added exactly like Parakeet was
(M4.1) and Cloud (M4.2): a new `EngineKind` case, a settings section, an `activeEngine`
branch. Whisper is **transcribe-on-release**: the engine accumulates the whole mic
`AsyncStream` into 16 kHz-mono-Float samples, and when the stream ends runs a single
`WhisperKit.transcribe(...)` pass, emitting exactly one `.final` event. It never emits
`.partial`. This is the simplest possible fit for the streaming `TranscriptionEngine`
protocol and gives Whisper its full-utterance context (best accuracy — the whole point).

**Dependency:** WhisperKit (`github.com/argmaxinc/WhisperKit`), added as an SPM package via
hand-edited `project.pbxproj` (`XCRemoteSwiftPackageReference` + `XCSwiftPackageProductDependency`),
**app target only** — the identical pattern used for FluidAudio and Sparkle. Exact version
tag and the model-identifier strings it resolves are **verified against the real pinned
release during planning**, not from memory (the M4.1 lesson: unverified dependency research
produces real build failures).

---

## Components

### `Transcription/TranscriptionEngine.swift` (modify)

Add `case whisper` to `EngineKind` (already `String, CaseIterable, Codable, Sendable`).

### `Transcription/WhisperEngine.swift` (new)

Holds three things:

**`WhisperModel`** — a pure enum (no WhisperKit types, so it backs a UserDefaults setting and
is unit-testable with WhisperKit app-only, exactly like `ParakeetModel`):

```
nonisolated enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case base, small, largeV3Turbo   // largeV3Turbo is the default
    var id: String
    var displayName: String          // "Base", "Small", "Large v3 Turbo"
    var subtitle: String             // size + speed/accuracy hint
}
```

The `WhisperModel → WhisperKit model-id` mapping is a **private function inside the engine**
(the FluidAudio-free enum never names a WhisperKit type), so `WhisperModel` stays test-linkable.

**`WhisperEngine: TranscriptionEngine`** — a `nonisolated final class` (not a struct: loading
a Whisper CoreML pipeline is multi-second and must be cached, same reasoning as `ParakeetEngine`).
Lock-guarded state (`OSAllocatedUnfairLock`, matching `AudioCapture`/`ParakeetEngine`):

```
private struct State {
    var pipe: WhisperKit?              // loaded pipeline
    var loadedModel: WhisperModel?     // which model `pipe` holds (nil = none)
    var requestedModel: WhisperModel = .largeV3Turbo
    var requestedLanguage: String = "auto"   // language code, or "auto" for detect
}
```

- `setModel(_:)` / `setLanguage(_:)` — record the user's choice (called by AppState).
  Changing the **model** invalidates the cache on next load; changing the **language** does
  **not** (language is a per-call decode option, no pipeline reload).
- `isReady` — `pipe != nil && loadedModel == requestedModel`. Keys off the model only, so
  Settings shows the right download state after a model switch.
- `ensureModelLoaded(progressHandler:)` — loads the requested model's pipeline via WhisperKit's
  own download-with-progress API if not already loaded for that model; caches it. Called from
  Settings' Download button. **Not** called lazily inside `transcribe()` — a `large-v3-turbo`
  download is ~1.6 GB and must never block a live dictation session; see error handling.
- `transcribe(_ audio:vocabulary:)` (nonisolated, per protocol): if `!isReady`, finish the
  stream throwing `EngineError.modelNotDownloaded` (surfaces in the overlay). Otherwise:
  convert each buffer to 16 kHz mono Float32 via the existing `BufferConverter`, accumulate;
  on stream-end call `pipe.transcribe(audioArray:decodeOptions:)` with:
  - `language` = requestedLanguage, mapped `"auto" → nil` (a pure helper).
  - the initial **prompt** built from `vocabulary` (see below) → tokenized via the pipeline's
    tokenizer → `DecodingOptions.promptTokens`.
  Emit the result text as a single `.final`, then finish. On any throw, finish throwing.

**Pure helpers (directly unit-tested):**
- `whisperKitModelID(for:) -> String` — model→id map.
- `decodeLanguage(_:) -> String?` — `"auto" → nil`, else the code.
- `vocabularyPrompt(_ terms:) -> String` — joins custom terms into a single context/glossary
  prompt string (empty terms → empty prompt → no promptTokens). Tokenization itself is a
  WhisperKit call and isn't unit-tested; the *string* it's given is.

### `AppState.swift` (modify)

- `EngineKind` already covered; `activeEngine` gains `case .whisper: whisperEngine`.
- `let whisperEngine = WhisperEngine()` collaborator.
- `whisperModel: WhisperModel` setting — UserDefaults-backed, `access/withMutation` (so the
  radio picker re-highlights), setter also calls `whisperEngine.setModel(newValue)`.
- `whisperLanguage: String` setting — UserDefaults-backed, `access/withMutation`, default
  `"auto"`, setter calls `whisperEngine.setLanguage(newValue)`.
- `init()` (non-test path): `whisperEngine.setModel(whisperModel)` +
  `whisperEngine.setLanguage(whisperLanguage)` so the engine honors persisted choices.
- `SettingsKeys`: add `whisperModel`, `whisperLanguage`.

### `UI/TranscriptionSettingsView.swift` (modify)

Add a `state.engineKind == .whisper` section, mirroring the Parakeet section that already
exists:
- **Model** radio picker (`WhisperModel.allCases`, bound to `$state.whisperModel`) + subtitle.
- **Language** picker bound to `$state.whisperLanguage`: an "Auto-detect" row (`"auto"`) plus
  WhisperKit's own language list (name → code), sorted. Always visible (language is a decode
  option, independent of download).
- **Download** button / progress / "Ready." state (per selected model), reusing the exact
  `downloadProgress`/`downloadError`/`isReady` local-`@State` pattern the Parakeet section uses,
  with an `.onChange(of: state.whisperModel)` re-reading readiness and clearing progress —
  identical to the Parakeet picker's just-shipped behavior.

---

## Data Flow

```
hotkey/PTT → AudioCapture (mic buffers) ──AsyncStream──▶ WhisperEngine.transcribe(audio, vocabulary)
                                                              │  (accumulate → 16k mono Float32)
                                          key release → stream ends
                                                              ▼
                                    WhisperKit.transcribe(samples, {language, promptTokens})
                                                              ▼
                                              one .final(text) ──▶ AppState → overlay → paste
```

## Error Handling

- **Model not downloaded** → `transcribe` finishes throwing `EngineError.modelNotDownloaded`
  ("Download the Whisper model in Settings."). Surfaces via the existing overlay error path
  (error capsule / Full-style label), same as Parakeet's `modelsNotLoaded`.
- **Download failure** (Settings) → surfaced in the section's `downloadError` line, same as
  Parakeet.
- **Transcription throw** → stream finishes throwing; AppState's existing engine-error handling
  shows the overlay error. No raw-text fallback exists for engines (that's the polish layer);
  a failed transcription simply surfaces as an error, matching Apple/Parakeet/Cloud.

## Testing

New `omwhisper-nativeTests/WhisperEngineTests.swift`, pure helpers only (no WhisperKit import,
matching `ParakeetEngineTests`):
- `WhisperModel` rawValue round-trip + `allCases` (persistence contract).
- `whisperKitModelID(for:)` maps each case to its expected id.
- `decodeLanguage("auto") == nil`, `decodeLanguage("te") == "te"`.
- `vocabularyPrompt([]) == ""`, and a non-empty list produces the expected prompt string.

## Prerequisite / Risk

- **`project.pbxproj` has uncommitted cosmetic changes** that must not be clobbered. Adding the
  WhisperKit SPM entries requires editing this file. Resolve before the dependency task:
  commit/stash the cosmetic changes first, or add only the SPM entries alongside them and
  verify the resulting diff. **Blocks the dependency task, not the design.**
- **WhisperKit API / model-id verification** happens at plan-writing time against the real
  pinned tag (exact `WhisperKitConfig`/`transcribe`/`DecodingOptions`/download-progress API and
  the `openai_whisper-*` model strings). The M4.1 precedent: read what the versioned dependency
  actually resolves to, not the default branch.
- **Model download size** (turbo ~1.6 GB) is why `transcribe` never auto-downloads; download is
  an explicit Settings action only.

## File Summary

| File | Change |
|------|--------|
| `Transcription/TranscriptionEngine.swift` | `EngineKind += .whisper` |
| `Transcription/WhisperEngine.swift` | **new** — `WhisperModel` enum + `WhisperEngine` + pure helpers |
| `AppState.swift` | `whisperEngine` collaborator, `whisperModel`/`whisperLanguage` settings, `activeEngine` branch, init sync, SettingsKeys |
| `UI/TranscriptionSettingsView.swift` | Whisper section (model + language + download) |
| `omwhisper-native.xcodeproj/project.pbxproj` | WhisperKit SPM dependency (app target) — see prerequisite |
| `omwhisper-nativeTests/WhisperEngineTests.swift` | **new** — pure-helper tests |
