# Meeting pre-roll recording + honest titles — design

**Date:** 2026-08-06
**Status:** approved (R, 2026-08-06)

Two independent defects reported after live use of the 2026-08-04 CoreAudio
detection rewrite. They share a file (`CallDetection`, `MeetingWatcher`) but
nothing else, and are specified separately below.

---

## Part 1 — the opening of a meeting is lost

### The report

> "It is usually taking around 10 seconds to trigger the pop up to record the
> meeting. It would be good if it pops much more faster, so that the initial
> conversation in the meetings doesn't get lost." … "Sometimes it can be more
> than 10 seconds for the pop up."

### What the code does today

`MeetingWatcherTiming.pollInterval = 2s`, `startDebounce = 3s`. The debounce is
measured from the *tick* that first saw the mic, so at a 2s cadence a 3s
threshold is crossed two ticks later. Mic-open → prompt is **4s best case, 6s
worst**.

That does not explain "more than 10 seconds", and **nothing in the app records
the real number** — there is no log pairing mic-first-seen with prompt-shown.
The leading hypothesis is that the mic does not open when the meeting appears
to start (joining muted may leave Teams' input stream stopped, so
`kAudioProcessPropertyIsRunningInput` stays false until unmute), but that is a
hypothesis. The last time detection was reasoned about from plausibility rather
than measurement, a 30-minute call went unrecorded.

### Why "make it faster" is the wrong goal

Even at zero detection latency the opening is lost: the consent panel is a
320pt non-activating card in the top-right corner, and the user must notice it
and click. That is realistically 5–15 seconds of talking. Halving 6s to 3s
improves the number and barely changes the outcome.

### Decision: record from detection, keep only on consent

The recorder starts the moment a recognised call is detected. Audio is written
to the meeting directory as it always has been. If consent is refused, the
recorder stops and **the directory is deleted**; no row is ever inserted.

Consequence: detection latency stops mattering. A 6s delay, or a 30s one,
costs nothing.

**Rejected — RAM ring buffer** (nothing ever touches disk until accept). Same
guarantee, materially more work: `MeetingRecorder` writes through `AVAudioFile`
in its IO callback, so a pre-roll buffer means a second write path plus ~35 MB
for 60s. Chosen against on cost, with the disk trade accepted explicitly below.

**Rejected — tuning the timings alone** (poll 2s→1s, debounce 3s→1s). Cheap and
safe, and it does not solve the stated problem.

### The trade, stated plainly

Audio touches disk before the user consents. "Never written" and "written then
deleted" are not the same claim, and **the consent panel's copy must stop
implying the former** (today: *"No answer? We'll ask once more, then leave it.
Stays on this Mac."*). The behaviour does not ship without the copy change.

### Where the pre-roll starts

At the `.idle → .detecting` transition — first sight of the mic, not after the
debounce. The 3s debounce exists to stop *prompting* on a transient mic open;
it has no reason to gate *capture*. This recovers the debounce window as well
as the user's reaction time. The prompt still waits it out.

`.detecting` carries no app name today. Rather than change the pure `nextState`
signature and its tests, the side-effect layer in `apply()` — which already
holds `detected` — supplies name and pid.

Capturing the window title at pre-roll start is a side benefit: it is read
while the call window is definitely up, rather than at consent time.

### What each answer does

| Answer | Effect |
|---|---|
| **Accept** (panel Record, or the hub's Start button during any pre-roll state) | Nothing starts. The recording already exists and continues. `isRecordingMeeting` flips true; panel dismissed. |
| **Decline** | Stop recorder, delete directory, insert no row. |
| **First timeout** | **Pre-roll survives** the 60s `retryCooldown`. See below. |
| **Second timeout** | Stop, delete directory. |
| **Call ends during pre-roll** (any of `.detecting`/`.prompting`/`.awaitingRetry` → `.idle`) | Stop, delete directory. |
| **Recorder fails to start** | Prompt still shows; accepting starts it then, exactly as today. A pre-roll failure costs the pre-roll, never the meeting. |

### The timeout window (R's decision, 2026-08-06)

An unanswered prompt is not a refusal — that distinction is already load-bearing
(`MeetingConsent.timedOut` exists precisely because conflating it with
`.declined` latched a missed call for its whole duration). Deleting on the first
timeout would make the retry start from zero 60 seconds later, which is past the
opening this work exists to save.

So the pre-roll survives the retry window. **The accepted ceiling: up to ~70
seconds of audio on disk before anyone consented to it.** Bounded on both ends —
explicit decline deletes immediately, the second timeout deletes, and a call
that ends during the window deletes for free via the existing
`.awaitingRetry → .idle` transition.

### `isRecordingMeeting` stays false during pre-roll

If it were true, the hub's button would read "Stop recording" while the consent
panel asks "Record this Teams call?" — two contradictory statements about the
same recording. During pre-roll the panel is the only UI.

This makes the hub's Start button unambiguous while consent is pending: it means
yes, and promotes the pre-roll. Without that, `toggleMeetingRecording` would
start a *second* recorder over a live one.

Stop is not reachable during pre-roll, because Start is what the button shows.

### Orphan sweep at launch

The hazard that shortening the window does **not** fix: if the app crashes or is
force-quit mid-window, the directory is never deleted and orphaned audio sits on
disk with nothing pointing at it.

This already exists today for consented recordings — the `meetings` row is only
inserted at stop — and pre-roll makes it more frequent. On launch, delete any
meeting directory with no corresponding row in `meetings.db`.

Guard: the sweep must not delete the directory of a recording in flight. It runs
once at startup, before any recorder can have started.

### Instrumentation, which is the point

A `.notice` log stamping mic-first-seen → prompt-shown → consent-answered, so
the next real call reports the true latency instead of the hypothesis above.
Without it, any timing change is tuned against a guess.

Bundle IDs, pids and durations only — never window titles. Surfaced through
`DebugInfo.meetingDetectionLines`, alongside the state already reported there.

---

## Part 2 — ad-hoc 1:1 calls are titled "Chat"

### The report

A scheduled meeting is titled correctly. An ad-hoc 1:1 Teams call was filed as
**"Chat"** (screenshot, 6 Aug 2026, 31m46s, 3 speakers).

### Root cause

`CallDetection.callWindowTitle` returns

```swift
titles.first(where: hasCallLikeTitle) ?? titles.max { $0.count < $1.count }
```

— i.e. **the longest window title** when no title contains a call word. For a
1:1 Teams call that is the main nav window, `Chat | Microsoft Teams`, which is
longer than the actual call window's title. `cleanedMeetingTitle` then splits on
`" | "` and yields `Chat`.

The heuristic is not failing to clean a bad title. It is **choosing the wrong
window**. Scheduled meetings escape it only because `MeetingCalendar.match`
overwrites the title afterwards, which is why the defect is invisible until an
ad-hoc call.

### Decision: both fixes, because neither works alone

**D — reject app-chrome titles.** A pure `isGenericTitle(_:appName:)` rejecting
the nav sections that are never meeting names (`Chat`, `Calls`, `Activity`,
`Calendar`, `Home`, `Files`, `Communities`, plus the app's own name, already
handled). Applied in two places: `callWindowTitle`'s selection, so a chrome
window cannot win the longest-title contest, and `cleanedMeetingTitle`'s result.

This is another vendor-shaped string heuristic — the exact class of thing that
missed the 30-minute call — and it will rot when Teams renames a tab. It is
included anyway because without it a generic title still wins and E is never
consulted. Its failure mode is benign: a missed rejection falls through to E.

**E — the model names the meeting.** A hidden fixed-UUID `PolishStyle` (absent
from `builtInTemplates`, pinned by the existing test) and
`MeetingSummarizer.title(fromSummary:polish:)`.

**From the summary, not the transcript.** The summary is short, already
distilled, fits any chunk limit, and needs exactly one model call with no
chunking. Generating from the transcript would repeat the whole map-reduce for a
six-word answer.

Applied when the stored title is nil or generic, in both `transcribeMeeting` and
`regenerateSummary` — so **Regenerate summary retitles the rows already on
disk**, including the "Chat" one in the screenshot.

**Never overwrites a title the user typed.** `MeetingStore.setDetails` is the
user-edit path; a generated title is written only when the stored title is nil
or generic. A user-typed "Chat" is a title they chose and survives.

**Matched exactly, never by `contains`.** `cleanedMeetingTitle` has already
split on `" | "`, so the candidate is the bare word. A substring test would
reject the real meeting name "Chat app redesign" — the same length-unbounded
mistake that made `answer()` discard extracts reading "Nothing relevant to the
budget, but…".

When the summary fails, no title is generated and the display falls back to
`appName`, exactly as today.

---

## Testing

Pure and testable:

- `isGenericTitle` — accepts a real meeting name, rejects each chrome word, is
  case-insensitive, and does not reject a name that merely *contains* one
  ("Chat app redesign" is a real meeting name).
- `callWindowTitle`'s selection, extracted as a pure function over `[String]`
  so the AX enumeration is not in the way — **must fail if the longest-wins
  rule is restored**, since that is the actual bug.
- `nextState` is unchanged; the pre-roll lives in the side-effect layer, so its
  existing tests stay green as the regression proof.
- Pre-roll lifecycle via `MeetingWatcher`'s injected closures: a decline and a
  second timeout each fire discard exactly once, an accept fires none, and a
  call ending in any pre-consent state discards.
- Orphan sweep: a directory with no row is deleted, a directory with a row is
  not. **The second half is what makes it a real test** — a sweep that deletes
  everything passes the first half.

Not unit-testable, owed live: the true latency from the new log stamp, the
consent panel's new copy, and that a declined pre-roll leaves nothing on disk.
