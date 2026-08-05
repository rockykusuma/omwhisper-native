# Reply Assist Reads the Conversation — Design

**Date:** 2026-08-05
**Status:** Approved. Pending an implementation plan.
**Area:** S4 Reply Assist. Sub-project 1 of a larger "raise Reply Assist to best-in-class" effort.

## Problem

Reply Assist drafts are not good enough, and the dominant reason is what it feeds the model.

`AppState.beginReplyAssist` calls `ScreenContextReader.captureFrontmostWindowText()`, which walks
the **whole window**. Memory hit exactly this problem and was fixed on 2026-08-01 to target the
page's web area instead — the tracker records why: *"Browser and Electron windows were being
recorded largely as sidebar and tab-strip text. Memory now reads the page content itself, so
searches find what you were reading rather than the chrome around it."*

**Reply Assist never got that fix.** So when replying in Slack, Gmail or Teams — the cases the
feature exists for — the model receives up to 2,000 characters that are substantially channel
lists, navigation and tab strips rather than the conversation being replied to.

This also silently breaks a correct piece of reasoning. `draftStyle` deliberately takes the
**suffix** of the context, with the comment: *"the window is scraped top-down, so in a chat the
newest message (what you're replying to) is at the BOTTOM."* That is true of a conversation. It
is not true of a window whose tail may be a sidebar. The heuristic is right; the input does not
honour it.

### A second, cheaper gap

The prompt never says **which app** or **which window** the user is in. Both are available at the
call site and neither is passed. A reply in Slack and a reply in Mail are drafted with identical
framing, when register is one of the few things that most obviously separates a good draft from
a wrong one.

### What this is not

Four other things are wrong with Reply Assist. They are deliberately out of scope and get their
own passes:

- **Memory grounding.** The roadmap promised it — *"S4 ships window-context-only (no stored
  memory), gains memory snippets when S1 lands"* — and S1 landed on 2026-07-08 without it. But
  for most replies memory adds nothing, a bad retrieval actively pollutes the prompt, and
  measuring it on top of chrome-text input means judging one unknown through another. It needs a
  working baseline first, which is what this sub-project produces.
- **Intent.** `draftAndStream(mode:intent:...)` is called with `intent: ""` hardcoded, so every
  draft is inferred. There is no way to say "decline, suggest Thursday".
- **Feedback.** `beginReplyAssist` touches no overlay. The user double-taps and gets silence for
  as long as AX resolution (~1.6s on Electron) plus the model takes.
- **Per-app shaping.** Planned as F6, unbuilt.

## The fix

What Reply Assist reads changes. Nothing else does — no new setting, no UI change, no change to
the double-tap flow or the typing path.

### 1. Target the conversation

A new `ScreenContextReader.captureConversationText()` prefers `BrowserURL.findWebArea` and falls
back to today's whole-window walk when there is no web area, so native apps — Mail, Messages —
behave exactly as they do now.

`findWebArea` is already internal, already used by `WindowSnapshotReader`, and its own
documentation notes it is not browser-only: *"Electron apps (Teams, Slack, VS Code, Claude)
expose a web area too, which is why no allowlist is involved."* This reuses proven code rather
than adding a second implementation of the same idea.

The existing suffix logic then becomes correct rather than accidentally correct.

### 2. Tell the model where it is

The prompt gains the frontmost app's name and the focused window's title. Both are already
available; both are discarded today.

### 3. Extract the prompt so it can be tested

`draftStyle` is a `private static` on `AppState`, which cannot be constructed in a test — its
initialiser opens the real history and memory stores, the trap `KeychainTests` fell into. It
becomes a pure `ReplyDraftPrompt` type, the same separation `LongFormBackends` received on
2026-08-05.

That is what makes real assertions possible: today the prompt's most important properties — that
the newest text survives the cap, that a rewrite keeps its selection's head while a continuation
keeps its tail — are untested because the function is unreachable.

## Deliberate decisions

**The 2,000-character cap stays.** It exists for a measured reason: 50,000 characters tripped
SystemLLM's 5-second timeout live, *"confirmed live: 'Polish timed out' against a text-heavy
markdown file in the background window."* The win here is that those 2,000 characters become
conversation instead of navigation. Raising the cap is a separate lever with its own latency
cost and should be judged against a working baseline.

**Exclusions stay.** `captureFrontmostWindowText` already refuses password managers, private
browsing and `.env` via `isExcluded(bundleID:windowTitle:)`. The new path keeps that gate. A
deliberately-invoked feature is not a reason to read a password manager.

**S2's vocabulary path is untouched.** `captureFrontmostWindowText` is also used by
context-aware dictation. Web-area targeting would probably help it too, but engine biasing is
*measured inert* on Apple Speech and both Parakeet variants, so changing it buys nothing and
risks a regression in a second feature. A new function is added rather than the shared one
changed.

**No change to backend selection.** Reply Assist stays on `activePolishBackend()`. It is
interactive — the user is waiting to send a message — so it belongs with dictation rather than
with the long-form paths, whatever its input size.

## Architecture

| Piece | Responsibility |
|---|---|
| `ScreenContextReader.captureConversationText()` | Effectful: resolve the focused window, prefer its web area, fall back to the whole window, apply exclusions. Returns app name, window title and text. |
| `ReplyDraftPrompt` (new, pure) | Assemble the draft instructions from mode, context, app, title and tone. No AX, no `AppState`. |
| `AppState.beginReplyAssist` / `draftAndStream` | Unchanged orchestration; call the two above instead of building the prompt inline. |

## Failure handling

- **No web area** — falls back to the whole-window walk. This is the native-app path and must
  stay indistinguishable from today's behaviour.
- **No focused window at all** — unchanged: `currentContext()` already returns nil and the user
  sees *"couldn't read the focused field."*
- **An excluded app** — unchanged: no text is captured, and the draft proceeds on mode alone
  rather than leaking excluded content into a prompt.
- **Empty window title** — the line is omitted rather than rendered empty, the same rule the
  chronicle caption follows.

## Testing

Everything asserted is pure; the AX capture itself is verified live.

- **The newest text survives the cap.** Build a context longer than the cap whose last line is a
  known sentinel, and assert the sentinel is in the prompt. A test that only checked "the prompt
  contains the context" would pass while truncating away the message being replied to — which is
  the actual bug.
- **Rewrite keeps the head, continuation keeps the tail.** These are opposite and easy to
  transpose; each gets a sentinel at the end that must or must not appear.
- **App name and window title appear**, and an absent title renders no empty line.
- **Tone is included when present and omitted when absent.**

Live, and this is the check that matters: trigger a reply in Slack or Gmail and compare against
today's draft. **The question is whether the draft references the actual last message** — today
it frequently cannot, because that message may not be in the 2,000 characters at all. Repeat in
a native app (Mail or Messages) to confirm the fallback path is unchanged.

## Out of scope

Memory grounding · intent capture · drafting feedback or a HUD · per-app output shaping ·
raising the context cap · changing which backend drafts · the typing path · the double-tap
trigger.

## Exit criteria

A reply drafted in a browser or Electron app is built from the conversation rather than the
window chrome, and references the message actually being replied to; the prompt names the app
and window; native apps draft exactly as they did before; excluded apps still contribute no
text; and the prompt's cap and ordering rules are asserted by tests rather than by reading.
