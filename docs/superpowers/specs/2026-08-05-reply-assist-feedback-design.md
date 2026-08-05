# Reply Assist Feedback — Design

**Date:** 2026-08-05
**Status:** Approved. Pending an implementation plan.
**Area:** S4 Reply Assist + the overlay HUD. Sub-project 2 of the "raise Reply Assist to
best-in-class" effort, promoted by hitting it in use.

## Problem

**Double-tapping right ⌥ produces nothing observable.** Reported directly: *"we don't see any UI
hover or anything, we don't know whether the request is taken or not."*

`AppState.beginReplyAssist` touches no overlay. Between the double-tap and the text appearing
there is AX focused-element resolution — up to ~1.6s on Electron trees, which the code comments
document — plus the model call, 2s on Apple Intelligence and longer on Ollama. Several seconds
of silence, with no way to tell whether the trigger registered.

### Failures are worse than slow

Reply Assist has five failure paths, each of which sets `errorMessage` and returns:

| Cause | Message set |
|---|---|
| No focused field | "couldn't read the focused field." |
| No AI backend | "needs an AI polish backend enabled in AI settings." |
| Model call threw | "draft failed (…)" |
| Focus moved mid-draft | "focus changed, nothing was typed." |
| Draft tripped the sentinel guard | "the draft looked like an error, nothing was typed." |

**None of them is ever displayed.** `AppState.errorMessage` is written 25 times across the file
and read by no view. Every `errorMessage` in the UI layer is a view's own `@State private var` —
five separate local ones in History, Memory, Chronicles, Home and Meetings. Dictation errors
surface only indirectly, because `AppState.swift:1950` checks whether the property is non-nil to
choose the overlay's exit flourish; the text itself is never shown, and Reply Assist does not
touch the overlay at all.

So a user who double-taps and sees nothing cannot distinguish "still working" from "failed", nor
learn which of five things failed — including two, *no text field* and *no AI backend*, that
they could fix in seconds if told.

### The trap in the obvious fix

`OverlayView.isVisible` is:

```swift
appState.dictation != .idle || appState.overlayPhase == .polishing || appState.overlayPreview != nil
```

With `dictation == .idle` — Reply Assist's state throughout — `.polishing` shows the HUD and
**`.error` does not**. Setting an error phase from Reply Assist would therefore render nothing,
and the fix would look complete while changing nothing observable. This is the same shape as the
entries in CLAUDE.md's Verification section.

Polish Selected Text also runs with `dictation == .idle`, so it plausibly has the same silent
failure. The implementation checks and, if so, fixes it in the same pass.

## The fix

**A `.drafting` phase.** `OverlayPhase` gains one case, rendering **"DRAFTING"**.

Reusing `.polishing` would cost nothing and display a word that is not true, on every draft. The
overlay is the app's face and this project treats its copy as load-bearing; one enum case and
three switch arms is a small price for not lying. Touch points: the enum, `phaseLabel`,
`hudColor`, and the visibility rule.

**`isVisible` becomes testable, and gains the missing cases.** It moves from a private computed
property to `OverlayView.isVisible(dictation:phase:isPreview:)`, a `nonisolated static` —
precisely the treatment `OverlayView.showsTranscript` received on 2026-08-05, which is already
asserted in `OverlayStyleTests`. It then admits `.drafting` and `.error`.

**Reply Assist drives it:**

- `overlayPhase = .drafting` and `overlay.show()` fire **immediately on double-tap**, before AX
  resolution. The acknowledgement must be instant; arriving after 1.6s would answer the wrong
  question.
- The HUD is hidden **just before** the typist starts. The text appearing is the success signal,
  and a "DRAFTED" beat would be noise by the fortieth use — the calm-motion rule the design
  system already applies.
- On failure, `overlayPhase = .error(label:)` holds briefly, then clears.

The HUD is a non-activating, click-through `NSPanel`. That property is why this is possible at
all: the original Reply Assist panel was removed precisely because it stole focus, and nothing
here reintroduces that.

**Failure labels name the cause**, in the existing register (`NOTHING HEARD`,
`SOMETHING BROKE — TEXT COPIED`):

| Cause | Label |
|---|---|
| No focused field | `NO TEXT FIELD` |
| No AI backend | `NO AI BACKEND` |
| Model call threw | `DRAFT FAILED` |
| Focus moved mid-draft | `FOCUS CHANGED` |
| Sentinel guard declined | `DRAFT LOOKED WRONG` |

The existing `errorMessage` assignments stay. They are harmless, and they become useful the day
that channel is connected.

## Deliberately not doing

**A success beat.** The drafted text arriving is unambiguous. An extra flourish fails the
fortieth-use test.

**A cancel affordance in the HUD.** A second double-tap cancels an in-flight draft, and that is
undiscoverable. Saying so needs either a longer label or a second line, and the HUD's geometry
is specified in `OVERLAY_SPEC.md`. Worth doing; not worth doing carelessly here.

**The app-wide `errorMessage` channel.** Twenty-five sites, each wanting a different
destination — some fire inside hub views that already own local alerts, some fire with no window
open at all. One blanket mechanism would be wrong for most of them. Recorded as its own piece of
work.

**Any change to what Reply Assist drafts.** Sub-project 1 (reading the conversation) is on this
same branch and unmerged; this adds only feedback.

## Testing

The visibility rule is pure once extracted, and its test **fails on today's code** — which is
the point of extracting it:

- `dictation: .idle, phase: .error` → visible. **This is the bug.**
- `dictation: .idle, phase: .drafting` → visible.
- `dictation: .idle, phase: .none` → hidden. Guards against fixing the above by making the HUD
  permanent.
- `dictation: .recording, phase: .none` → visible, unchanged.
- A preview forces visible regardless, matching `showsTranscript`'s existing contract.

The cause→label mapping is a pure function and is asserted directly, including that every case
produces a non-empty label — an empty one renders an invisible capsule, which is the silent
failure this whole sub-project exists to remove.

The HUD's appearance is verified live, per this project's standing convention that SwiftUI
rendering is not unit-tested.

## Live verification

Each can come back negative:

1. **Double-tap in a text field** → a DRAFTING HUD appears immediately, not after a pause, and
   disappears as the text starts arriving.
2. **Double-tap with no text field focused** (click the desktop first) → `NO TEXT FIELD`.
3. **Double-tap, then immediately click another app** → `FOCUS CHANGED`, and nothing is typed
   into either app.
4. **The HUD does not steal focus** — the field you were in still has the caret, and typing
   continues to land there while the HUD is up.
5. **Polish Selected Text failures**, if that hole is confirmed and fixed, surface rather than
   ending in silence.

## Exit criteria

A double-tap produces visible acknowledgement within a fraction of a second; each of the five
failure paths shows a capsule naming its cause; the HUD never takes focus from the field being
replied into; and the visibility rule is asserted by a test that fails against the current
implementation.
