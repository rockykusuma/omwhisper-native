# Smriti → OmWhisper Native Integration Plan

> Decided 2026-07-07. Bring Smriti's features into omwhisper-native by **copying or
> rewriting code here** — the `smriti` repo stays untouched (read-only reference,
> same author, MIT). Sequencing: **finish M2 parity first**, then this plan.
> Website stays **OmWhisper-centric**; Smriti-derived features ship as OmWhisper 2.x
> capabilities.

---

## Product Thesis

OmWhisper's identity stays "free, private voice-to-text." Smriti's capabilities turn it
into a **context-aware** dictation app:

1. **Screen-context dictation** — the app knows what's on your screen and biases
   transcription toward those terms. No competitor has this.
2. **Meeting intelligence** — consent-first call recording, transcribed by OmWhisper's
   own engines, summarized by the polish backends.
3. **Voice reply assist** — double-tap, speak your intent, get a context-aware polished
   reply typed into the field.
4. **Personal memory** — searchable screen history, daily chronicles, and an MCP server
   exposing it to Claude Desktop.

**Privacy contract is non-negotiable**: every Smriti-derived feature is **off by
default**. A dictation user who never opens Settings → Memory never has their screen
read. Exclusions-first, consent-first meetings, redaction on all remote egress.

---

## Constraints

- **Swift 6 / MainActor-default / macOS 26** here vs. Smriti's Swift 5.9 / macOS 13.
  Every copied file needs a concurrency pass: capture timers, CGEventTaps, audio taps,
  and SQLite access must be explicitly `nonisolated` + locked (see CLAUDE.md
  "Concurrency"). Nothing is drop-in.
- **Don't duplicate what omwhisper-native already has or has planned**: transcription
  engines (`TranscriptionEngine`), polish backends (M3 `PolishBackend`: SystemLLM /
  Ollama / CloudLLM), Keychain key storage (M3), GRDB history DB (M2), CGEventTap
  monitoring (`PushToTalkMonitor`), paste (`PasteService`), menu bar (`NSStatusItem`).
  Smriti's `OllamaClient`, `CloudLLM`, `ClaudeCLI`, `Transcriber`, and its UI chrome are
  **not ported** — their roles are filled by existing/planned OmWhisper components.
- **One database.** Snapshots (FTS5), meetings, chronicles, and tone live in the same
  GRDB SQLite as transcription history (M2). One file to inspect, one file to delete.
- Attribution: code copied from `github.com/rockykusuma/smriti` (MIT, same author) —
  note origin in file headers where copied substantially.

## Port Map

| Smriti component (SmritiKit/) | Disposition | Notes |
|---|---|---|
| `AXReader.swift`, `BrowserURL.swift` | **Copy + concurrency pass** | Core value. AX tree → window text; AXWebArea → URL for domain exclusions. |
| `Redactor.swift` | **Copy nearly verbatim** | Pure logic (keys/JWTs/cards/SSNs/emails → `[REDACTED_…]`). Unit tests port too. |
| `Store.swift` (snapshots, FTS5, dedup, retention) | **Rewrite on GRDB** | Smriti uses raw system SQLite; we standardize on GRDB (M2). Keep the schema ideas: dedup by (app, title, content-hash), `last_seen_at` bump, retention prune, chronicles kept. |
| `CaptureDaemon.swift` | **Rewrite** | 5s timer + prune; becomes a `MemoryCapture` service owned by AppState, gated by the Memory feature flag, pause via menu bar. |
| `Config.swift` exclusions (apps/domains/title keywords) | **Rewrite into AppState settings** | No second config file — UserDefaults like everything else. Password managers excluded by default. |
| `MeetingWatcher`, `MeetingRecorder`, `MicCheck` | **Copy + adapt** | Mic-open detection → 10s consent panel → record mic + system audio as separate tracks. |
| `MeetingTranscription.swift` | **Replace** | Use `TranscriptionEngine` (Apple/Parakeet/Cloud) instead of Smriti's plain SFSpeech path. Better accuracy, engine choice for free. |
| `MeetingSummary`, `ActionItems`, `Chronicler` | **Rewrite onto `PolishBackend`** | Smriti shells out to `claude -p`; we use M3 backends (SystemLLM default — fully local summaries, an upgrade over Smriti). |
| `AssistListener.swift` (double-tap right ⌥) | **Rewrite** | Follow `PushToTalkMonitor` patterns; add the voice variant (tap → dictate intent → context-aware reply). |
| `DraftHUD`, `ToastPanel` | **Rebuild in OmWhisper UI** | We already have `OverlayPanel` (non-activating NSPanel); extend it rather than porting a second panel stack. |
| `ToneProfile.swift` | **Copy + adapt** | tone.md distillation via `PolishBackend` instead of `claude -p`. |
| `MCPServer.swift` (stdio JSON-RPC, 5 tools) | **Copy + adapt** | Expose OmWhisper memory to Claude Desktop: `search_memory`, `get_recent_activity`, `get_snapshot`, `get_chronicle`, `list_chronicles` (+ `search_transcriptions`). Launched via `OmWhisper.app/Contents/MacOS/omwhisper --mcp` or a bundled helper. |
| UI sections (`MainWindow`, `HomeSection`, `TodaySection`, `SearchSection`, `MeetingsSection`, `MemoryChat`, …) | **Rebuild** | OmWhisper look & feel; Smriti files are wireframe reference only. |
| `OllamaClient`, `CloudLLM`, `ClaudeCLI`, `WarmClaude`, `Transcriber`, `VoiceNoteRecorder`, `LaunchAgent`, theme/onboarding | **Skip** | Superseded by M2/M3 equivalents. |

## Milestones (Phase S — starts after M2 ships)

Existing M0–M5 keep their numbers. Phase S interleaves: S1 can start right after M2;
S3 requires M3 (polish backends); M5 (release) gates on whichever S-milestones are in
the 2.x launch scope.

### S1 — Memory core (foundation, no UI beyond a toggle)
`AXReader` + `BrowserURL` + `Redactor` ports; `MemoryCapture` daemon (timer, dedup,
prune); snapshots + FTS5 tables in the GRDB db; exclusions (apps, domains + subdomains,
title keywords; password managers default-excluded); retention setting; pause from menu
bar; **Memory master toggle in Settings, default OFF**.
*Exit*: capture runs for a day without measurable battery/CPU complaint; excluded apps
provably never hit the DB; FTS search works from a debug command.

### S2 — Context-aware dictation ⭐ (the differentiator)
On dictation start, read the frontmost window's text (one AX walk — or the seconds-old
snapshot if capture is on), extract salient terms (proper nouns, code identifiers,
rare words), merge with user vocabulary → `AnalysisContext.contextualStrings` /
engine keyterms. Works **without** S1 capture enabled (single on-demand read, nothing
stored) — a lighter permission story.
*Exit*: measurable WER improvement dictating names/jargon visible on screen; strengthens
sign-off criterion #4.

### S3 — Meeting intelligence (needs M3)
`MeetingWatcher` mic-open detection → 10s consent panel (nothing recorded on timeout);
mic + system-audio recording; transcription via `TranscriptionEngine`; summary +
action items via `PolishBackend` (SystemLLM default = fully local); Meetings UI;
searchable, part of history. Audio stays in app support dir.
*Exit*: record a real Meet/Zoom call end-to-end; summary quality acceptable on SystemLLM.

### S4 — Reply assist, voice-first (needs M3; ships before S1)
Double-tap right ⌥ in any text field: empty field → drafted reply, unfinished draft →
continuation, selection → rewrite. **Voice variant**: tap, speak intent, engine
transcribes, polish backend drafts using window context. Ships **window-context-only**
(on-demand AX read + `Redactor`, nothing stored); memory-snippet enrichment turns on
automatically when S1 lands. Tone learning (`tone.md`) ships here — the chosen scope
of "getting to know the user". Redaction on every remote lane; per-app cloud
opt-out. Streams into the field via `PasteService`-style events.
*Exit*: sub-2s to first streamed token on SystemLLM; redaction verified on egress.

### S5 — Memory surfacing + MCP
Search/Today/timeline UI; daily chronicles (via `PolishBackend`, scheduled); memory
chat; MCP server so Claude Desktop can query it. This is the full "Smriti inside
OmWhisper" experience.
*Exit*: "what was I working on before lunch?" answerable from Claude Desktop.

### S6 — Website update (omWhisperWebApp)
OmWhisper-centric single-product page, updated for 2.0: macOS 26 requirement
(macOS only — no Windows build), and new feature sections as they ship — context-aware dictation (S2) first, then meetings (S3), reply assist (S4),
memory + MCP (S5). Privacy page updated for the new permission surfaces (Accessibility
capture, Input Monitoring, mic/system audio) with the same "off by default, local by
default" story. Can start copy/design after S2 demos.

## Priorities (R, 2026-07-07)

1. Voice-to-text + **screen-context dictation** (S2) — the headline; no competitor has it.
2. **Meeting intelligence** (S3) — consent-first recording, transcript sorted/summarized/stored.
3. **Screen-context reply** on right-⌥ double-tap (S4).
4. **Local Mac memory** (S1 + S5) — and learning the user over time. Within Phase S the
   scope is **writing tone only** (`tone.md`, ships with S4). Auto-vocabulary learning,
   personal knowledge profile, and habit-aware assistance are deferred **into Phase 3
   (Digital Twin, below)** — decided 2026-07-07.

## Order

**M2 → S2 → M3 → S3 → S4 → S1 → S5 → M4 → S6/M5** (confirmed: M2 finishes first)

Rationale: S2 is the highest value-to-effort feature and needs only an on-demand AX
read (a small slice of S1) — pull it forward as the 2.0 headline. S3 rides M3 and fits
the dictation identity. **S4 precedes S1** per the priority ranking — it must therefore
ship in window-context-only mode (AX read of the conversation on screen + tone.md, no
stored-memory snippets); the "up to 3 related memory snippets" enrichment activates
automatically once S1 lands. S1's always-on capture is the biggest trust ask, so it
comes once the app has earned it, unlocking S5. M4 (cloud/Parakeet engines) benefits
S3 retroactively.

## Phase 3 — Digital Twin (after S5; decided 2026-07-07)

> Goal: OmWhisper knows the user better day by day. Honest framing: a twin that
> **writes like you and knows what you know** — tone + facts + vocabulary + patterns.
> It does NOT clone judgment or taste on novel questions; we never market it as "you."
> Everything local, inspectable, deletable, off by default. Requires S1 capture on.

### T1 — Profile distillation (the learning loop)
Nightly local job (SystemLLM/Ollama — same lane as chronicles) reads the day's
snapshots, dictations, and meetings and updates a structured profile:
- **Facts store** (GRDB): projects, people + relationships, tools, recurring topics,
  preferences/decisions — each fact carries `confidence`, `first_seen`, `last_confirmed`,
  `source` (snapshot/meeting/dictation id). Re-confirmation raises confidence; facts not
  seen for N weeks decay and eventually expire. This is what makes it *day-by-day better*
  rather than a static dossier.
- **`profile.md`** — human-readable rendering the user can open, edit (edits are pinned,
  never overwritten), or delete. Complements `tone.md` (S4).

### T2 — Twin-grounded assistance
Reply assist, polish, and memory chat retrieve from profile + FTS memory before
drafting: replies reference the right project names and shared history; "answer as me"
mode in memory chat. Redaction still applies on any remote lane; profile snippets count
toward the same egress rules as memory snippets.

### T3 — Auto-vocabulary learning (revived from deferred list)
When the user corrects a transcription (edit-before-paste diff, or history edits),
the corrected terms feed the vocabulary store automatically → `contextualStrings`
biasing. The twin literally hears better as it learns your lexicon.

### T4 — Habit layer (revived from deferred list; last, most speculative)
Patterns from the facts store drive proactive nudges: recurring meeting starting →
offer to record; you always summarize after standup → offer it. Strictly
notification-level suggestions, never autonomous actions.

**Sequencing**: Phase 3 starts after S5 (needs capture + surfacing). T1 → T2 → T3 → T4,
each independently shippable. Website (S6) gets a "learns you, locally" section only
once T1/T2 are real.

**Phase-3-specific risks**: profile accuracy (hallucinated facts → wrong replies:
mitigate with source-linked facts + confidence threshold before use); creepiness
(mitigate: profile.md is always one click away, and deleting it is honored
immediately); the twin overfitting to work-mode tone (mitigate: per-context tone
sections in tone.md).

## Risks

- **Scope** — this roughly doubles the app. Mitigation: strict milestone gates, M2
  first, each S-milestone independently shippable and feature-flagged.
- **Permission fatigue** — Accessibility (already needed for paste), Input Monitoring
  (S4), mic + system audio (S3). Mitigation: request lazily, per-feature, at first use;
  never at onboarding.
- **Swift 6 migration of copied code** — AX walks and SQLite access off MainActor.
  Mitigation: follow the `nonisolated` + `OSAllocatedUnfairLock` patterns already
  proven in `AudioCapture`.
- **Battery/CPU of the capture timer** — 5s AX walks are cheap but not free.
  Mitigation: Smriti's dedup design (idle window = one row) + skip walk when frontmost
  app unchanged and content hash stable.
- **App identity drift** — dictation app that reads your screen. Mitigation: default-off,
  S2's storage-free mode as the introduction, honest privacy page (S6).
