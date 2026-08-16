# Meeting microphone control — design

**Date:** 2026-08-16
**Status:** approved, not yet implemented

## The problem, as reported

R attended a Teams call from a conference room with no dedicated hardware —
MacBook mic and MacBook speakers. He was **muted in Teams for essentially the
whole call** and mostly listening. The recorded transcript nevertheless contains,
under **"You"**:

- a private side conversation with a colleague sitting in the same room
- a phone ringing (`*phone ringing* Hello.`)

The reported expectation — *"my voice should only register if I am unmuted"* —
rests on a premise that is false, and the correction is the reason this design
exists:

> **Muting in Teams does not mute the microphone.** Teams stops *transmitting*
> your audio. The hardware mic keeps running, and `MeetingRecorder`'s aggregate
> device reads the hardware directly. Nothing in the captured audio distinguishes
> muted from unmuted.

## Why not just detect Teams' mute state

Investigated first, and rejected as the *first* thing to build. macOS exposes no
per-process mute state to another application:

- The six process-scoped CoreAudio properties are `BundleID`, `PID`, `Devices`,
  `IsRunning`, `IsRunningInput`, `IsRunningOutput`. No mute among them.
- `kAudioHardwarePropertyProcessInputMute` exists and is **not** it. Its own doc
  text reads *"all data coming into **the process**"* — it is how an app mutes
  its **own** input, scoped to the caller. It cannot read Teams.

That leaves reading Teams' mute button through Accessibility, which is rejected
for now on three grounds:

1. **Per-vendor and vendor-invalidated.** Teams, Zoom, Meet and Slack each need
   their own button-finding logic, and New Teams is a webview whose AX tree
   Microsoft re-lays-out freely. This is the exact shape of `hasCallLikeTitle`,
   which returned nil on every 2s poll for 30+ minutes of a real Teams call
   because Microsoft moved the meeting name into the window title.
2. **Asymmetric failure.** Wrong toward "muted" **silently drops the user's real
   contributions**, discovered weeks later reading a transcript missing what they
   said. Silent data loss is the worst failure mode available here.
3. **It would not fully solve the reported problem.** During the stretches the
   user *is* unmuted, the room side-chat is still captured.

Whether an AX mute signal exists at all is worth **measuring** before designing
around it — see "Deliberately out of scope".

## What is being built

A manual control, in two forms that make **different promises**. The difference
is load-bearing and the copy must not blur it.

### 1. Global: "Record my microphone in meetings"

- Lives in Meetings settings. **Default: on** — the current behaviour. Flipping
  the default would silently stop capturing every existing user's own voice.
- When **off**, `MeetingRecorder` never adds the mic sub-device to the aggregate
  device. The mic is not captured-and-discarded; it never enters the process, and
  `me.caf` is never created. This is a provable guarantee, not a promised one.
- Governs the **pre-roll** too, which begins at detection before any consent
  prompt exists — so this setting is what actually protects the room during the
  seconds before the panel appears.

### 2. Live: two buttons while a recording is running

These can only stop something already running, so their guarantee is weaker than
the global setting's. The copy says "stopped recording your mic", never "your mic
was never recorded".

| Button | Effect |
|---|---|
| `Mute my mic` | Stops mic capture for the remainder of this recording. `me.caf` keeps what was captured up to that instant. |
| `Discard my audio` | Deletes `me.caf` in full **and** mutes. Nothing from the mic survives. |

**Both are one-way for the remainder of that recording. Neither un-mutes.**

### Why one-way — the part that looks arbitrary and is not

A reversible mute forces a choice between two broken options:

- **Drop frames while muted.** `me.caf` then contains the unmuted stretches
  concatenated, so every "You" timestamp after the first gap shifts earlier than
  it really happened, corrupting the interleaved diarized transcript.
- **Write silence while muted.** Timeline stays correct, and it is worse: the
  meeting transcription path has **no VAD anywhere** (`EnergyVAD` exists only in
  `WhisperEngine`, on the dictation path), and this project has already recorded
  Whisper confidently inventing `"Thank you."` out of silence. A mostly-silent
  mic track would produce hallucinated sentences the user never said, attributed
  to them by name, inside a meeting record.

One-way mute avoids both: the retained audio is always a clean **prefix**, whose
timestamps are correct by construction and which contains no synthesised silence.
A user who genuinely wants the mic back stops and starts a new recording.

`Discard my audio` implies mute — discarding while continuing to capture would
immediately re-accumulate what was just deleted.

### Confirmation

`Discard my audio` gets **no confirmation dialog**. It is a panic button reached
for while a live meeting runs; a modal defeats its purpose. It is separated
visually from `Stop` and destructive-styled instead. Explicitly R's call, made
with the misclick risk stated.

## Where the controls live

- **Menu-bar mini panel** — the one that matters. During a Teams call the hub
  window is not open. The panel is already meeting-recording-first
  (`MiniPanelView`: record/stop primary action, "Recording meeting…" status line).
- **Hub Meetings recording bar** — alongside the existing Start/Stop recording
  control in `HubMeetingsSectionView`.

Both surfaces show the mic controls **only while a recording is running**, and
reflect mic state once muted (the button becomes an inert "Mic off" indicator
rather than a toggle, matching the one-way rule).

## Provenance: a new `micCaptured` column

A transcript with no "You" turns is ambiguous — *did I not speak, or was the mic
off?* — and that ambiguity is unresolvable a month later. This is the same
reasoning that put the "Written by" caption on summaries.

- `meetings` gains a **nullable** `micCaptured` (Bool). Nullable so pre-existing
  rows read back NULL and are rendered as "unknown" rather than falsely claiming
  either state.
- **Definition: did any mic audio survive into the stored recording.** Derived at
  stop from the file itself — `me.caf` absent, or present with zero frames — not
  from the settings that led there. Deriving it from the file is what stops the
  flag drifting from what is actually on disk.
- So: global setting off → false. Discarded → false. Muted before anything was
  captured → false. **Muted at minute 55 of 60 → true**, because 55 minutes of
  mic audio genuinely were recorded and a header claiming otherwise would be a
  lie. Partial capture is deliberately not distinguished: the ambiguity this
  column exists to resolve is "*no `You` turns at all — did I not speak, or was
  the mic off?*", and a partial capture still produces `You` turns, so the
  question never arises.
- The meeting detail header shows *"Your microphone wasn't recorded"* when false.
  NULL shows nothing.

## Transcription with no mic track

`MeetingTranscriber` must treat a missing or empty `me.caf` as a normal case, not
an error:

- `labeledTranscript(you:others:)` with an empty `you` yields an others-only
  transcript.
- `diarizedTranscript` produces no `You` segments and interleaves only the
  diarized system-audio segments.
- A meeting whose mic track is absent still transcribes, summarises and titles
  normally.

## Testing

Pure and store-level pieces are unit-testable; the CoreAudio path is not.

- `micCaptured` round-trips through `MeetingStore`, and the migration leaves
  pre-existing rows NULL — run against a **copy** of the real `meetings.db`, never
  production, per the standing constraint.
- `labeledTranscript` with an empty `you` returns others-only text.
- **One-way mute, stated so it can fail:** feed the recorder's buffer-handling
  path frames, mute, then feed more frames, and assert the mic frame count stops
  advancing. There is no unmute API to call, so a test phrased as "unmuting does
  not work" would be vacuous — it must assert on frames written, which is the
  thing a future reversible-mute change would break.
- Discard deletes the file **and** leaves the recorder muted, asserted together;
  a discard that left capture running would silently re-accumulate what was just
  deleted, and a test checking only the delete would pass.

The CoreAudio aggregate change (mic sub-device absent) has no unit test — it is
verified live, and the check that can fail is: record a meeting with the global
setting off, then confirm **`me.caf` does not exist on disk** and the transcript
carries no "You" turns. "It looked fine" is not that check.

## Deliberately out of scope

- **Automatic mute detection.** Measure first whether Teams exposes mute in its
  AX tree at all, from inside the app (a shell-spawned probe makes Terminal the
  responsible process for TCC, so every AX read returns empty and a real signal
  would look absent). Only design around it if it proves stable across several
  real calls.
- **Room-voice attribution.** `MeetingTranscriber` labels the entire mic track
  `"You"` — diarization runs only on the system-audio track — so a colleague in
  the room is attributed to the user whenever the mic is on. That is F3
  (FluidAudio speaker ID) and a separate piece of work. Note it would **not**
  have fixed the reported problem: the side chat is the user's own voice, so a
  speaker-ID gate keeps it.
- **Retroactively dropping the mic track from already-recorded meetings.**
