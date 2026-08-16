# Delete my audio from a completed meeting — design

**Date:** 2026-08-16
**Status:** approved, not yet implemented
**Follows:** `2026-08-16-meeting-mic-control-design.md` (the live controls this
is the retroactive twin of)

## The problem

The mic controls shipped on `meeting-mic-control` only help someone who acted
*during* the recording. The reported case is the opposite: R attended a Teams
call from a conference room, forgot the mic was recording, and a private side
conversation with a colleague — plus a ringing phone — is now in a stored
meeting transcript, attributed to "You".

## Why editing the transcript text was rejected as the first move

R's first instinct was a transcript editor. It is a false fix for this case, in
three specific ways:

1. **The audio stays.** `me.caf` still holds the conversation.
2. **Re-transcribe silently restores it.** That button calls
   `setTranscriptAndSummary` and overwrites the transcript from the audio. One
   click, months later, no warning, and the edit is gone.
3. **The summary was written from the unedited transcript**, and possibly the
   title too (`nameMeetingIfNeeded`). Editing the transcript touches neither.

A transcript editor is still worth having for surgical fixes — removing one
exchange while keeping contributions you legitimately made — but it is a weaker
privacy guarantee, and shipping it first would let it *feel* like the fix. It is
out of scope here.

## The action

**"Delete my audio…"** in the meeting detail action row, beside Re-transcribe.
**Confirmed with a dialog**, deliberately unlike the live `Discard my audio`
button: that one is a panic button during a running meeting where a modal
defeats the purpose, this one is a considered decision with no time pressure and
is irreversible.

## What it does, in this order

The order is the design, not an implementation detail. Deleting the audio alone
fixes nothing, because the private words are already in the transcript — which
is the searchable, exportable, summarised copy.

1. **Delete `me.caf`.**
2. **Strip every `**You:**` block from the stored transcript.**
3. **Clear the summary, then regenerate it in the background.**
4. **Set `micCaptured = false`.**

Every step is written before the next begins, so an interruption leaves the
recording *more* private, never less.

## Step 2: block-filtering, not re-transcription

Both stored transcript formats share one shape — a label line, then body,
blank line between blocks:

- Diarized (`MeetingDiarization.renderInterleaved`): `**Speaker 1:** [0:03]\ntext`
- Legacy (`MeetingTranscriber.labeledTranscript`): `**You:**\ntext`

So a single pure function drops the user's turns from either: split on blank
lines, discard any block whose first line is a `**You:**` label, rejoin.

**Block-filtering rather than parse-and-re-render** (`AppMarkdown.turns` →
`renderInterleaved`) because a round trip through the parser silently loses
anything the parser does not model. Filtering preserves every surviving block
verbatim.

**And not re-transcription**, which was the obvious approach and is worse in
every dimension: it requires the Whisper model to be downloaded, takes minutes
on a long meeting, is nondeterministic, and **can fail — leaving the private
transcript exactly where it was**. A privacy action must fail closed. Text
filtering cannot fail, and produces the result the re-transcription would have.

## Step 3: clear first, regenerate second

The stored summary was written from the unedited transcript and may quote the
private exchange. It is cleared **before** regeneration is attempted, so a
backend that is unavailable, times out, or errors leaves the meeting with **no
summary** rather than the old one. The user can press Regenerate summary
whenever they like; there is no path where a failure preserves the leak.

The title is deliberately **not** touched. `nameMeetingIfNeeded` only ever names
a meeting from its summary when nothing better is known, and a title long enough
to leak a private aside is not a shape this produces. Wiping a title the user
may have typed would cost more than it protects.

## Step 4 and the copy change

`micCaptured` means "did any mic audio survive into the stored recording", so
`false` is definitionally correct here — none did.

But the header currently renders that as *"Your microphone wasn't recorded"*,
which would be a **lie about history**: it was recorded, and the user removed it.
Rewording to *"Your microphone isn't in this recording"* is true in both cases
and avoids inventing a third state for one line of copy.

## Afterwards

Re-transcribe stays enabled and becomes safe rather than dangerous: `me.caf` is
gone, so it regenerates an others-only transcript. No warning is needed, because
there is nothing left to restore.

## Testing

- The block filter is pure and directly tested: diarized format, legacy
  `**You:**`/`**Others:**` format, a transcript with no `You` turns (unchanged),
  a transcript of *only* `You` turns (empty result), and — the one that matters —
  **a body line that merely mentions the word "You" must survive**, since only a
  label line may be matched.
- Timecodes and the surviving blocks' text are byte-identical after filtering.
- Store-level: after the action the row has no `You` turns, a nil summary, and
  `micCaptured == false`, asserted together — checking only the file deletion
  would pass while the transcript still held everything.
- The FTS mirror updates on transcript rewrite, so a search for a phrase from the
  removed conversation stops finding the meeting. This is the check a user would
  actually perform, and the one that fails if the write bypasses GRDB's
  synchronize triggers.
- Live: the audio file is gone from the meeting directory, and the private phrase
  no longer appears in the transcript, the summary, or search.

## Deliberately out of scope

- **Editing arbitrary transcript text** (the "option A" above) — a separate,
  surgical tool, worth building later.
- **Deleting `them.caf`** — the other side of the call is the meeting record
  itself; Delete already removes a meeting whole.
- **Bulk-applying this across meetings.**
