# F5 — Brain-dump mode — Design

**Date:** 2026-07-12
**Phase:** F (Frontier features), wave 2.1
**Plan ref:** `docs/FRONTIER_FEATURES_PLAN.md` §F5
**Status:** Approved, ready for implementation plan

## Problem

Dictation today is sentence-to-text. Brain-dump mode is talk-messily-for-minutes →
out comes a structured artifact (email / ticket / outline / to-do / agenda / journal),
shaped by the target you pick and grounded in on-screen context. Competitors ship
static "modes"; ours are grounded in S2 screen context and reuse the app's own
polish backends.

## Decisions (brainstorming 2026-07-12)

- **Shape picked up front** (a default setting + a mini-panel dropdown) — NOT
  inferred from the frontmost app. App-inference is F6's job; keeping it out avoids
  scope overlap.
- **Paste directly** on stop (like dictation) + save to history — NOT a
  review/re-shape window. Leanest v1; the app's model is dictate→paste, and the
  fallback rule means the raw words are never lost.
- **Local-first**: structuring runs through `activePolishBackend()` (SystemLLM by
  default), same as all polish. Off unless a backend is enabled — with backend
  Disabled/unavailable, a brain-dump pastes the raw ramble.

## Design

### 1. Trigger & shape selection

- **Hotkey ⌘⇧D** (kVK_ANSI_D = 2; V/B/P already used) — a new `GlobalHotkey`
  in `AppState`, started alongside the others, calling `beginBrainDump()`.
  Toggle-style like ⌘⇧V/⌘⇧B (press to start, press to stop).
- **Mini-panel row** — a "Brain-dump" entry with a shape dropdown + start action,
  so the feature is discoverable without the hotkey. Uses the active shape.
- **6 built-in shapes** in `Polish/BrainDumpShapes.swift`, each a fixed-UUID
  `PolishStyle` (reusing the struct — a shape *is* a named structuring prompt):
  Email, Ticket (summary / steps to reproduce / expected), Outline, To-do list,
  Meeting agenda, Journal. Prompts instruct: take a rambling spoken transcript and
  produce ONLY the structured artifact, no preamble.
- **Custom shapes**: same CRUD as custom polish styles, stored separately —
  `AppState.brainDumpShapes` (`[PolishStyle]`, UserDefaults JSON, like
  `customPolishStyles`) + `activeBrainDumpShapeID`. Kept out of the polish-style
  picker so the two concepts don't muddy each other.

### 2. Capture & the relaxed overlay

- **Session mode**: replace `AppState.isSmartDictationSession: Bool` with
  `private var sessionMode: SessionMode` (`.normal` / `.smart` / `.brainDump`).
  `toggleOrStop(smart:)` becomes `toggleOrStop(mode:)`; `beginSmartDictation()` and
  the new `beginBrainDump()` pass their mode. Capture is the identical pipeline —
  the mode only changes what `stopDictation` does with the text and what the
  overlay renders.
- **Relaxed overlay**: while `sessionMode == .brainDump`, the overlay swaps its
  2-line transcript for **"N words · M:SS"** — word count of the accumulated
  transcript + elapsed since `recordingStartedAt`, driven by a `TimelineView`
  periodic clock (no per-frame observation needed). The orb / warming / finalize
  states are unchanged. Per the plan: "you're not supposed to watch it."

### 3. Structuring — map-reduce (`Polish/BrainDumpStructurer.swift`)

Mirrors `MeetingSummarizer`/`Chronicler` exactly, for the same reason: a
multi-minute ramble far exceeds SystemLLM's ~2000-char/5s envelope, so every LLM
call must stay in-budget.

```
static func structure(transcript:, shape: PolishStyle, context: String?,
                      polish: PolishBackend) async throws -> String
```

- `chunk(_:limit:)` — word-pack the transcript into ≤1800-char groups (pure,
  tested; same helper shape as `MeetingSummarizer.chunk`).
- **One chunk** (short ramble) → skip the map; run the shape prompt directly on the
  raw transcript.
- **Multiple chunks** → **map**: each chunk → concise notes via a fixed-UUID
  `chunkNotesStyle` ("extract the key points and content as terse notes"). **Reduce**:
  the joined notes (capped ~1800) → the target shape via `shape.prompt`, with
  `context` appended.
- **Context**: `context` = frontmost app name + S2 salient screen terms
  (`ScreenContextReader` / `SalientTermExtractor`, already captured at dictation
  start via `startContextCapture`). Appended to the reduce prompt so the output uses
  the right names/tickets.

### 4. Output & fallback (`AppState.stopDictation`)

The existing smart-dictation branch generalizes:

```
if phase == .pasting {
    switch sessionMode {
    case .smart where !tooShortForPolish(text): text = await polishedText(for: text)
    case .brainDump:                              text = await brainDumpStructured(for: text)
    default: break
    }
}
```

- `brainDumpStructured(for:)` resolves the active shape + `activePolishBackend()`
  and calls `BrainDumpStructurer.structure`. **Any** failure (no backend, timeout,
  empty result) returns the raw ramble — words are never dropped, matching
  `polishedText`'s fallback rule. Overlay shows the existing `.polishing` phase
  while it runs (labelled generically; no new color, per OVERLAY_SPEC §2).
- Then the normal `phase == .pasting` paste + history path runs unchanged (paste
  directly into the frontmost app, record to history).

### 5. Settings (`UI/AISettingsView.swift`)

A "Brain-dump" subsection: the active-shape picker + shape CRUD, reusing the
existing custom-polish-style editor UI (add / edit / delete a name + prompt).

## Out of scope (YAGNI)

- Shape auto-inference from the frontmost app (F6).
- Review / re-shape UI before paste.
- Per-app profiles / templates (F6).
- A dedicated brain-dump overlay *style* — the relaxed content reuses the current
  overlay chrome.

## Files

| File | Change |
|---|---|
| `Polish/BrainDumpShapes.swift` | New — 6 built-in shape `PolishStyle`s + the hidden chunk-notes style |
| `Polish/BrainDumpStructurer.swift` | New — `chunk` + `structure` map-reduce (pure `chunk` tested) |
| `AppState.swift` | `SessionMode` enum (replaces `isSmartDictationSession`); `beginBrainDump()`; ⌘⇧D hotkey; `brainDumpShapes`/`activeBrainDumpShapeID` settings; `brainDumpStructured(for:)`; structuring hook in `stopDictation` |
| `UI/OverlayView.swift` | Word-count + elapsed content when `sessionMode == .brainDump` |
| `UI/AISettingsView.swift` | Brain-dump shapes subsection (active picker + CRUD) |
| `UI/MiniPanelView.swift` | Brain-dump row (shape dropdown + start) |

## Testing

- `BrainDumpStructurer.chunk` — pure, directly tested (word-packing, oversize-line
  handling), mirroring `MeetingSummarizerTests`.
- `SessionMode` routing in `stopDictation` — the map-reduce/effectful paths and
  SwiftUI overlay/settings are verified live per project convention.
- Live (exit criterion): a 5-minute ramble → usable ticket/email without edits in
  ≥7/10 attempts; zero-edit normal dictation pays no added latency; backend-off
  brain-dump pastes the raw ramble.
