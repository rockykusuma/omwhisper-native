# Reply Assist Reads the Conversation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reply Assist drafts from the conversation on screen rather than the window's sidebar and tab strip, and the prompt says which app and window it is in.

**Architecture:** The prompt moves out of `AppState` into a pure `ReplyDraftPrompt` so its cap and ordering rules can be asserted. A new `ScreenContextReader.captureConversationText()` prefers the page's web area — the same targeting `WindowSnapshotReader` already uses — and falls back to the whole-window walk for native apps.

**Tech Stack:** Swift 6, Accessibility API, Swift Testing.

## Global Constraints

- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: anything meant to run off the main thread needs an explicit `nonisolated` marker. A missing marker is a real build error, not a warning.
- Build and test with `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test`.
- Suite is at **496 tests in 71 suites** before this work. Every task ends green.
- **`AppState` cannot be constructed in a test** — its initialiser opens the real history and memory stores. Every assertion here runs against pure functions, never `AppState`.
- Xcode groups are file-system-synchronized: creating a `.swift` file on disk is enough. Never hand-edit `project.pbxproj`.
- SourceKit in this project reports false "cannot find X in scope" errors. Only a real `xcodebuild` result counts.
- **The 2,000-character caps do not change.** They exist because 50,000 characters tripped SystemLLM's 5-second timeout live. The win here is what fills those characters.
- **Exclusions must keep applying.** Password managers, private browsing and `.env` are refused by `isExcluded(bundleID:windowTitle:)`; a deliberately-invoked feature is not a reason to read a password manager.
- `Context/ScreenContextReader.swift`'s existing `captureFrontmostWindowText()` is **not** modified — S2's vocabulary path uses it, and engine biasing is measured inert on Apple and Parakeet, so changing it buys nothing and risks a second feature.

---

### Task 1: Extract the prompt so it can be tested

**Files:**
- Create: `omwhisper-native/ReplyAssist/ReplyDraftPrompt.swift`
- Modify: `omwhisper-native/AppState.swift:2080-2118` (delete `windowContextCap`, `fieldTextCap`, `draftStyle`) and `:2051` (the call site)
- Test: `omwhisper-nativeTests/ReplyDraftPromptTests.swift`

**Interfaces:**
- Consumes: `ReplyMode` (`.reply` / `.continueDraft(String)` / `.rewrite(String)`) and `PolishStyle`, both existing.
- Produces: `ReplyDraftPrompt.style(mode:appName:windowTitle:windowContext:tonePrefix:) -> PolishStyle`, plus `ReplyDraftPrompt.contextCap` and `.fieldTextCap` (both `2_000`).

The prompt's most important properties are untested today because `draftStyle` is a `private static` on a type no test can construct.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/ReplyDraftPromptTests.swift`:

```swift
import Testing
@testable import OmWhisper

@Suite("Reply draft prompt")
struct ReplyDraftPromptTests {
    /// Longer than the cap, with a known marker at the very end.
    private func longContext(endingWith marker: String) -> String {
        String(repeating: "old scrollback line. ", count: 400) + marker
    }

    @Test("the newest on-screen text survives the cap")
    func newestContextSurvivesTheCap() {
        // The message being replied to is the LAST thing on screen. A test that
        // only checked "the prompt contains the context" would pass while
        // truncating exactly that away, which is the bug this guards.
        let marker = "MOST-RECENT-MESSAGE-a7f3"
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: "Slack", windowTitle: "#general",
            windowContext: longContext(endingWith: marker), tonePrefix: nil)
        #expect(style.prompt.contains(marker))
    }

    @Test("a continuation keeps the draft's tail, not its head")
    func continuationKeepsTheTail() {
        // Continuing cares about where the sentence got to, not how it opened.
        let draft = String(repeating: "earlier words ", count: 400) + "TAIL-b2c1"
        let style = ReplyDraftPrompt.style(
            mode: .continueDraft(draft), appName: "Mail", windowTitle: "Re: pricing",
            windowContext: nil, tonePrefix: nil)
        #expect(style.prompt.contains("TAIL-b2c1"))
    }

    @Test("a rewrite keeps the selection's head, not its tail")
    func rewriteKeepsTheHead() {
        // Opposite of a continuation, and easy to transpose. A rewrite starts
        // from the beginning of what was selected.
        let selection = "HEAD-d4e5 " + String(repeating: "selected words ", count: 400)
        let style = ReplyDraftPrompt.style(
            mode: .rewrite(selection), appName: "Notes", windowTitle: "Ideas",
            windowContext: nil, tonePrefix: nil)
        #expect(style.prompt.contains("HEAD-d4e5"))
    }

    @Test("the prompt says which app and window it is in")
    func namesTheAppAndWindow() {
        // A reply in Slack and one in Mail should not be framed identically.
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: "Slack", windowTitle: "#eng-releases",
            windowContext: "hey, can you review this?", tonePrefix: nil)
        #expect(style.prompt.contains("Slack"))
        #expect(style.prompt.contains("#eng-releases"))
    }

    @Test("absent app, title and tone render no empty lines")
    func absentFieldsAreOmitted() {
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: nil, windowTitle: nil,
            windowContext: nil, tonePrefix: nil)
        #expect(!style.prompt.contains("App:"))
        #expect(!style.prompt.contains("Window:"))
        #expect(!style.prompt.contains("Writing tone"))
        #expect(!style.prompt.contains("On-screen context"))
    }

    @Test("tone is included when present")
    func toneIncludedWhenPresent() {
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: nil, windowTitle: nil,
            windowContext: nil, tonePrefix: "Short sentences. No exclamation marks.")
        #expect(style.prompt.contains("No exclamation marks"))
    }

    @Test("the style id is stable so stored defaults keep resolving")
    func styleIDIsUnchanged() {
        // Same fixed UUID the inline draftStyle used — hidden styles are
        // referenced by id elsewhere, and changing it would orphan them.
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: nil, windowTitle: nil,
            windowContext: nil, tonePrefix: nil)
        #expect(style.id == UUID(uuidString: "7610B7A2-5DAA-4017-A135-45B67089A0FB")!)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ReplyDraftPrompt' in scope`.

- [ ] **Step 3: Create `ReplyDraftPrompt.swift`**

The instruction text is carried over from `AppState.draftStyle` verbatim, including the
suffix/prefix comments — those record real reasoning and must not be lost in the move.

```swift
//
//  ReplyDraftPrompt.swift
//  OmWhisper
//
//  Assembles the Reply Assist draft prompt. Pure and free of AppState on
//  purpose: this used to be a private static on AppState, which no test can
//  construct (its initialiser opens the real history and memory stores), so the
//  prompt's most important properties -- that the newest on-screen text
//  survives the cap, and that a rewrite and a continuation truncate from
//  opposite ends -- went unasserted.
//

import Foundation

nonisolated enum ReplyDraftPrompt {
    /// ScreenContextReader can return up to 50,000 characters, and the AX-read
    /// draft/selection is equally uncapped -- a focused "field" that is a
    /// document editor yields the whole document. Both are capped because
    /// including that much text tripped SystemLLM's 5s timeout on every draft
    /// (confirmed live: "Polish timed out" against a text-heavy markdown file
    /// in a background window).
    static let contextCap = 2_000
    static let fieldTextCap = 2_000

    static func style(mode: ReplyMode,
                      appName: String?,
                      windowTitle: String?,
                      windowContext: String?,
                      tonePrefix: String?) -> PolishStyle {
        var instructions = "You draft a reply/message for the user, writing AS the user in first person. Respond with ONLY the drafted text -- no preamble, no quotes, no explanation.\n\n"

        switch mode {
        case .reply:
            instructions += "Draft a new reply appropriate to the conversation context below.\n"
        case .continueDraft(let draft):
            // suffix, not prefix -- continuing a draft cares about its most
            // recent tail, not however it started.
            instructions += "Continue this unfinished draft naturally, in the same voice:\n\(draft.suffix(fieldTextCap))\n"
        case .rewrite(let selection):
            instructions += "Rewrite this selected text, keeping its meaning:\n\(selection.prefix(fieldTextCap))\n"
        }

        // Where the user is. Register differs between a team chat and an email
        // thread, and the model cannot tell them apart from body text alone.
        if let appName, !appName.isEmpty { instructions += "\nApp: \(appName)\n" }
        if let windowTitle, !windowTitle.isEmpty { instructions += "Window: \(windowTitle)\n" }

        if let windowContext, !windowContext.isEmpty {
            // suffix, not prefix -- the conversation is read top-down, so the
            // newest message (what you're replying to) is at the BOTTOM.
            // Keeping the head fed the model the oldest scrollback and
            // truncated away the live message.
            instructions += "\nOn-screen context:\n\(windowContext.suffix(contextCap))\n"
        }
        if let tonePrefix, !tonePrefix.isEmpty {
            instructions += "\nWriting tone to match:\n\(tonePrefix)\n"
        }

        return PolishStyle(
            id: UUID(uuidString: "7610B7A2-5DAA-4017-A135-45B67089A0FB")!,
            name: "Reply Draft",
            prompt: instructions,
            isBuiltIn: true
        )
    }
}
```

- [ ] **Step 4: Delete the old prompt from `AppState` and repoint the call site**

In `omwhisper-native/AppState.swift`, delete `windowContextCap`, `fieldTextCap` and the whole
`draftStyle` function (the block from the `/// ScreenContextReader.captureFrontmostWindowText()
can return up to` doc comment through the closing brace of `draftStyle`, around lines
2080-2118), along with their doc comment — it now lives on `ReplyDraftPrompt.contextCap`.

Then change the call site at line 2051 from:

```swift
        let style = Self.draftStyle(mode: mode, windowContext: windowContext, tonePrefix: tonePrefix)
```

to:

```swift
        let style = ReplyDraftPrompt.style(mode: mode, appName: nil, windowTitle: nil,
                                           windowContext: windowContext, tonePrefix: tonePrefix)
```

`appName` and `windowTitle` are nil here and gain real values in Task 2 — this task is the
extraction only, so a reviewer can confirm nothing about the prompt changed except where it
lives.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 503 tests in 72 suites.

Note the `namesTheAppAndWindow` test passes against the new pure function even though the live
call site still passes nil — that is the point of extracting it, and Task 2 connects the wire.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/ReplyAssist/ReplyDraftPrompt.swift \
        omwhisper-native/AppState.swift \
        omwhisper-nativeTests/ReplyDraftPromptTests.swift
git commit -m "♻️ refactor(replyassist): extract the draft prompt so it can be tested

draftStyle was a private static on AppState, which no test can construct
-- its initialiser opens the real history and memory stores. So the
prompt's most important properties went unasserted: that the newest
on-screen text survives the cap, and that a rewrite and a continuation
truncate from OPPOSITE ends.

Behaviour is unchanged. The instruction text and both truncation comments
move verbatim, and the fixed style UUID is pinned by a test because
hidden styles are referenced by id."
```

---

### Task 2: Read the conversation, not the window chrome

**Files:**
- Modify: `omwhisper-native/Context/ScreenContextReader.swift` (add `captureConversationText`, leave `captureFrontmostWindowText` untouched)
- Modify: `omwhisper-native/AppState.swift:2044` (`beginReplyAssist`) and `:2048-2051` (`draftAndStream`)

**Interfaces:**
- Consumes: `ReplyDraftPrompt.style(mode:appName:windowTitle:windowContext:tonePrefix:)` from Task 1; `BrowserURL.findWebArea(_:depth:) -> AXUIElement?` and `ScreenContextReader.collectText`/`copyAttribute`/`isExcluded`, all existing and internal.
- Produces: `ScreenContextReader.ConversationContext` (`nonisolated struct { let appName: String; let windowTitle: String; let text: String? }`) and `ScreenContextReader.captureConversationText(timeBudget:) -> ConversationContext?`.

**No unit tests in this task, deliberately.** Every line is an AX read against a live window;
there is no pure decision to assert, and a test that constructed no real window would pass
whatever the code did. This follows the same convention as `AudioProcesses` — the verification
is the live check at the end of this plan.

- [ ] **Step 1: Add `captureConversationText` to `ScreenContextReader.swift`**

Place it directly after `captureFrontmostWindowText`, which it deliberately does not modify:

```swift
    /// What the user is looking at, for Reply Assist: the page's conversation
    /// rather than the window's furniture.
    ///
    /// Memory hit this first -- its snapshots were "largely sidebar and
    /// tab-strip text" until WindowSnapshotReader started targeting the web
    /// area. Reply Assist reads the same kind of window for the same reason and
    /// never got that fix, so a Slack or Gmail reply was drafted from up to
    /// 2,000 characters of channel list and navigation.
    ///
    /// Differs from Memory in ONE deliberate way: when the web area yields
    /// nothing, this FALLS BACK to the whole-window walk. Memory skips the tick
    /// instead, because "a snapshot that is 100% chrome is worse than no
    /// snapshot, and the 5s poll retries almost immediately" -- neither half of
    /// that holds here. There is no retry, and the user is waiting on a draft.
    ///
    /// nil when there is no frontmost app or focused window, or the app/window
    /// is excluded -- in which case no app name or title is returned either,
    /// since a password manager's window title is not ours to put in a prompt.
    static func captureConversationText(timeBudget: TimeInterval = 0.6) -> ConversationContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        // Not `as?`: the compiler rejects that as dead code ("conditional downcast
        // to CoreFoundation type 'AXUIElement' will always succeed") — CFTypeRef
        // bridging isn't a dynamic class-hierarchy check the way `as!` normally
        // implies, so this can't trap the way a force-cast on a class type could.
        let windowElement = window as! AXUIElement

        let title = (copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        guard !isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }

        let deadline = Date().addingTimeInterval(timeBudget)
        var lines: [String] = []
        var budget = 50_000
        let webArea = BrowserURL.findWebArea(windowElement)
        collectText(webArea ?? windowElement, depth: 0, into: &lines,
                    budget: &budget, deadline: deadline)

        var content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // A web area that yielded nothing means a page mid-load, a canvas app or
        // a PDF viewer. Unlike Memory, fall back rather than give up: the user
        // asked for a draft and is waiting for one.
        if content.isEmpty, webArea != nil {
            lines = []
            budget = 50_000
            collectText(windowElement, depth: 0, into: &lines, budget: &budget, deadline: deadline)
            content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ConversationContext(appName: app.localizedName ?? bundleID,
                                   windowTitle: title,
                                   text: content.isEmpty ? nil : content)
    }
```

And add the return type beside the existing `nonisolated enum ScreenContextReader {` declaration,
above `captureFrontmostWindowText`:

```swift
    /// The frontmost window's identity and readable content.
    nonisolated struct ConversationContext {
        let appName: String
        let windowTitle: String
        /// nil when the window exposed no text at all.
        let text: String?
    }
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -2`
Expected: `** BUILD SUCCEEDED **`.

If it reports `cannot find 'BrowserURL' in scope`, that is SourceKit noise — only a real
`xcodebuild` result counts. `BrowserURL` is in the same target at
`omwhisper-native/Memory/BrowserURL.swift`.

- [ ] **Step 3: Thread the context through `beginReplyAssist`**

In `omwhisper-native/AppState.swift`, replace line 2044:

```swift
        let windowContext = ScreenContextReader.captureFrontmostWindowText()
        await draftAndStream(mode: context.mode, intent: "", windowContext: windowContext, targetPID: targetPID)
```

with:

```swift
        let conversation = ScreenContextReader.captureConversationText()
        await draftAndStream(mode: context.mode, intent: "",
                             conversation: conversation, targetPID: targetPID)
```

- [ ] **Step 4: Use it in `draftAndStream`**

Change the signature and the style call:

```swift
    private func draftAndStream(mode: ReplyMode, intent: String,
                                conversation: ScreenContextReader.ConversationContext?,
                                targetPID: pid_t?) async {
        let tonePrefix = (try? String(contentsOf: ToneProfile.toneFileURL(), encoding: .utf8))
            .map { ToneProfile.promptPrefix(from: $0) }
        let style = ReplyDraftPrompt.style(mode: mode,
                                           appName: conversation?.appName,
                                           windowTitle: conversation?.windowTitle,
                                           windowContext: conversation?.text,
                                           tonePrefix: tonePrefix)
```

Leave the rest of the function — backend selection, the frontmost-PID guard, the typist call and
the sentinel handling — exactly as it is.

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 503 tests. No new tests — see the note under this task's
Interfaces.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Context/ScreenContextReader.swift omwhisper-native/AppState.swift
git commit -m "🐛 fix(replyassist): draft from the conversation, not the window chrome

Reply Assist read the whole window, so a Slack or Gmail reply was drafted
from up to 2,000 characters that were substantially channel lists, nav
and tab strips. Memory hit exactly this and was fixed on 2026-08-01 to
target the web area; Reply Assist never got that fix.

It also silently broke correct reasoning: the prompt takes the SUFFIX
because a chat's newest message is at the bottom, which is true of a
conversation and not of a window whose tail may be a sidebar.

Falls back to the window walk when the web area is empty -- the opposite
of Memory's choice, and for a stated reason: Memory skips the tick
because its 5s poll retries almost immediately, and neither half of that
holds when a user is waiting on a draft.

The prompt now also names the app and window. Both were available at the
call site and both were discarded, so a reply in Slack and one in Mail
were framed identically."
```

---

## Live verification

The unit tests cover the prompt; the capture is only provable against real windows. Each of
these can come back negative.

1. **The check that matters — a browser or Electron reply.** Open a Slack or Gmail thread, click
   into the reply box, double-tap right ⌥. **Does the draft reference the actual last message?**
   Today it frequently cannot, because that message may not be in the 2,000 characters at all.
   Compare against a draft from the installed 2.0.8 build in the same thread — that is the
   before/after, and it is the whole point of this change.
2. **A native app is unchanged.** Repeat in Mail or Messages, which expose no web area. The draft
   should be no worse than today: this exercises the fallback path.
3. **A page that exposes an empty web area.** A PDF in a browser tab, or a page mid-load. The
   draft should still be attempted from the window walk rather than failing — the deliberate
   difference from Memory's behaviour.
4. **An excluded app contributes nothing.** With a password manager frontmost, double-tap. No
   window title or app name should reach the model; the draft proceeds on mode alone or reports
   that it could not read the field.
5. **Continuation and rewrite still behave.** Type half a sentence and double-tap (should
   continue it); select a sentence and double-tap (should rewrite it). Both paths changed file
   but not logic, and this confirms the move was clean.

## Out of scope

Memory grounding · intent capture · drafting feedback or a HUD · per-app output shaping ·
raising the 2,000-character caps · changing which backend drafts · the typing path · the
double-tap trigger · `captureFrontmostWindowText` and the S2 vocabulary path that uses it.
