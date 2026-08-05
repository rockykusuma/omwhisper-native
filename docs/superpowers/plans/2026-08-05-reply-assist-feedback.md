# Reply Assist Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-tapping right ⌥ shows a DRAFTING HUD immediately, and each of Reply Assist's five failure paths shows a capsule naming its cause instead of ending in silence.

**Architecture:** `OverlayPhase` gains a `.drafting` case; `OverlayView.isVisible` moves from a private computed property to a testable `nonisolated static` and gains the `.error` case it is missing. A pure `ReplyAssistFailure` enum owns the five causes, their HUD labels and their existing messages.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

## Global Constraints

- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: anything meant to run off the main thread needs an explicit `nonisolated` marker. A missing marker is a real build error, not a warning.
- Build and test with `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test`.
- Suite is at **503 tests in 72 suites** before this work. Every task ends green.
- **`AppState` cannot be constructed in a test** — its initialiser opens the real history and memory stores. Every assertion here runs against pure functions.
- Xcode groups are file-system-synchronized: creating a `.swift` file on disk is enough. Never hand-edit `project.pbxproj`.
- SourceKit in this project reports false "cannot find X in scope" errors. Only a real `xcodebuild` result counts.
- **The HUD must never take focus.** It is a non-activating, click-through `NSPanel`; the original Reply Assist panel was removed precisely because it stole focus. Nothing here may reintroduce that — no `NSApp.activate`, no key window.
- **Labels are short and uppercase**, matching the existing register: `NOTHING HEARD`, `SOMETHING BROKE — TEXT COPIED`.
- This branch (`reply-assist-conversation`) already carries sub-project 1. Do not change what Reply Assist drafts — only what it shows.

---

### Task 1: The overlay can show a draft, and can show an error at all

**Files:**
- Modify: `omwhisper-native/AppState.swift:70-76` (`OverlayPhase`)
- Modify: `omwhisper-native/UI/OverlayView.swift:25-31` (`showsTranscript`), `:36-38` (`isVisible`), `:106-122` (`statusLabel`), `:124-131` (`labelColor`)
- Test: `omwhisper-nativeTests/OverlayStyleTests.swift`

**Interfaces:**
- Consumes: `OverlayPhase`, `DictationState`, both existing.
- Produces: `OverlayPhase.drafting`, and `OverlayView.isVisible(dictation:phase:isPreview:) -> Bool` as a `nonisolated static`.

The `.error` omission in the visibility rule is the load-bearing fix: without it, Task 2 sets
error phases that render nothing and the whole feature looks complete while changing nothing
observable.

- [ ] **Step 1: Write the failing tests**

Add to `omwhisper-nativeTests/OverlayStyleTests.swift`, inside a new suite at the end of the file:

```swift
@Suite("Overlay visibility")
struct OverlayVisibilityTests {
    @Test("an error is visible with no dictation running — the bug")
    func errorVisibleWhenIdle() {
        // Reply Assist runs entirely at .idle. The old rule admitted .polishing
        // but not .error, so every Reply Assist failure rendered nothing at all
        // and the user could not tell "working" from "failed".
        #expect(OverlayView.isVisible(dictation: .idle,
                                      phase: .error(label: "NO TEXT FIELD"),
                                      isPreview: false))
    }

    @Test("a draft in flight is visible with no dictation running")
    func draftingVisibleWhenIdle() {
        #expect(OverlayView.isVisible(dictation: .idle, phase: .drafting, isPreview: false))
    }

    @Test("idle with nothing happening stays hidden")
    func idleStaysHidden() {
        // Guards against "fixing" the above by making the HUD permanent.
        #expect(!OverlayView.isVisible(dictation: .idle, phase: .none, isPreview: false))
    }

    @Test("polishing and a live dictation are unchanged")
    func existingCasesUnchanged() {
        #expect(OverlayView.isVisible(dictation: .idle, phase: .polishing, isPreview: false))
        for state in [DictationState.starting, .recording, .finalizing] {
            #expect(OverlayView.isVisible(dictation: state, phase: .none, isPreview: false),
                    "\(state) should show the HUD")
        }
    }

    @Test("a settings preview is always visible")
    func previewAlwaysVisible() {
        // Matches showsTranscript's existing contract.
        #expect(OverlayView.isVisible(dictation: .idle, phase: .none, isPreview: true))
    }

    @Test("a draft shows no transcript — those fields hold the LAST dictation")
    func draftingHidesStaleTranscript() {
        // Same reason Polish Selected suppresses it: dictation stays .idle, so
        // finalizedTranscript still holds whatever was dictated before. Without
        // this the DRAFTING HUD displays the previous dictation's words.
        #expect(!OverlayView.showsTranscript(dictation: .idle, phase: .drafting, isPreview: false))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head -4`
Expected: `type 'OverlayPhase' has no member 'drafting'` and `type 'OverlayView' has no member 'isVisible'`.

- [ ] **Step 3: Add the `.drafting` case**

In `omwhisper-native/AppState.swift`, add to `OverlayPhase` (around line 70):

```swift
nonisolated enum OverlayPhase: Equatable {
    case none
    case pasting
    case polishing               // Smart Dictation / Polish Selected Text running the active style
    case drafting                // Reply Assist composing a reply
    case error(label: String)   // "NOTHING HEARD" | "SOMETHING BROKE — TEXT COPIED"
    case cancelled
}
```

A separate case rather than reusing `.polishing`: the overlay is the app's face, and
"POLISHING" would be shown on every draft while not being true.

- [ ] **Step 4: Extract and fix `isVisible`**

In `omwhisper-native/UI/OverlayView.swift`, replace the private computed property at lines 36-38:

```swift
    private var isVisible: Bool {
        appState.dictation != .idle || appState.overlayPhase == .polishing || appState.overlayPreview != nil
    }
```

with a call to a testable static, plus the static itself placed beside `showsTranscript`:

```swift
    /// Whether the HUD shows at all.
    ///
    /// `.error` was missing here, and that was a real bug rather than an
    /// oversight of style: Reply Assist runs entirely at `dictation == .idle`,
    /// so every one of its failures set an error phase that rendered nothing.
    /// Extracted from a private computed property for the same reason
    /// showsTranscript was -- a private var on a View cannot be asserted, and
    /// AppState cannot be constructed in a test.
    nonisolated static func isVisible(
        dictation: DictationState, phase: OverlayPhase, isPreview: Bool
    ) -> Bool {
        if isPreview { return true }
        if dictation != .idle { return true }
        switch phase {
        case .polishing, .drafting, .error: return true
        case .none, .pasting, .cancelled: return false
        }
    }

    private var isVisible: Bool {
        OverlayView.isVisible(dictation: appState.dictation,
                              phase: appState.overlayPhase,
                              isPreview: appState.overlayPreview != nil)
    }
```

- [ ] **Step 5: Suppress the stale transcript while drafting**

`showsTranscript` at lines 25-31 currently ends with `return phase != .polishing`. A `.drafting`
phase would otherwise display the previous dictation's text. Change that line to:

```swift
        return phase != .polishing && phase != .drafting
```

- [ ] **Step 6: Label and colour the drafting phase**

In `FullStyleOverlay.statusLabel` (around line 110), add a case beside `.polishing`:

```swift
        case .drafting:
            return "DRAFTING"
```

And in `labelColor` (around line 126), treat it like polishing:

```swift
        if case .drafting = appState.overlayPhase { return .omTeal }
```

Build and let the compiler find any remaining non-exhaustive switches over `OverlayPhase`; add
`.drafting` to each alongside `.polishing`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 509 tests in 73 suites.

- [ ] **Step 8: Prove the visibility test can fail**

Temporarily remove `.error` from the `case .polishing, .drafting, .error: return true` line, run
only that suite, and confirm `errorVisibleWhenIdle` fails. Restore it.

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/OverlayVisibilityTests test 2>&1 | grep -E "error is visible|TEST (SUCCEEDED|FAILED)"`
Expected while removed: the test fails. A guard that cannot fail is not a guard.

- [ ] **Step 9: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/UI/OverlayView.swift \
        omwhisper-nativeTests/OverlayStyleTests.swift
git commit -m "🐛 fix(overlay): an error phase was invisible with no dictation running

isVisible admitted .polishing but not .error, and Reply Assist runs
entirely at dictation == .idle -- so every one of its failures set a
phase that rendered nothing. Setting error phases without this fix would
have looked complete while changing nothing observable.

Extracted to a testable static, the same treatment showsTranscript got,
because a private computed property on a View cannot be asserted and
AppState cannot be constructed in a test. Confirmed the guard fails when
.error is removed again.

Adds a .drafting phase for Reply Assist rather than reusing .polishing,
which would show a word that is not true on every draft -- and suppresses
the transcript during it, since dictation stays idle and those fields
still hold the LAST dictation."
```

---

### Task 2: Reply Assist shows what it is doing

**Files:**
- Create: `omwhisper-native/ReplyAssist/ReplyAssistFailure.swift`
- Modify: `omwhisper-native/AppState.swift` (`beginReplyAssist` and `draftAndStream`)
- Test: `omwhisper-nativeTests/ReplyAssistFailureTests.swift`

**Interfaces:**
- Consumes: `OverlayPhase.drafting` and `OverlayView.isVisible` from Task 1.
- Produces: `ReplyAssistFailure` (`nonisolated enum` with cases `.noTextField`, `.noBackend`, `.draftFailed(String)`, `.focusChanged`, `.sentinelDeclined`), each with `.overlayLabel: String` and `.message: String`.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/ReplyAssistFailureTests.swift`:

```swift
import Testing
@testable import OmWhisper

@Suite("Reply Assist failures")
struct ReplyAssistFailureTests {
    private let all: [ReplyAssistFailure] = [
        .noTextField, .noBackend, .draftFailed("timed out"), .focusChanged, .sentinelDeclined
    ]

    @Test("every failure has a non-empty label")
    func everyFailureHasALabel() {
        // An empty label renders an invisible capsule — the exact silent
        // failure this whole change exists to remove.
        for failure in all {
            #expect(!failure.overlayLabel.isEmpty, "\(failure) has no label")
        }
    }

    @Test("labels are short enough for the capsule and match the house register")
    func labelsAreShortAndUppercase() {
        // The capsule is minWidth 180 at 11pt; long labels wrap or clip. The
        // existing labels are "NOTHING HEARD" and "SOMETHING BROKE — TEXT COPIED".
        for failure in all {
            #expect(failure.overlayLabel.count <= 24, "\(failure.overlayLabel) is too long")
            #expect(failure.overlayLabel == failure.overlayLabel.uppercased(),
                    "\(failure.overlayLabel) is not uppercase")
        }
    }

    @Test("each cause is distinguishable — the point of naming them")
    func labelsAreDistinct() {
        // One shared "SOMETHING WENT WRONG" would pass the tests above while
        // leaving the user unable to tell a missing field from a dead backend.
        let labels = all.map(\.overlayLabel)
        #expect(Set(labels).count == labels.count)
    }

    @Test("the underlying error text is carried in the message, not the label")
    func draftFailedCarriesItsReason() {
        // The label stays short; the detail belongs in errorMessage, which will
        // be useful the day that channel is connected.
        #expect(ReplyAssistFailure.draftFailed("Ollama timed out").message.contains("Ollama timed out"))
        #expect(!ReplyAssistFailure.draftFailed("Ollama timed out").overlayLabel.contains("Ollama"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ReplyAssistFailure' in scope`.

- [ ] **Step 3: Create `ReplyAssistFailure.swift`**

```swift
//
//  ReplyAssistFailure.swift
//  OmWhisper
//
//  The five ways a reply draft can fail, each with the short label the overlay
//  shows and the longer message AppState records.
//
//  One type rather than five scattered string literals because the user needs
//  to tell them APART: "no text field" and "no AI backend" are both fixable in
//  seconds if named, and indistinguishable if not.
//

import Foundation

nonisolated enum ReplyAssistFailure: Equatable {
    case noTextField
    case noBackend
    case draftFailed(String)
    case focusChanged
    case sentinelDeclined

    /// Short, uppercase, capsule-sized -- matching "NOTHING HEARD".
    var overlayLabel: String {
        switch self {
        case .noTextField:     return "NO TEXT FIELD"
        case .noBackend:       return "NO AI BACKEND"
        case .draftFailed:     return "DRAFT FAILED"
        case .focusChanged:    return "FOCUS CHANGED"
        case .sentinelDeclined: return "DRAFT LOOKED WRONG"
        }
    }

    /// The detail. Kept out of the label, which has to stay short.
    var message: String {
        switch self {
        case .noTextField:
            return "Reply assist: couldn't read the focused field."
        case .noBackend:
            return "Reply assist needs an AI polish backend enabled in AI settings."
        case .draftFailed(let reason):
            return "Reply assist: draft failed (\(reason))."
        case .focusChanged:
            return "Reply assist: focus changed, nothing was typed."
        case .sentinelDeclined:
            return "Reply assist: the draft looked like an error, nothing was typed."
        }
    }
}
```

- [ ] **Step 4: Add a single failure path to `AppState`**

Add this private helper next to `beginReplyAssist` in `omwhisper-native/AppState.swift`:

```swift
    /// Show the cause in the HUD, record it, and clear after a beat. One path so
    /// no failure can be added later that forgets to surface itself.
    private func failReplyAssist(_ failure: ReplyAssistFailure) async {
        errorMessage = failure.message
        overlayPhase = .error(label: failure.overlayLabel)
        overlay.show(appState: self)
        try? await Task.sleep(for: .milliseconds(2200))
        overlay.hide()
        overlayPhase = .none
    }
```

- [ ] **Step 5: Show the HUD from `beginReplyAssist`**

In `beginReplyAssist`, immediately after the `isReplyAssistDrafting = true` / `defer` lines and
**before** `refreshToneProfileIfStale()`, add:

```swift
        // Instant acknowledgement. AX resolution alone can take ~1.6s on
        // Electron trees, so showing this after it would answer the wrong
        // question. The HUD is non-activating and click-through, so it cannot
        // take focus from the field being replied into.
        overlayPhase = .drafting
        overlay.show(appState: self)
```

Extend the existing `defer` so the HUD cannot outlive the draft on any exit path:

```swift
        defer {
            isReplyAssistDrafting = false
            overlay.hide()
            overlayPhase = .none
        }
```

Then replace the `guard let context` failure with the new path:

```swift
        guard let context = await ReplyContextReader.currentContext() else {
            await failReplyAssist(.noTextField)
            return
        }
```

- [ ] **Step 6: Route the remaining failures in `draftAndStream`**

Replace the three `errorMessage = ...; return` blocks with the shared path. The backend guard:

```swift
        guard let backend = activePolishBackend() else {
            await failReplyAssist(.noBackend)
            return
        }
```

The draft failure:

```swift
        } catch {
            log.error("draftAndStream — polish failed: \(error)")
            await failReplyAssist(.draftFailed(error.localizedDescription))
            return
        }
```

The focus guard:

```swift
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            log.warning("draftAndStream — frontmost app changed before typing; aborting")
            await failReplyAssist(.focusChanged)
            return
        }
```

And the sentinel result:

```swift
        if case .declinedSentinel(let sentinel) = result {
            log.warning("draftAndStream — declined on sentinel: \(sentinel)")
            await failReplyAssist(.sentinelDeclined)
        }
```

- [ ] **Step 7: Hide the HUD before typing starts**

Still in `draftAndStream`, immediately **before** `let result = await replyStreamTypist.stream(drafted)`:

```swift
        // The arriving text is the success signal; a "DRAFTED" beat would be
        // noise by the fortieth use. Hidden here rather than in the defer so it
        // is gone before the first keystroke lands.
        overlay.hide()
        overlayPhase = .none
```

The `defer` in `beginReplyAssist` still runs and is harmless — hiding an already-hidden panel is
a no-op.

- [ ] **Step 8: Check whether Polish Selected Text has the same hole**

Read `runPolishSelectedText` (around `AppState.swift:1763`). It calls `polishedText(for:)`, which
by M3's design **never throws** — every failure falls back to the original text, which is then
pasted. If that is still true, Polish Selected Text has no error path to surface and needs no
change; record that in the commit message rather than inventing one. If it *can* fail visibly,
route it through `overlayPhase = .error(...)` the same way.

- [ ] **Step 9: Run the tests**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 513 tests in 74 suites.

- [ ] **Step 10: Commit**

```bash
git add omwhisper-native/ReplyAssist/ReplyAssistFailure.swift omwhisper-native/AppState.swift \
        omwhisper-nativeTests/ReplyAssistFailureTests.swift
git commit -m "✨ feat(replyassist): show that a draft is in flight, and why one failed

Double-tapping produced nothing observable for several seconds -- AX
resolution up to ~1.6s plus the model call -- and all five failure paths
ended in silence, because they set errorMessage and AppState.errorMessage
is read by no view.

A DRAFTING HUD now appears immediately, before AX resolution, so the
acknowledgement answers the right question. It is hidden before the first
keystroke: the arriving text is the success signal, and a beat after it
would be noise by the fortieth use.

Each failure names its cause. ReplyAssistFailure owns the five, so no
future one can be added that forgets to surface itself, and a test pins
that the labels stay distinct -- a single SOMETHING WENT WRONG would pass
every other assertion while leaving a missing field and a dead backend
indistinguishable."
```

---

## Live verification

Reply Assist is currently **off** in settings — turn it on first. Each check can come back
negative.

1. **Double-tap in a text field** → the DRAFTING HUD appears immediately, not after a pause, and
   is gone as the text starts arriving.
2. **The HUD does not steal focus** — the caret stays in the field, and the drafted text lands
   there. This is the property the original panel violated, and the reason it was deleted.
3. **Double-tap with nothing focused** (click the desktop first) → `NO TEXT FIELD`.
4. **Double-tap, then immediately click another app** → `FOCUS CHANGED`, and nothing is typed
   into either app.
5. **Set AI Polish to Disabled and double-tap** → `NO AI BACKEND`.
6. **A second double-tap mid-draft still cancels**, and the HUD clears rather than being left on
   screen — the `defer` covers it, and this confirms it.

## Out of scope

Intent capture · memory grounding · per-app shaping · a success beat · a cancel affordance in the
HUD · connecting `AppState.errorMessage` app-wide · anything that changes what Reply Assist
drafts.
