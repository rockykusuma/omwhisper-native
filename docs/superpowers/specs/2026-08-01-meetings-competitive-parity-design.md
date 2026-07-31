# Meetings Competitive Parity — Design

**Date:** 2026-08-01
**Status:** Approved (brainstorming), pending implementation plans
**Area:** S3 Meetings. Goal: on par or better than Meetily (meetily.ai) and Littlebird (littlebird.ai) on the dimensions the user chose, without giving up the on-device rule.

## Competitive context (researched 2026-08-01, live sites/docs/reviews)

**Where OmWhisper is already ahead:**
- Consent-first auto-detection (Littlebird has no participant-consent flow at all; Meetily Community is manual start/stop — auto-detect is Pro-only and undocumented).
- Dual-track You/Others capture (Littlebird appears system-audio-only; "computer's audio" is their own phrasing).
- Free on-device diarization (Meetily paywalls diarization in Pro; Littlebird doesn't have speaker ID at all — an observed absence flagged by reviewers).
- Cross-meeting FTS search (Meetily has no cross-meeting search — only Pro-gated search-and-replace within one meeting).
- MCP server (Littlebird gates MCP behind its $50/mo tier).
- Native, light, no subscription. Littlebird is cloud-by-design (founders on HN: a fully-local version is impossible for them); its dominant criticism is exactly that.

**Real gaps this design closes:**
- Meetings are titled "zoom.us", not "Q3 Planning"; no participant names; speakers stuck as "Speaker 1/2" (Meetily's rename flow is best-in-class; Littlebird's detection/prep is calendar-driven).
- Summary is read-only (both competitors editable); no templates (Meetily: 6 built-ins + custom markdown templates); SystemLLM's ~2,000-char map-reduce degrades on long calls (the same weakness reviewers flag in Meetily's local mode).
- No export (Meetily: md/docx/pdf, Pro-gated; Littlebird: none — parity chance), no ask-questions-about-meetings (Littlebird's marquee feature), meetings absent from our MCP server, no follow-up drafts.

## Decisions (brainstorming, 2026-08-01)

1. **On-device-only stays.** Recorded meetings never egress — the standing S3 rule is the differentiator, not a constraint to relax. Cloud backends stay excluded from the meeting pipeline entirely.
2. **Priorities** (user-chosen): meeting context & identity, post-meeting intelligence, notes quality & structure. **Live in-meeting transcript explicitly not chosen** — out of scope.
3. **"On-device" ≠ "SystemLLM-only":** Ollama is local with zero egress and is allowed as a meeting-summary backend when it's the user's selected polish backend.
4. **Titles/participants source = calendar (EventKit) + AX window-title fallback.** Calendar matching is opt-in (new permission prompt only when enabled).
5. **Meeting Q&A = MCP tools + in-app single-shot ask.** No in-app multi-turn chat (same reasoning that descoped Memory Chat in S5.2: no local multi-turn tool-calling backend worth shipping).
6. **Three sub-projects, priority order:** SP1 Identity → SP2 Notes → SP3 Intelligence. Each independently shippable, its own implementation plan (established S3-1/2, M3-2a/2b, D2a/b pattern).

## Out of scope (YAGNI)

Live in-meeting transcript/notes (not chosen; biggest-cost item). Littlebird-style prep briefs, routines, menu-bar meeting calendar (future — SP1's EventKit plumbing is the prerequisite; noted as follow-on, not designed here). Retranscribe-with-engine-picker (the diarized pipeline needs Whisper timestamps regardless). DOCX/PDF export. Voice-sample playback in the rename flow (v2 if plain renaming proves insufficient). Speaker voice enrollment / real voice ID (F3). Mail.app integration for follow-ups (clipboard + review sheet only).

---

## 1. Data model (shared foundation, lands in SP1)

New GRDB migration on `meetings.db` adding three nullable columns to `meetings`:

- `title TEXT` — display title; null → UI falls back to `appName` (today's behavior; existing rows unaffected).
- `attendees TEXT` — JSON array of names from the matched calendar event.
- `speakerNames TEXT` — JSON dict mapping raw transcript labels → user-given names, e.g. `{"Speaker 1": "Alice"}`.

`title` joins `meetings_fts`. An FTS5 table built with `synchronize(withTable:)` can't be altered in place — the migration drops and recreates `meetings_fts` with the new column set; content is repopulated from the base table.

**Stored transcript stays immutable with generic labels.** Names are applied at read time by one pure helper — `resolvedTranscript(transcript:speakerNames:)` — used by the detail view, copy, export, summarizer input, and Q&A. A rename therefore propagates everywhere instantly, and a re-transcribe (fresh, unstable diarization labels) resets the mapping rather than corrupting text.

## 2. SP1 — Meeting identity

**Title capture.** At recording start, `AppState` already holds the call app's pid (auto-stop uses it). Capture the call window's AX title there, reusing `CallDetection`'s existing window enumeration. On insert: title = calendar-event title if matched, else cleaned window title, else null.

**Calendar.** New `Meetings/MeetingCalendar.swift`: read-only `EKEventStore`; `matchEvent(start:end:)` returns the calendar event with the greatest time-overlap with the recording window → `(title, attendeeNames)`. Gated by a new `meetingsCalendarEnabled` setting, **default off** (permission prompts are opt-in in this app); enabling it triggers the macOS Calendar prompt; denied or no match → silent fallback to window title. The usage-description Info.plist key goes through the existing PlistBuddy patch phase if `INFOPLIST_KEY_*` synthesis doesn't cover it (the known `GENERATE_INFOPLIST_FILE` gotcha — verify at plan time).

**Speaker rename.** In the transcript detail, every speaker label except "You" becomes clickable → popover with a text field + suggestion chips built from `attendees`. Saving writes `speakerNames`; one rename applies to every turn with that label.

**Regenerate summary.** New button that re-runs `MeetingSummarizer` over the *resolved* transcript without re-running ASR/diarization — the correct-then-regenerate loop, and what makes renames appear in the summary ("Alice will send the deck", not "Speaker 1 will…").

## 3. SP2 — Notes quality

**Ollama routing.** `AppState.transcribeMeeting` currently hard-passes `systemLLM` to `MeetingSummarizer`. New rule: if the user's polish backend is Ollama — and only Ollama; cloud stays excluded — pass the Ollama backend, else SystemLLM. `MeetingSummarizer.generate` gains a `chunkLimit` argument: 1,800 for SystemLLM (the proven envelope), 12,000 for Ollama (fits its 30s timeout; an hour-long call goes from ~40 lossy chunks to ~6 — tune only if live testing shows timeouts). Ollama failure mid-summary → retry once via SystemLLM (fail-safe philosophy: a transcript with a mediocre summary beats an error).

**Templates.** The reduce-stage prompt (`meetingWriteStyle`) becomes one of a small set of fixed-UUID built-in templates — **Standard** (today's), **Standup**, **Client call**, **1:1**, **Interview** — sharing the chunk (map) stage. Custom templates: a user-editable list stored like `customPolishStyles` (same `PolishStyle` type, same CRUD UI pattern), managed in the Meetings section, never shown in the AI tab's dictation-style picker. Picker: a settings-level default plus a per-generation menu on the Transcribe/Regenerate button (per-run choice is not persisted per meeting).

**Editable summary.** "Edit" on the summary card → in-place `TextEditor` → Save writes back via `setTranscriptAndSummary`. Regenerate overwrites edits (same as Meetily; no merge logic).

## 4. SP3 — Post-meeting intelligence

**MCP.** Two read-only tools on the existing server, same `mcpAccessEnabled` gating and refusal behavior: `search_meetings(query)` (FTS over transcript/summary/title/appName) and `get_meeting(id)` (title, date, duration, attendees, resolved transcript, summary). `MCPLauncher` additionally opens `MeetingStore`. This delivers real cross-meeting Q&A with a frontier model — honestly, and off-device only via the user's own MCP client.

**In-app one-shot Q&A.** "Ask about this meeting" field in the detail pane: question → map (per chunk: "extract anything relevant to: {question}") → reduce ("answer from these notes; say 'not discussed' if absent"), through the same System/Ollama routing and chunk sizing as summaries. One question, one answer, no thread, nothing stored.

**Export.** Per-meeting menu: Markdown / Plain text via `NSSavePanel` (`HistoryView`'s exact pattern). Content = title/date/attendees header + summary + resolved transcript. Plus "Copy summary" alongside the existing "Copy transcript".

**Follow-up draft.** "Draft follow-up email" button: one polish call over summary + action items with a fixed hidden style → shown in a review sheet, copied to clipboard on accept. No mail integration.

## Error handling

- Calendar denied / no overlapping event → window title → appName. Never blocks or delays recording (title capture is post-hoc metadata, not on the record path).
- Ollama unreachable or erroring → SystemLLM retry once → existing failure surface.
- Q&A / draft failures → the detail pane's existing `errorMessage` line.
- Nothing in SP1–SP3 touches the recording path; all three operate on already-stored data.

## Testing (pure-logic convention; effectful verified live)

- Migration round-trip: a v1 `meetings.db` with rows survives, new columns null, FTS still matches old transcripts and new titles.
- Calendar overlap selection: greatest-overlap event wins; no-overlap → nil.
- `resolvedTranscript`: mapped labels substituted, "You" untouched, unmapped labels pass through.
- Per-backend chunk-limit selection; template prompt assembly; Q&A map/reduce prompt assembly.
- MCP `search_meetings`/`get_meeting` against in-memory stores (existing `MCPServerTests` pattern).

Live verification (per sub-project): the EventKit prompt + a real calendar-matched recording title; rename → regenerate showing names in the summary; an Ollama-summarized hour-scale transcript; export files opening correctly; MCP tools answering from Claude Desktop/Code.

## Exit criteria

- A recorded meeting shows a real title (calendar or window) and, when calendar-matched, its attendees.
- "Speaker 1" can be renamed once and the name appears in the transcript view, copy, export, and (after regenerate) the summary.
- An hour-long meeting summarized via Ollama is coherent and specific (no chunk-boundary amnesia); SystemLLM path unchanged for short calls.
- Summaries are editable; a template choice visibly changes summary structure.
- `search_meetings`/`get_meeting` answer real questions from an MCP client; in-app ask answers a one-shot question or honestly says "not discussed".
- A meeting exports to a well-formed .md file.
- Everything on-device; cloud polish backends never receive meeting content.
