# Memory Capture — Web Area, Not Whole Window — Design

**Date:** 2026-08-01
**Status:** Approved (brainstorming), pending an implementation plan
**Area:** S1 Memory capture. Follows the semantic-search work, which exposed this as the
real ceiling on retrieval quality.

## Problem

`WindowSnapshotReader.captureFrontmost` walks the AX tree from the **window root**, so every
snapshot carries the app's chrome: Arc's sidebar and pinned-tab list, toolbars, tab strips.

Measured on the real store: **58% of a median Arc snapshot (median) is boilerplate** — tokens
appearing in >70% of all Arc snapshots — and Arc is 3,582 of 6,076 snapshots. Even 900
characters in, a snapshot is still tab titles and "Back to Pinned URL" rather than page text.

This is the ceiling on semantic search. The retrieval verification after building it showed
matched passages like `Footer © 2026 GitHub, Inc. Footer navigation Terms Privacy` — the
index working correctly over material that was never worth indexing. Per-app boilerplate
stripping removes what is common to *most* of an app's snapshots; per-site chrome survives it.
No embedding model fixes bad input.

## Decision

Capture the **web content subtree** instead of the whole window, when one exists.

`AXWebArea` is not speculative here: `BrowserURL.findWebAreaURL` already locates exactly that
role and reads its `AXURL`, and has shipped and worked across nine browsers since S1. This
reuses a proven mechanism for a second purpose.

## Design

1. **Generalise the finder.** `BrowserURL`'s private `findWebAreaURL` becomes
   `findWebArea(_:depth:) -> AXUIElement?`, returning the element. The existing URL lookup is
   re-expressed in terms of it, so there is one finder with two callers rather than twins.
   `BrowserURLTests` continues to cover the URL path unchanged.
2. **Target the walk.** In `captureFrontmost`, after resolving the focused window: if a web
   area is found, run `ScreenContextReader.collectText` from **that element**; otherwise from
   the window root, exactly as today.
3. **Empty web area → skip the snapshot.** If a web area exists but yields no text (a
   lazily-loaded page, a canvas app, a PDF viewer), return nil rather than falling back to the
   window walk. A snapshot that is 100% chrome is worse than no snapshot: it dilutes the index
   and produces precisely the junk results observed above. The 5-second poll retries almost
   immediately, so a still-loading page is captured on the next tick. Logged, so the behaviour
   stays observable rather than silent.

**This is broader than "browsers" despite the framing.** Electron apps — Teams, Slack, VS
Code, Claude — also expose `AXWebArea`, so they benefit with no allowlist and no per-app
knowledge. Genuinely native apps (Xcode, Finder, Notes) find no web area and behave exactly as
they do today.

## Scope

**In:** the targeting change, the shared finder, the empty-web-area skip.

**Out:** chrome-role skipping for native apps and any "largest text subtree" heuristic — both
risk silently dropping real content (an outline is chrome in Xcode's navigator and content in
a Notes document). Revisit only if the measurement below shows browsers were not the bulk of
the problem. Also out: re-capturing existing snapshots — the past cannot be re-read, and old
rows age out under the existing 90-day retention, so the improvement is forward-only.

## Testing

The AX walk needs a live tree, so this is **verified live**, matching the project convention
for `ScreenContextReader`/`WindowSnapshotReader`. No unit test can prove the targeting works;
the existing suite staying green is the regression proof that nothing else moved.

## Exit criterion — a measurement, not a claim

After the change, capture fresh snapshots and re-run the boilerplate analysis on **new rows
only**, comparing against today's baseline of **58% median for Arc**. If that share does not
fall substantially, the change did not work and the native-app options above come back into
scope.

A useful secondary check: re-run a semantic query that previously returned chrome
("Footer © 2026 GitHub, Inc.") and confirm the matched passage is now real page text.
