# Silent Fallback Trace — Design

**Date:** 2026-08-02
**Status:** Approved. Pending an implementation plan.
**Area:** Cross-cutting — `Polish/`, `Memory/`, `DebugInfo`.

## Problem

Several features fail *safe*: when something goes wrong they substitute a plausible result and
carry on. Individually each is correct engineering. Together they make a broken feature
indistinguishable from a working one.

Found on 2026-08-01/02, all on the same machine, all invisible to a 439-test suite:

| Feature | On failure | Looks like |
|---|---|---|
| Polish (dictation, Smart Dictation, Polish Selected, brain-dump, Reply Assist) | pastes the **original text** | polish decided nothing needed changing |
| Memory capture | returns nil, stores nothing | nothing was on screen worth capturing |
| Meeting Ask | "That wasn't discussed in this meeting." | a correct answer |
| Ollama timeout | "Couldn't reach Ollama. Is it running?" | the service being down |

The cost was concrete: **Apple Intelligence has never worked on this Mac** — `en-IN` is not among
Foundation Models' 23 supported locales, while `availability` still reports `.available`. Smart
Dictation, Polish Selected, brain-dump and Reply Assist therefore returned raw text **for
months**, and nothing anywhere said so. It surfaced only because chronicles happened to raise
the framework's raw error instead of swallowing it.

The existing `DebugInfo.recentLogLines` can read the unified log back, so a channel exists — but
it requires already suspecting a problem, which is exactly what did not happen.

## Decisions

1. **Escalating, not passive and not immediate.** Always recorded and passively visible; but when
   a feature falls back **N times consecutively**, say so once, unprompted.
   *Occasional* fallback is normal and must stay silent — a flaky network nagging on every paste
   teaches users to ignore the alert, which is worse than no alert. *Persistent* fallback means
   the feature is dead, and that is precisely the case that cost months.
2. **Only unambiguous degradations.** Polish falling back to raw text, and Memory capture
   returning nothing while enabled. In both, a streak has no innocent explanation.

**Deliberately out of scope: meeting Ask.** "That wasn't discussed" can be legitimately correct
five times running — a streak there cannot distinguish a broken extractor from a user asking
about things the meeting did not cover. Alerting on it would produce false alarms, and a false
alarm trains people to dismiss the real one. Ask remains able to mislead; that is a known,
accepted gap.

Also out: meeting summaries and chronicles, which already raise visible errors.

## Architecture

| Piece | Responsibility |
|---|---|
| `Degradation` | The whole mechanism. `record(_:reason:)` increments a per-feature consecutive-failure streak and stores the latest reason; `recordSuccess(_:)` clears both the streak and the warned flag. Pure decision logic (`shouldEscalate`) separated from storage so it is directly testable. |
| `Degradation.Feature` | `polish`, `memoryCapture`. An enum, so a typo cannot silently create a third counter that nobody reads. |
| Call sites | `AppState.polishedText(for:)` and `MemoryCapture.tick()` — two places, both already the single funnel for their feature. |
| `DebugInfo` | A section listing each feature's streak and last reason. |
| Settings surfaces | AI Polish and Memory each show their own count and last reason. |

### Persistence is load-bearing

Streaks live in `UserDefaults`, not memory. Apple Intelligence failed **across relaunches** for
months; an in-memory counter would have reset before ever reaching a threshold, and this whole
mechanism would have missed the exact bug that motivated it.

### Thresholds differ because the cadences differ

- **Polish: 10 consecutive.** Ten dictations, none polished — that is dead, and ten is few enough
  to notice within a session.
- **Memory capture: 120 consecutive.** Capture ticks every 5 seconds, so 10 would be under a
  minute of ordinary window-switching. 120 is roughly ten minutes of capturing nothing while
  enabled and unpaused.

One mechanism, a threshold per feature.

### What must not count

**Configuration is not failure.** None of these increment anything:

- polish backend set to Disabled; no text to polish
- Memory paused, or disabled
- an excluded app, excluded domain, or private-browsing window
- a window with genuinely no text (a canvas app, a mid-load page)

If configuration counted, the alert would fire for people who deliberately switched something
off — and within a week nobody would read it.

### Escalation fires once

A `warned` flag suppresses repeat alerts for the same streak; a success clears it. The alert
reuses the existing one-time-nudge pattern (`errorMessage`), which the app already uses for
Foundation Models being unavailable — precedent rather than a new interruption style.

**Accepted concern:** that is a modal alert, and one arriving straight after a paste is
intrusive. It fires at most once per streak, and the passive-only alternative was rejected
precisely for being missable. Revisit if it proves annoying in practice.

## Passive surface

Between escalations, each feature's settings screen shows its streak and last reason, and
`DebugInfo` includes the same. This answers "is polish actually running?" without waiting for a
threshold — the question that had no answer for months.

## Failure handling

The recorder must never break the thing it observes. A failure to read or write `UserDefaults`
is swallowed; recording is best-effort telemetry, and a broken counter must not stop a paste.

## Testing

`shouldEscalate` is pure and carries the real tests:

- Nine failures escalate **nothing**; the tenth escalates. **This is the test that fails if the
  mechanism always or never fires** — a "does it escalate?" test alone passes either way.
- Escalation happens **once**: the 11th, 12th … failures do not re-fire.
- A success resets both streak and warned flag, so a later streak can escalate again.
- Configuration reasons do not increment.
- Per-feature thresholds are independent: polish at 10 does not trip memory capture.

Live: with the polish backend set to System on a Mac where Foundation Models cannot run,
ten dictations must produce exactly one alert naming the real reason — the scenario that
silently produced nothing for months.

## Out of scope

Meeting Ask · meeting summaries and chronicles (already visible) · telemetry leaving the device
(nothing here is transmitted; it is local state and Debug Info text) · a general event log or
metrics system · changing any fallback's behaviour — every one still fails safe exactly as it
does today.

## Exit criteria

Ten consecutive polish fallbacks produce one alert naming the cause; the eleventh produces
none; a single successful polish resets it. Memory capturing nothing for ten minutes while
enabled does the same. Turning polish off, or pausing Memory, produces no alert ever. Both
counts are visible on their settings screens and in Debug Info without waiting for a threshold.
