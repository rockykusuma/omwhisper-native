# Design: S4 — Reply Assist, Voice-First

> Written 2026-07-08. Brainstormed via `superpowers:brainstorming`. Implements
> "S4 — Reply assist, voice-first" from `docs/SMRITI_INTEGRATION_PLAN.md`,
> next in the project's priority order (M2 → S2 → M3 → S3 → **S4** → S1 → S5 →
> M4 → S6/M5) after S3 sub-project 1 shipped. Ships ahead of S1 (memory
> capture) per that ordering, which shapes two decisions below (tone source,
> no redaction yet).

> **Amendment (2026-07-08, after live verification):** `ReplyAssistPanel` and
> the type-intent/leave-blank/hold-to-speak choice described below were built
> and worked live, but the user changed direction after seeing it in
> practice: double-tap right ⌥ now silently auto-drafts from context and
> streams straight into the field, with no panel and no voice-intent path at
> all — the panel, its UI, and the scoped voice-capture method were removed.
> Canceling a mid-stream draft (still required — see Global Constraints) now
> reuses the same gesture: double-tapping again while a draft is in flight
> cancels it via `ReplyStreamTypist.cancel()`, rather than an Escape key
> handler on a panel that no longer exists. The voice/"hold to speak" path
> from the original goal is dropped for this ship, not deferred to a later
> task — revisit if it turns out to matter. Two more real fixes surfaced only
> via live testing, both still applicable to the current implementation: (1)
> `ScreenContextReader.captureFrontmostWindowText()`'s up-to-50,000-character
> output (fine for S2's local vocabulary extraction) blew SystemLLM's 5s
> polish timeout when embedded raw in a draft prompt — both window context
> and the AX-read draft/selection text are now capped at 2,000 characters
> (the draft case keeps the *tail*, not the head, since continuation cares
> about the most recent text). (2) `ReplyStreamTypist`'s original 20-
> UTF16-unit-per-chunk keystroke bursts (ported from smriti) caused real,
> scattered character corruption typing into Claude's web chat input; chunk
> size dropped to 1 character.

## Goal

Double-tap right ⌥ in any text field to draft a reply, continue an unfinished
draft, or rewrite a selection — either silently from window context, or by
speaking your intent. Drafted text streams into the field live. Off by
default, per this project's standing privacy contract for every
Smriti-derived feature.

## Reference: smriti's implementation

Investigated directly from `/Users/rakeshkusuma/Documents/PersonalProjects/smriti`
(same author, MIT, read-only reference per this project's conventions) —
`AssistListener.swift`, `Redactor.swift`, `ToneProfile.swift`,
`CaptureDaemon.swift`, and their test files:

- **Trigger (`DoubleTapDetector`)** — a pure, dependency-free struct: a
  0.45s window between two right-⌥ presses, `interrupt()` resets the pair on
  any other key (so ⌥-symbol combos like ⌥4→€ never miscount), held
  Cmd/Ctrl/Shift suppresses the trigger (avoid firing mid-shortcut). Ported
  near-verbatim — it's already well-tested and framework-agnostic.
  **Not ported as-is**: smriti drives this via 30ms `CGEventSource` polling
  because "event taps and NSEvent global monitors are unreliable for
  launchd-spawned agents." OmWhisper is a normal app bundle, not a launchd
  daemon, and already has a proven, simpler mechanism —
  `PushToTalkMonitor.swift`'s `NSEvent.addGlobalMonitorForEvents(matching:
  .flagsChanged)` reliably distinguishes modifier press/release today. This
  design reuses that pattern instead, and uses `NSEvent`'s own `keyCode`
  (61 = right ⌥) to distinguish right from left Option, rather than smriti's
  raw `NX_DEVICERALTKEYMASK` device-bit trick — a simpler win from the
  higher-level API this app already relies on.
- **Context/mode detection** — reads `kAXValueAttribute` (draft text),
  `kAXPlaceholderValueAttribute`, `kAXSelectedTextAttribute` on the focused
  element. Real gotcha ported as-is: web/Electron fields return placeholder
  text as the AX *value* when empty — must be stripped before mode
  selection, or the assist "continues" placeholder text into nonsense. Mode:
  `selection.count > 3` → rewrite; else non-empty draft → continue; else →
  reply. Focus resolution has a 3-tier fallback (per-app focused element →
  system-wide element → flip `AXManualAccessibility`/`AXEnhancedUserInterface`
  and retry up to 8×200ms, since Electron trees can take >1s to materialize)
  — ported as-is, this is exactly the kind of hard-won AX behavior worth
  keeping.
- **Streaming (`StreamTypist`)** — synthesized Unicode keydown/keyup events
  in chunks (20 UTF-16 units, `usleep(8_000)` between chunks) rather than
  `AXSelectedText`, because Electron fields "accept it and render nothing."
  Buffers the first 24 characters before typing, checked against failure
  sentinels (`NO_REPLY_CONTEXT`, `Not logged in`, `Please run /login`,
  `Invalid API key`) — the threshold must exceed the longest sentinel so a
  failure is always still buffered when checked. `cancel()` drops pending
  text but keeps whatever's already been typed. Ported near-verbatim; the
  sentinel list adapts to this app's own error strings.
- **`Redactor.swift`** — ordered secret/PII pattern list (JWT, AWS, GitHub,
  Slack, OpenAI/Stripe/Google/Groq/OpenRouter token shapes, Bearer headers,
  email, SSN, Luhn-validated credit cards, separator-only phone numbers,
  catch-all `key=value`), applied to every remote LLM lane. **Not ported for
  this ship** (see Global Constraints) — `PolishBackend` only reaches
  `SystemLLM` (on-device) today; nothing leaves the Mac yet. Revisit when M3
  sub-project 2 adds Ollama/CloudLLM.
- **`ToneProfile.swift`** — builds `tone.md` from 2 weeks of screen-capture
  snapshots across a communication-app allowlist. **Not ported as-is** (see
  Global Constraints) — that capture mechanism is S1's, which ships *after*
  S4 in this project's order. This design sources tone from `HistoryStore`
  instead (this app's own past dictated/polished text, already captured
  since M2) — a better fit besides: it's literally the user's own words, not
  a general screen scrape.

## Architecture

New `ReplyAssist/` group, mirroring `Meetings/`'s structure from S3:

```
ReplyAssist/
├── DoubleTapDetector.swift      # CREATE — pure state machine, ported from smriti
├── ReplyAssistMonitor.swift     # CREATE — NSEvent monitors, mirrors PushToTalkMonitor
├── ReplyContext.swift           # CREATE — AX read + mode classification
├── ReplyStreamTypist.swift      # CREATE — synthesized-keystroke streaming
└── ToneProfile.swift            # CREATE — tone.md distillation from HistoryStore
UI/
└── ReplyAssistPanel.swift       # CREATE — inline "type / blank / hold to speak" UI
```

- **`DoubleTapDetector`** — pure struct: `optionDown(at:)`, `interrupt()`,
  `window: TimeInterval = 0.45`. Unit-testable with synthetic timestamps, no
  AX/CGEvent dependencies — exactly like `MeetingWatcher.nextState` in S3.
- **`ReplyAssistMonitor`** (`@MainActor`, modeled directly on
  `PushToTalkMonitor`) — owns global+local `.flagsChanged` monitors, feeds
  right-⌥ transitions into `DoubleTapDetector`, and on a detected double-tap
  (with no other modifier held) triggers `ReplyAssistPanel`. Suppressed
  whenever `AppState.dictation != .idle`, matching `MeetingWatcher.isSuppressed`.
- **`ReplyContext` / `ReplyContextReader`** — on-demand AX read of the
  focused element (reusing S2's `ScreenContextReader` conventions for the
  same app-exclusion list — password managers, private browsing). Produces
  `enum ReplyMode { case reply, continueDraft(String), rewrite(String) }`
  plus the window's salient context (via `SalientTermExtractor`, already
  built for S2) for the draft prompt.
- **`ReplyAssistPanel`** — small SwiftUI panel, positioned like
  `MeetingConsentPanel` (fixed screen corner, not cursor-relative — getting
  precise caret bounds via AX is its own edge-case-prone problem across
  native/web/Electron fields, not worth taking on for this ship; cursor-
  relative positioning is a nice-to-have, not in scope here): a text field
  for typed intent (leave blank for silent auto-draft) plus a hold-to-speak
  affordance. Holding routes audio through the existing `AudioCapture` →
  `TranscriptionEngine` pipeline, exactly like dictation, just scoped to
  this panel instead of the main overlay.
- **`ReplyStreamTypist`** — ported from smriti per above; ships as its own
  file since `PasteService` is single-shot paste, not streaming, and
  shouldn't grow a second responsibility.
- **`ToneProfile`** — `nonisolated`, reads recent `HistoryStore` entries
  (capped sample, matching smriti's digest-capping approach), asks
  `PolishBackend` to distill a ≤20-line style guide to `tone.md` in the
  app's support directory, refreshed periodically (not on every draft).
  Truncated to a prompt-safe prefix (matching smriti's 1,500-char cap) when
  used in a draft prompt.

**Flow:** double-tap right ⌥ (no other modifier held) → `ReplyContextReader`
classifies the field and reads window context → `ReplyAssistPanel` appears →
user types intent, leaves it blank, or holds to speak (transcribed via the
existing engine) → `PolishBackend.polish(...)` drafts using window context +
intent + `tone.md` prefix → `ReplyStreamTypist` streams the result into the
focused field, sentinel-checked before the first character types, cancelable
via Escape (already-typed text survives cancel; only pending text drops).

## Global Constraints

- Off by default: `AppState.replyAssistEnabled` defaults to `false`.
  `ReplyAssistMonitor` is not instantiated or started unless this is on — no
  flagsChanged monitor runs at all for a user who hasn't opted in.
- `ReplyAssistMonitor` must be suppressed entirely whenever
  `AppState.dictation != .idle` — own dictation must never trigger the
  assist panel, matching `MeetingWatcher`'s suppression contract.
- No redaction in this ship. `PolishBackend.polish(...)` only reaches
  `SystemLLM` (on-device Foundation Models) today — there is no remote lane
  to protect. `Redactor` is deferred to M3 sub-project 2, when Ollama/Cloud
  backends actually create one.
- `tone.md` is sourced from `HistoryStore`, not screen captures — S1's
  capture mechanism doesn't exist yet at this point in the build order.
- Escape cancels a pending draft/stream at any point; already-typed
  characters are never rolled back, only pending text is dropped.
- Sentinel-checked streaming: the first ~24 characters are buffered and
  checked against known failure strings before any character is typed, so a
  backend error never gets typed into the user's field as garbage text.
- Real, SDK/reference-verified API surface only — the AX fallback chain,
  placeholder-vs-value gotcha, and streaming-via-synthesized-keystrokes
  approach above are taken directly from smriti's tested implementation, not
  guessed.

## Error Handling & Permissions

- AX focus resolution failing after all fallbacks → panel shows "can't read
  this field," no draft attempted.
- `PolishBackend` failure (backend disabled, model error, timeout) → panel
  shows an inline error, nothing is typed — mirrors M3's "never silently
  drop the user's input" principle, applied in reverse (never silently
  insert bad output either).
- Sentinel match in the buffered prefix → treated the same as a backend
  failure: inline error, zero characters typed.
- No new permission beyond what's already granted: Accessibility (already
  required for `PasteService`/`PushToTalkMonitor`) covers both the AX reads
  and the synthesized keystrokes here.

## Testing

Pure-logic unit tests (Swift Testing, matching S3's `MeetingWatcherLogicTests`
style):
- `DoubleTapDetector`: double-tap within window fires, gap beyond window
  doesn't, `interrupt()` resets a pending tap, triple-tap fires once then
  cleanly restarts a new pair, held Cmd/Ctrl/Shift suppresses.
- Mode classification: empty → reply, non-empty no-selection → continue,
  selection > 3 chars → rewrite, placeholder-as-value stripped before
  classification.
- `ReplyStreamTypist` sentinel matching: buffered prefix containing a known
  failure string → zero characters typed; cancel after partial typing keeps
  typed text, drops only pending.
- `ToneProfile` digest capping/truncation math (sample cap, prompt-prefix
  truncation length).

AX-dependent behavior (real focus resolution, real synthesized typing into
third-party apps) and live voice capture aren't unit-testable — covered by
live verification, same as S2/S3: real double-tap in a real text field
across a few representative apps (a native field, a web field, an Electron
app like Slack), real hold-to-speak draft, real cancel-mid-stream.

**Exit criteria** (from `docs/SMRITI_INTEGRATION_PLAN.md`): sub-2s to first
streamed token on SystemLLM; feature fully inert with the setting off.
