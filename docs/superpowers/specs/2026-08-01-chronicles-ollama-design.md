# Chronicles — Ollama Backend — Design

**Date:** 2026-08-01
**Status:** Approved. Pending an implementation plan.
**Area:** S5.1 Chronicler. Closes the follow-up recorded in `CLAUDE.md`'s M3-2a row
("Chronicler stays System-only … a `ponytail`-noted follow-up").

## Problem

Chronicles run through `SystemLLM` and nothing else. `AppState.regenerateChronicle` hardcodes
`polish: systemLLM`, and `ChronicleScheduler.isSuppressed` is
`polishBackend != .system || !SystemLLM.isAvailable()`.

That was a defensible scope boundary when Foundation Models was assumed present. It is not
survivable now: **Foundation Models supports 23 locales and `en-IN` is not among them**
(`en-US`, `en-GB`, `en-AU` are), while `availability` still reports `.available` — measured on
this machine, 2026-08-01. On such a Mac chronicles can never be generated at all, whatever the
user does in the app, because the one backend they are wired to always throws
`unsupportedLanguageOrLocale`.

Meetings already solved this in SP2: `meetingSummaryBackends()` prefers Ollama when it is the
selected polish backend, falls back to `SystemLLM`, and never uses Cloud. Chronicles simply
never got the same treatment.

## Decision

**Mirror the meetings precedent exactly rather than invent a second scheme.**

1. **Ollama when it is the selected polish backend and a model is set**; `SystemLLM` otherwise,
   and also as the retry when Ollama fails. Same order, same "first candidate that produces a
   result wins" semantics as `generateMeetingSummary`.
2. **Cloud is never a chronicle backend**, whatever `polishBackend` says. Memory is local-only
   and stays that way — the same rule that keeps recordings off Cloud in meetings. This is
   enforced in code, not by a setting.
3. **Chunk limit travels with the backend.** `SystemLLM` keeps 1,800 characters;
   Ollama gets 12,000, matching `MeetingSummarizer.ollamaChunkLimit`. A day's snapshots
   currently shred into many tiny chunks purely because of Foundation Models' envelope; with
   Ollama a busy day should collapse in far fewer passes, losing less to repeated summarising.

Rejected: a separate "chronicle backend" setting (a second place to configure the same thing —
the polish backend already expresses this preference); routing chronicles through Cloud when
selected (memory is the most sensitive store in the app).

## Architecture

| Piece | Change |
|---|---|
| `Chronicler.generate(day:store:polish:)` | Gains `chunkLimit: Int = chunkCharLimit`, used for **both** the chunk and reduce passes. Today those are two constants with the same value; one parameter keeps them in step. |
| `AppState.chronicleBackends()` | New, mirroring `meetingSummaryBackends()` — returns `[(polish: PolishBackend, chunkLimit: Int)]` in preference order. |
| `AppState.regenerateChronicle(day:)` | Iterates the candidates instead of hardcoding `systemLLM`. |
| `ChronicleScheduler` | Its fixed `polish` property is replaced by a `generate: (String) async throws -> Void` closure supplied by `AppState`, so the backend is chosen when the timer fires rather than when the scheduler was wired. `isSuppressed` becomes "no usable backend", not "backend isn't System". |

The scheduler change is the load-bearing one. Holding a `PolishBackend` captured at wiring time
is why a user who switches to Ollama today still gets nothing: the scheduler keeps the
`systemLLM` it was handed when Memory was enabled.

## Error messages

Three distinct outcomes, and they must not collapse into one string:

- **No candidates at all** — Ollama not selected and `SystemLLM` unusable. Report the real
  cause via `SystemLLM.unavailableReason()` and point at Ollama, exactly as
  `AppState.systemUnavailableMessage` already does. Never "Apple Intelligence is off" when it
  is on.
- **Candidates existed but all failed** — say so, and say the chronicle was not written. A
  wrong Ollama URL and an unsupported locale are different problems.
- **No snapshots for the day** — the existing `ChroniclerError.noSnapshots`, unchanged.

## Testing

- `Chronicler.generate` honours a larger `chunkLimit`: with the stub `PolishBackend` already in
  `ChroniclerTests`, a transcript that produces several chunks at 1,800 produces strictly fewer
  polish calls at 12,000. This is the test that would actually fail if the parameter were
  accepted and ignored — asserting only that it "still works" would pass either way.
- The existing collapse-loop regression test (the one tracing the day's **last** block into the
  final reduce input) must keep passing at both limits — it is the guard against the
  truncation bug that `MeetingSummarizer` and `Chronicler` have each had once.
- **Backend ordering is not unit-tested**, matching `meetingSummaryBackends()`: constructing
  `AppState` opens the real history/memory stores, the same trap that had `KeychainTests`
  deleting real API keys. Verified live instead.

Live: with Ollama selected and a model pulled, "Generate today" writes a real chronicle on a
machine where Foundation Models cannot run — which is the whole point, and is a check that
fails today.

## Out of scope

A separate chronicle-backend setting · Cloud chronicles · changing the daily schedule or the
UTC/local day boundary · retroactively regenerating past chronicles · chronicle templates.

## Exit criteria

On an `en-IN` Mac with Ollama selected and a model pulled, "Generate today" produces a real
chronicle; with no usable backend the user sees why, naming the actual cause rather than
telling them to enable something already enabled; Cloud is never used even when selected; and
with `SystemLLM` available and Ollama unselected, behaviour is unchanged from today.
