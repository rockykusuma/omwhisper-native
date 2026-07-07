# S4 — Reply Assist, Voice-First Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-tap right ⌥ in any text field to draft a reply, continue a draft, or rewrite a selection — silently from window context, or by holding to speak intent. Drafted text streams into the field via synthesized keystrokes. Off by default.

**Architecture:** New `ReplyAssist/` group: `DoubleTapDetector` (pure state machine) → `ReplyAssistMonitor` (NSEvent flagsChanged, right-⌥-only) → `ReplyContextReader` (AX focused-element read + reply/continue/rewrite classification) → `ReplyStreamTypist` (synthesized-keystroke streaming, sentinel-checked) → `ToneProfile` (tone.md distilled from `HistoryStore`, not screen capture). `ReplyAssistPanel` (new `NSPanel`) is the UI; `AppState` wires it all together and owns a scoped voice-capture method reusing the existing `audioCapture`/`engine`.

**Tech Stack:** Swift 6, AppKit (`NSEvent`, `AXUIElement`, `CGEvent`), GRDB (`HistoryStore` read), Swift Testing.

## Global Constraints

- Off by default: `AppState.replyAssistEnabled` defaults to `false`. `ReplyAssistMonitor` is not instantiated or started unless this is on.
- `ReplyAssistMonitor` must be suppressed entirely whenever `AppState.dictation != .idle` — matches `MeetingWatcher.isSuppressed`'s contract exactly.
- No redaction in this ship — `PolishBackend.polish(...)` only reaches `SystemLLM` (on-device) today. Deferred to M3 sub-project 2.
- `tone.md` is sourced from `HistoryStore.fetchPage(offset:limit:)`, not screen captures.
- Escape cancels a pending draft/stream; already-typed characters are never rolled back, only pending text is dropped.
- The first `bufferThreshold` (24) characters of any drafted text are checked against known failure sentinels before any character is typed — see Task 4.
- `ReplyAssistPanel` is positioned like `MeetingConsentPanel` (fixed screen corner) — not cursor-relative.
- Real, verified API surface only. The AX focused-element fallback chain in Task 3 and the synthesized-keystroke streaming in Task 4 are ported directly from `/Users/rakeshkusuma/Documents/PersonalProjects/smriti`'s `AssistListener.swift` (same author, MIT, read-only reference) — not guessed.
- `PolishBackend.polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String`: `style.prompt` becomes the LLM's system instructions; `text` is the user message the model responds to (confirmed in `SystemLLM.swift:32-39`). Every new `PolishStyle` this plan constructs is a fixed-UUID, `isBuiltIn: true`, internal style — never shown in the AI settings tab's user-facing style picker.

---

### Task 1: `DoubleTapDetector`

**Files:**
- Create: `omwhisper-native/ReplyAssist/DoubleTapDetector.swift`
- Test: `omwhisper-nativeTests/DoubleTapDetectorTests.swift`

**Interfaces:**
- Produces: `nonisolated struct DoubleTapDetector { init(window: TimeInterval = 0.45); mutating func tapDetected(at time: TimeInterval) -> Bool; mutating func interrupt() }` — pure, no AX/CGEvent/NSEvent dependency. Consumed by Task 2.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OmWhisper

@Suite("DoubleTapDetector")
struct DoubleTapDetectorTests {
    @Test("two taps within the window fire a double-tap")
    func withinWindow() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        #expect(detector.tapDetected(at: 0.2) == true)
    }

    @Test("two taps beyond the window do not fire")
    func beyondWindow() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        #expect(detector.tapDetected(at: 0.5) == false)
    }

    @Test("a third tap right after a fired pair starts a fresh pending single, not a re-fire")
    func tripleTapFiresOnceThenRestarts() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        #expect(detector.tapDetected(at: 0.1) == true)   // fires once
        #expect(detector.tapDetected(at: 0.2) == false)  // starts a new pending single
        #expect(detector.tapDetected(at: 0.35) == true)  // pairs with the tap at 0.2
    }

    @Test("interrupt clears a pending single so the next tap starts fresh")
    func interruptClearsPending() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        detector.interrupt()
        #expect(detector.tapDetected(at: 0.1) == false)  // would have fired without interrupt()
    }

    @Test("a tap exactly at the window boundary still fires")
    func exactBoundaryFires() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        #expect(detector.tapDetected(at: 0.45) == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/DoubleTapDetectorTests 2>&1 | tail -30`
Expected: FAIL — `DoubleTapDetector` doesn't exist yet.

- [ ] **Step 3: Implement `DoubleTapDetector`**

```swift
//
//  DoubleTapDetector.swift
//  OmWhisper
//
//  Pure double-tap timing state machine, ported from smriti's AssistListener.swift
//  (same author, MIT, read-only reference). No AX/CGEvent/NSEvent dependency --
//  ReplyAssistMonitor decides WHEN to call tapDetected(at:)/interrupt(), this
//  type only tracks the timing window between two calls.
//

import Foundation

nonisolated struct DoubleTapDetector {
    let window: TimeInterval
    private var lastTapAt: TimeInterval?

    init(window: TimeInterval = 0.45) {
        self.window = window
    }

    /// Returns true if `time` completes a double-tap with the immediately
    /// preceding call. Consumes the pair on a fire, so a rapid triple-tap
    /// fires once (on the 2nd tap) and the 3rd tap becomes a fresh pending
    /// single rather than re-firing immediately.
    mutating func tapDetected(at time: TimeInterval) -> Bool {
        if let lastTapAt, time - lastTapAt <= window {
            self.lastTapAt = nil
            return true
        }
        lastTapAt = time
        return false
    }

    /// Clears any pending single tap -- called when a different key/modifier
    /// is pressed, so e.g. ⌥4→€ or a held Cmd/Ctrl/Shift never counts as part
    /// of a future double-tap pair.
    mutating func interrupt() {
        lastTapAt = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/DoubleTapDetectorTests 2>&1 | tail -30`
Expected: PASS, 5/5.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/ReplyAssist/DoubleTapDetector.swift omwhisper-nativeTests/DoubleTapDetectorTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(reply-assist): add DoubleTapDetector" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 2: `ReplyAssistMonitor`

**Files:**
- Create: `omwhisper-native/ReplyAssist/ReplyAssistMonitor.swift`

**Interfaces:**
- Consumes: `DoubleTapDetector` (Task 1).
- Produces: `@MainActor final class ReplyAssistMonitor { var onTriggered: (() -> Void)?; var isSuppressed: () -> Bool; func start(); func stop() }`. Consumed by Task 6 (`AppState` wiring).

No unit test for this task — it's pure NSEvent-monitor wiring around an already-tested pure detector, exactly like `PushToTalkMonitor` has no test file of its own. Covered by live verification in Task 7.

- [ ] **Step 1: Implement `ReplyAssistMonitor`**

```swift
//
//  ReplyAssistMonitor.swift
//  OmWhisper
//
//  Detects a double-tap of the RIGHT Option key anywhere (global) or while
//  OmWhisper itself is frontmost (local), and fires onTriggered. Modeled
//  directly on PushToTalkMonitor.swift's NSEvent.flagsChanged monitor pattern
//  -- NOT smriti's 30ms CGEventSource polling, which exists there specifically
//  because smriti runs as a launchd-spawned daemon ("event taps and NSEvent
//  global monitors are unreliable for launchd-spawned agents"). OmWhisper is a
//  normal app bundle; PushToTalkMonitor already proves NSEvent monitors work
//  reliably here for exactly this kind of modifier-only gesture.
//
//  Right vs. left Option is distinguished via NSEvent.keyCode (61 = right
//  Option) -- the higher-level API this app already relies on, simpler than
//  smriti's raw NX_DEVICERALTKEYMASK device-bit check.
//
//  Requires Accessibility trust for the global monitor, like PushToTalkMonitor
//  and GlobalHotkey -- no new permission burden.
//

import AppKit

@MainActor
final class ReplyAssistMonitor {
    private static let rightOptionKeyCode: UInt16 = 61

    var onTriggered: (() -> Void)?
    /// Checked before firing onTriggered -- AppState sets this to
    /// `{ self.dictation != .idle }`, matching MeetingWatcher.isSuppressed's
    /// contract exactly: a double-tap during dictation must never even
    /// register as a pending trigger, not just be ignored downstream.
    var isSuppressed: () -> Bool = { false }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var isRightOptionDown = false
    private var detector = DoubleTapDetector()

    func start() {
        stop()
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        // Any regular keystroke (e.g. the "4" in ⌥4→€) interrupts a pending
        // tap so it's never mistaken for the second half of a double-tap.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.detector.interrupt()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.detector.interrupt()
            return event
        }
    }

    func stop() {
        for monitor in [globalFlagsMonitor, localFlagsMonitor, globalKeyMonitor, localKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        isRightOptionDown = false
        detector.interrupt()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let isDown = event.modifierFlags.contains(.option)
        guard isDown != isRightOptionDown else { return }
        isRightOptionDown = isDown
        guard isDown else { return }  // only the press counts as a tap, not the release
        // Cmd/Ctrl/Shift held alongside right-⌥ means this is part of some
        // other shortcut, not a reply-assist trigger -- and it interrupts any
        // pending pair rather than silently ignoring it.
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.shift) else {
            detector.interrupt()
            return
        }
        guard detector.tapDetected(at: event.timestamp) else { return }
        guard !isSuppressed() else { return }
        onTriggered?()
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/ReplyAssist/ReplyAssistMonitor.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(reply-assist): add ReplyAssistMonitor (right-⌥ double-tap)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 3: `ReplyContext` + `ReplyContextReader`

**Files:**
- Create: `omwhisper-native/ReplyAssist/ReplyContext.swift`
- Test: `omwhisper-nativeTests/ReplyContextClassificationTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum ReplyMode: Equatable {
      case reply
      case continueDraft(String)
      case rewrite(String)
  }
  nonisolated struct ReplyContext { let mode: ReplyMode }
  nonisolated enum ReplyContextReader {
      static func classify(value: String?, placeholder: String?, selection: String?) -> ReplyMode
      @MainActor static func focusedElement(maxRetries: Int = 8, retryDelay: Duration = .milliseconds(200)) async -> AXUIElement?
      @MainActor static func currentContext() async -> ReplyContext?
  }
  ```
  Consumed by Task 6 (`AppState`/`ReplyAssistPanel` wiring).

Only `classify` is pure/unit-testable — `focusedElement`/`currentContext` are AX-dependent, covered by live verification in Task 7, matching how `ScreenContextReader.captureFrontmostWindowText` has no unit test either.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OmWhisper

@Suite("ReplyContextReader.classify")
struct ReplyContextClassificationTests {
    @Test("empty field with no placeholder -> reply")
    func emptyNoPlaceholder() {
        #expect(ReplyContextReader.classify(value: nil, placeholder: nil, selection: nil) == .reply)
        #expect(ReplyContextReader.classify(value: "", placeholder: nil, selection: nil) == .reply)
    }

    @Test("empty field whose AX value mirrors its placeholder -> reply, not continueDraft")
    func placeholderMistakenForValue() {
        let mode = ReplyContextReader.classify(value: "Type a message...", placeholder: "Type a message...", selection: nil)
        #expect(mode == .reply)
    }

    @Test("non-empty draft with a different placeholder -> continueDraft")
    func realDraft() {
        let mode = ReplyContextReader.classify(value: "Hey, just wanted to say", placeholder: "Type a message...", selection: nil)
        #expect(mode == .continueDraft("Hey, just wanted to say"))
    }

    @Test("selection over 3 chars -> rewrite, even with a non-empty draft present")
    func selectionWins() {
        let mode = ReplyContextReader.classify(value: "some draft text", placeholder: nil, selection: "please rewrite this part")
        #expect(mode == .rewrite("please rewrite this part"))
    }

    @Test("selection of 3 chars or fewer does not trigger rewrite")
    func tinySelectionIgnored() {
        let mode = ReplyContextReader.classify(value: nil, placeholder: nil, selection: "hi")
        #expect(mode == .reply)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/ReplyContextClassificationTests 2>&1 | tail -30`
Expected: FAIL — `ReplyContextReader` doesn't exist yet.

- [ ] **Step 3: Implement `ReplyContext.swift`**

```swift
//
//  ReplyContext.swift
//  OmWhisper
//
//  Classifies the focused text field into reply/continue/rewrite, and
//  resolves that focused element via AX. Focused-element resolution and the
//  placeholder-vs-value gotcha are ported directly from smriti's
//  AssistListener.swift (same author, MIT, read-only reference) -- both are
//  hard-won against real Electron/web app behavior, not guessed:
//
//  - Web/Electron fields return their placeholder text as the AX *value*
//    when the field is actually empty. classify() strips a value that
//    exactly matches the placeholder before deciding the mode, or an empty
//    field gets mistaken for a non-empty draft.
//  - Electron/Chromium apps report NoValue for kAXFocusedUIElementAttribute
//    until their accessibility tree is switched on -- flipping
//    AXManualAccessibility/AXEnhancedUserInterface and retrying (big trees
//    like Claude/Teams can take over a second) is required, not optional.
//
//  Concurrency: focusedElement()/currentContext() are @MainActor (AXUIElement
//  calls have no documented off-main-thread guarantee, unlike the
//  NSWorkspace-only reads in ScreenContextReader), and use Task.sleep instead
//  of smriti's blocking usleep so the retry loop never freezes the app.
//

import AppKit
import ApplicationServices

nonisolated enum ReplyMode: Equatable {
    case reply
    case continueDraft(String)
    case rewrite(String)
}

nonisolated struct ReplyContext {
    let mode: ReplyMode
}

nonisolated enum ReplyContextReader {
    static func classify(value: String?, placeholder: String?, selection: String?) -> ReplyMode {
        if let selection, selection.count > 3 {
            return .rewrite(selection)
        }
        let effectiveValue: String?
        if let value, let placeholder, value == placeholder {
            effectiveValue = nil
        } else {
            effectiveValue = value
        }
        if let effectiveValue, !effectiveValue.isEmpty {
            return .continueDraft(effectiveValue)
        }
        return .reply
    }

    @MainActor
    static func currentContext() async -> ReplyContext? {
        guard let element = await focusedElement() else { return nil }
        let value = axStringValue(element, kAXValueAttribute as String)
        let placeholder = axStringValue(element, kAXPlaceholderValueAttribute as String)
        let selection = axStringValue(element, kAXSelectedTextAttribute as String)
        return ReplyContext(mode: classify(value: value, placeholder: placeholder, selection: selection))
    }

    @MainActor
    static func focusedElement(maxRetries: Int = 8, retryDelay: Duration = .milliseconds(200)) async -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let focused = copyElement(appElement, kAXFocusedUIElementAttribute as String) {
            return focused
        }

        // The system-wide element often reports focus when the per-app query
        // returns NoValue (some Electron builds).
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = copyElement(systemWide, kAXFocusedUIElementAttribute as String) {
            return focused
        }

        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        for _ in 0..<maxRetries {
            try? await Task.sleep(for: retryDelay)
            if let focused = copyElement(appElement, kAXFocusedUIElementAttribute as String)
                ?? copyElement(systemWide, kAXFocusedUIElementAttribute as String) {
                return focused
            }
        }

        // Last resort: walk the focused window for the element that claims
        // keyboard focus (AXFocused == true).
        if let window = copyElement(appElement, kAXFocusedWindowAttribute as String),
           let focused = findFocusDescendant(window, depth: 0) {
            return focused
        }
        return nil
    }

    private static func findFocusDescendant(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if let focused = copyAttribute(element, kAXFocusedAttribute as String) as? Bool, focused,
           isEditable(element) {
            return element
        }
        guard let children = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findFocusDescendant(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        let role = (copyAttribute(element, kAXRoleAttribute as String) as? String) ?? ""
        if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole {
            return true
        }
        // Web content (e.g. LinkedIn comment boxes) often reports a generic
        // role but still supports selected-text editing.
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return settable.boolValue
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axStringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/ReplyContextClassificationTests 2>&1 | tail -30`
Expected: PASS, 5/5.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: all tests passing (98 + this task's 5 = 103).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/ReplyAssist/ReplyContext.swift omwhisper-nativeTests/ReplyContextClassificationTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(reply-assist): add ReplyContextReader (AX focus + mode classification)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 4: `ReplyStreamTypist`

**Files:**
- Create: `omwhisper-native/ReplyAssist/ReplyStreamTypist.swift`
- Test: `omwhisper-nativeTests/ReplyStreamTypistSentinelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated enum StreamResult: Equatable {
      case typed
      case declinedSentinel(String)
      case cancelled
  }
  @MainActor final class ReplyStreamTypist {
      static func sentinelMatch(in prefix: String) -> String?   // pure, unit-tested
      func cancel()
      func stream(_ text: String) async -> StreamResult
  }
  ```
  Consumed by Task 6.

Only `sentinelMatch` is pure/unit-testable — actual keystroke synthesis is covered by live verification in Task 7.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OmWhisper

@Suite("ReplyStreamTypist.sentinelMatch")
struct ReplyStreamTypistSentinelTests {
    @Test("a known failure sentinel in the prefix is detected")
    func detectsSentinel() {
        #expect(ReplyStreamTypist.sentinelMatch(in: "Invalid API key, please check") == "Invalid API key")
        #expect(ReplyStreamTypist.sentinelMatch(in: "NO_REPLY_CONTEXT") == "NO_REPLY_CONTEXT")
    }

    @Test("ordinary drafted text has no sentinel match")
    func noFalsePositive() {
        #expect(ReplyStreamTypist.sentinelMatch(in: "Sounds good, see you at 3pm!") == nil)
    }

    @Test("every sentinel string is shorter than the buffer threshold")
    func sentinelsFitInBuffer() {
        for sentinel in ReplyStreamTypist.sentinels {
            #expect(sentinel.count <= ReplyStreamTypist.bufferThreshold)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/ReplyStreamTypistSentinelTests 2>&1 | tail -30`
Expected: FAIL — `ReplyStreamTypist` doesn't exist yet.

- [ ] **Step 3: Implement `ReplyStreamTypist.swift`**

```swift
//
//  ReplyStreamTypist.swift
//  OmWhisper
//
//  Streams drafted text into the currently-focused field as synthesized
//  Unicode keystrokes -- ported from smriti's StreamTypist (same author,
//  MIT), chosen there over AXSelectedText because "Electron fields accept it
//  and render nothing." Deliberately does NOT use PasteService.paste(), which
//  always writes through NSPasteboard.general -- a visible clipboard flash is
//  wrong for text that's meant to look like it's being typed live, and
//  PasteService's single-shot paste+restore model doesn't fit incremental
//  streaming anyway.
//
//  The first `bufferThreshold` characters are buffered and checked against
//  known failure sentinels before anything is typed -- bufferThreshold must
//  exceed the longest sentinel so a failure is always still fully buffered
//  when checked (enforced by ReplyStreamTypistSentinelTests).
//
//  cancel() drops only pending (not-yet-typed) text -- whatever's already
//  been typed stays, matching smriti's StreamTypistTests-verified contract.
//

import AppKit

nonisolated enum StreamResult: Equatable {
    case typed
    case declinedSentinel(String)
    case cancelled
}

@MainActor
final class ReplyStreamTypist {
    static let sentinels = [
        "NO_REPLY_CONTEXT", "Not logged in", "Please run /login", "Invalid API key",
    ]
    static let bufferThreshold = 24

    private var cancelled = false

    static func sentinelMatch(in prefix: String) -> String? {
        sentinels.first { prefix.contains($0) }
    }

    func cancel() {
        cancelled = true
    }

    func stream(_ text: String) async -> StreamResult {
        cancelled = false
        let prefix = String(text.prefix(Self.bufferThreshold))
        if let sentinel = Self.sentinelMatch(in: prefix) {
            return .declinedSentinel(sentinel)
        }

        let utf16 = Array(text.utf16)
        var index = 0
        let source = CGEventSource(stateID: .combinedSessionState)
        while index < utf16.count {
            if cancelled { return .cancelled }
            let chunk = Array(utf16[index..<min(index + 20, utf16.count)])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            index += 20
            try? await Task.sleep(for: .milliseconds(8))
        }
        return .typed
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/ReplyStreamTypistSentinelTests 2>&1 | tail -30`
Expected: PASS, 3/3.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/ReplyAssist/ReplyStreamTypist.swift omwhisper-nativeTests/ReplyStreamTypistSentinelTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(reply-assist): add ReplyStreamTypist (synthesized-keystroke streaming)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 5: `ToneProfile`

**Files:**
- Create: `omwhisper-native/ReplyAssist/ToneProfile.swift`
- Test: `omwhisper-nativeTests/ToneProfileTests.swift`

**Interfaces:**
- Consumes: `HistoryStore.TranscriptionEntry` (existing, `History/HistoryStore.swift`).
- Produces:
  ```swift
  nonisolated enum ToneProfile {
      static let sampleCap: Int
      static let digestCharCap: Int
      static let promptPrefixCap: Int
      static let distillationPrompt: String
      static func toneFileURL() throws -> URL
      static func buildDigest(from entries: [TranscriptionEntry]) -> String
      static func promptPrefix(from toneMarkdown: String) -> String
  }
  ```
  Consumed by Task 6 (`AppState`'s periodic refresh + draft-time prompt assembly).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import OmWhisper

@Suite("ToneProfile")
struct ToneProfileTests {
    private func entry(_ text: String) -> TranscriptionEntry {
        TranscriptionEntry(
            id: nil, text: text, durationSeconds: 1, modelUsed: "test",
            createdAt: "2026-07-08T00:00:00Z", wordCount: text.split(separator: " ").count,
            source: "raw", rawText: nil, polishStyle: nil
        )
    }

    @Test("buildDigest concatenates entry text with newlines")
    func digestConcatenates() {
        let digest = ToneProfile.buildDigest(from: [entry("hello there"), entry("how are you")])
        #expect(digest == "hello there\nhow are you\n")
    }

    @Test("buildDigest caps at sampleCap entries")
    func digestCapsSampleCount() {
        let entries = (0..<(ToneProfile.sampleCap + 20)).map { entry("entry \($0)") }
        let digest = ToneProfile.buildDigest(from: entries)
        let lineCount = digest.split(separator: "\n").count
        #expect(lineCount == ToneProfile.sampleCap)
    }

    @Test("buildDigest stops before exceeding digestCharCap")
    func digestCapsCharCount() {
        let longEntry = entry(String(repeating: "x", count: ToneProfile.digestCharCap))
        let digest = ToneProfile.buildDigest(from: [longEntry, entry("short")])
        #expect(digest.count <= ToneProfile.digestCharCap + 1)  // +1 for the trailing newline of the entry that fit
        #expect(!digest.contains("short"))
    }

    @Test("buildDigest on an empty entry list returns an empty digest")
    func emptyEntries() {
        #expect(ToneProfile.buildDigest(from: []) == "")
    }

    @Test("promptPrefix truncates to promptPrefixCap")
    func prefixTruncates() {
        let long = String(repeating: "a", count: ToneProfile.promptPrefixCap + 500)
        #expect(ToneProfile.promptPrefix(from: long).count == ToneProfile.promptPrefixCap)
    }

    @Test("promptPrefix passes short tone files through unchanged")
    func prefixPassesThroughShort() {
        #expect(ToneProfile.promptPrefix(from: "short tone") == "short tone")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/ToneProfileTests 2>&1 | tail -30`
Expected: FAIL — `ToneProfile` doesn't exist yet.

- [ ] **Step 3: Implement `ToneProfile.swift`**

```swift
//
//  ToneProfile.swift
//  OmWhisper
//
//  Distills a writing-tone style guide (tone.md) from this app's own dictation
//  history -- NOT from continuous screen captures the way smriti's
//  ToneProfile.swift does. That capture mechanism belongs to S1 (memory
//  capture), which ships AFTER S4 in this project's build order; HistoryStore
//  is a better fit besides, since it's literally the user's own past written
//  words rather than a general screen scrape.
//
//  Pure digest/prompt-shaping helpers here are unit-tested directly; the
//  actual distillation call (HistoryStore read + PolishBackend call + file
//  write) is orchestrated by AppState in Task 6, since it needs live
//  collaborators this type deliberately doesn't own.
//

import Foundation

nonisolated enum ToneProfile {
    static let sampleCap = 120
    static let digestCharCap = 90_000
    static let promptPrefixCap = 1_500

    static let distillationPrompt = """
        You analyze a person's past written text and distill their writing tone \
        into a concise style guide for drafting replies in their voice.

        Write RULES, not observations -- e.g. "Use short sentences, no filler \
        words" not "The user tends to write short sentences." At most 20 lines \
        of markdown.
        """

    static func toneFileURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("com.omwhisper.mac", isDirectory: true)
            .appendingPathComponent("tone.md")
    }

    /// Concatenates up to `sampleCap` entries' text (newline-joined), capped
    /// overall at `digestCharCap` characters so the distillation prompt stays
    /// bounded regardless of history size. Entries are consumed in the order
    /// given -- callers pass already-most-recent-first entries.
    static func buildDigest(from entries: [TranscriptionEntry]) -> String {
        var digest = ""
        for entry in entries.prefix(sampleCap) {
            let line = entry.text + "\n"
            guard digest.count + line.count <= digestCharCap else { break }
            digest += line
        }
        return digest
    }

    /// Truncates a stored tone.md to a prompt-safe prefix for use in a draft
    /// prompt -- the file on disk may be longer (or user-edited longer) than
    /// what's safe to include verbatim in every draft call.
    static func promptPrefix(from toneMarkdown: String) -> String {
        String(toneMarkdown.prefix(promptPrefixCap))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/ToneProfileTests 2>&1 | tail -30`
Expected: PASS, 6/6.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/ReplyAssist/ToneProfile.swift omwhisper-nativeTests/ToneProfileTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(reply-assist): add ToneProfile (tone.md digest from HistoryStore)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 6: `ReplyAssistPanel` + `AppState` wiring + Settings tab

**Files:**
- Create: `omwhisper-native/UI/ReplyAssistPanel.swift`
- Create: `omwhisper-native/UI/ReplyAssistSettingsView.swift`
- Modify: `omwhisper-native/AppState.swift`
- Modify: `omwhisper-native/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `ReplyAssistMonitor` (Task 2), `ReplyContextReader`/`ReplyMode` (Task 3), `ReplyStreamTypist`/`StreamResult` (Task 4), `ToneProfile` (Task 5), existing `AppState.audioCapture`/`engine`/`historyStore`/`systemLLM`/`SettingsKeys` pattern.
- Produces: `AppState.replyAssistEnabled: Bool`, `AppState.beginReplyAssist() async`, `AppState.startVoiceIntentCapture()`/`stopVoiceIntentCapture() async -> String?`, wired into the Meetings-tab-style Settings UI.

Before writing, read `AppState.swift:480-572` (`startDictation()`) once for the exact `audioCapture.start(preferredDeviceUID:)` / `engine.transcribe(_:vocabulary:)` call shape — this task's voice capture reuses those same two collaborators directly, bypassing the `dictation` state machine and main `OverlayPanel` entirely (this is a separate, small, scoped capture, not a second dictation session).

- [ ] **Step 1: Implement `ReplyAssistPanel.swift`**

```swift
//
//  ReplyAssistPanel.swift
//  OmWhisper
//
//  Small interactive panel offering: type intent, leave blank for a silent
//  auto-draft, or hold to speak. Positioned like MeetingConsentPanel (fixed
//  screen corner) -- NOT cursor-relative; resolving precise caret bounds via
//  AX across native/web/Electron fields is its own edge-case-prone problem,
//  out of scope for this ship (see the design spec).
//
//  A new NSPanel, not OverlayPanel (deliberately click-through) -- this needs
//  real keyboard/mouse interaction, matching MeetingConsentPanel's approach.
//

import SwiftUI

@MainActor
final class ReplyAssistPanel {
    private var panel: NSPanel?

    /// onSubmitText receives the typed intent (empty string for a silent
    /// auto-draft). onStartListening/onStopListening bracket a press-and-hold
    /// gesture on the speak button -- separate calls, not one opaque async
    /// call, because the VIEW needs to tell AppState exactly when the mouse
    /// released (matching the start/stop shape this app's own push-to-talk
    /// already uses); a single `() async -> String?` closure called on press
    /// would have no way to signal "the user just released" from outside.
    /// onCancel fires on Escape/dismiss with nothing typed.
    func show(
        mode: ReplyMode,
        onSubmitText: @escaping (String) -> Void,
        onStartListening: @escaping () -> Void,
        onStopListening: @escaping () async -> String?,
        onCancel: @escaping () -> Void
    ) {
        dismiss()
        let newPanel = makePanel()
        let view = ReplyAssistView(
            mode: mode,
            onSubmitText: { [weak self] text in
                self?.dismiss()
                onSubmitText(text)
            },
            onStartListening: onStartListening,
            onStopListening: onStopListening,
            onCancel: { [weak self] in
                self?.dismiss()
                onCancel()
            }
        )
        newPanel.contentView = NSHostingView(rootView: view)
        position(newPanel)
        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        return newPanel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
    }
}

private struct ReplyAssistView: View {
    let mode: ReplyMode
    let onSubmitText: (String) -> Void
    let onStartListening: () -> Void
    let onStopListening: () async -> String?
    let onCancel: () -> Void

    @State private var intent = ""
    @State private var isListening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Type intent, or leave blank…", text: $intent)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmitText(intent) }
            HStack {
                Button(isListening ? "Listening… release to draft" : "Hold to speak") {}
                    .buttonStyle(.bordered)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !isListening else { return }
                                isListening = true
                                onStartListening()
                            }
                            .onEnded { _ in
                                guard isListening else { return }
                                isListening = false
                                Task {
                                    let spoken = await onStopListening()
                                    onSubmitText(spoken ?? intent)
                                }
                            }
                    )
                Spacer()
                Button("Draft") { onSubmitText(intent) }
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var title: String {
        switch mode {
        case .reply: "Draft a reply"
        case .continueDraft: "Continue this draft"
        case .rewrite: "Rewrite selection"
        }
    }
}
```

- [ ] **Step 2: Implement `ReplyAssistSettingsView.swift`**

```swift
//
//  ReplyAssistSettingsView.swift
//  OmWhisper
//

import SwiftUI

struct ReplyAssistSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Toggle("Reply assist (double-tap right ⌥)", isOn: $state.replyAssistEnabled)
            Text("Double-tap right ⌥ in any text field to draft a reply, continue a draft, or rewrite a selection — silently from context, or by holding to speak. Off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ReplyAssistSettingsView().environment(AppState())
}
```

- [ ] **Step 3: Add the tab to `SettingsView.swift`**

Add between the "Meetings" and "About" tabs:

```swift
Tab("Reply Assist", systemImage: "text.bubble") {
    ReplyAssistSettingsView()
}
```

- [ ] **Step 4: Wire `AppState`**

Add near the other Smriti-derived collaborators (alongside `meetingWatcher`/`meetingRecorder`/`meetingConsentPanel`):

```swift
@ObservationIgnored private let replyAssistMonitor = ReplyAssistMonitor()
@ObservationIgnored private let replyAssistPanel = ReplyAssistPanel()
@ObservationIgnored private let replyStreamTypist = ReplyStreamTypist()
@ObservationIgnored private var voiceIntentTask: Task<Void, Never>?
@ObservationIgnored private var voiceIntentTranscript = ""
```

Add to `SettingsKeys`:

```swift
static let replyAssistEnabled = "replyAssistEnabled"
```

Add the setting (mirrors `meetingsEnabled` exactly):

```swift
var replyAssistEnabled: Bool {
    get {
        access(keyPath: \.replyAssistEnabled)
        return UserDefaults.standard.object(forKey: SettingsKeys.replyAssistEnabled) as? Bool ?? false
    }
    set {
        withMutation(keyPath: \.replyAssistEnabled) {
            UserDefaults.standard.set(newValue, forKey: SettingsKeys.replyAssistEnabled)
        }
        if newValue {
            replyAssistMonitor.isSuppressed = { [weak self] in self?.dictation != .idle }
            replyAssistMonitor.onTriggered = { [weak self] in
                Task { await self?.beginReplyAssist() }
            }
            replyAssistMonitor.start()
        } else {
            replyAssistMonitor.stop()
        }
    }
}
```

Add to `init()`, alongside the existing `if meetingsEnabled { meetingsEnabled = true }` re-arm line:

```swift
if replyAssistEnabled { replyAssistEnabled = true }
```

Add the orchestration methods (near `startDictation()`/`stopDictation()`):

```swift
func beginReplyAssist() async {
    guard dictation == .idle else { return }  // ReplyAssistMonitor already suppresses this, but stay defensive
    guard let context = await ReplyContextReader.currentContext() else {
        errorMessage = "Reply assist: couldn't read the focused field."
        return
    }
    let windowContext = ScreenContextReader.captureFrontmostWindowText()
    replyAssistPanel.show(
        mode: context.mode,
        onSubmitText: { [weak self] intent in
            Task { await self?.draftAndStream(mode: context.mode, intent: intent, windowContext: windowContext) }
        },
        onStartListening: { [weak self] in self?.startVoiceIntentCapture() },
        onStopListening: { [weak self] in await self?.stopVoiceIntentCapture() },
        onCancel: {}
    )
}

/// Scoped mic capture for the "hold to speak" path -- reuses the same
/// audioCapture/engine AppState already owns for dictation, but bypasses the
/// `dictation` state machine and main OverlayPanel entirely: this is a short
/// capture for the reply-assist panel, not a second dictation session. Safe
/// to share audioCapture/engine sequentially since ReplyAssistMonitor is
/// suppressed whenever dictation != .idle.
///
/// Start/stop, not one opaque "await while held" call -- the button's
/// onEnded fires exactly when the mouse releases, and stopVoiceIntentCapture
/// must be callable at that exact moment to end the mic stream, matching
/// this app's existing PushToTalkMonitor start/stop shape.
private func startVoiceIntentCapture() {
    guard let audioStream = try? audioCapture.start(preferredDeviceUID: audioInputDeviceUID) else { return }
    voiceIntentTranscript = ""
    let vocabSnapshot = customVocabulary
    voiceIntentTask = Task { [weak self] in
        guard let self else { return }
        let events = self.engine.transcribe(audioStream, vocabulary: vocabSnapshot)
        do {
            for try await event in events {
                switch event {
                case .partial(let text): self.voiceIntentTranscript = text
                case .final(let text): self.voiceIntentTranscript += text
                }
            }
        } catch {
            log.error("startVoiceIntentCapture — engine error: \(error)")
        }
    }
}

private func stopVoiceIntentCapture() async -> String? {
    audioCapture.stop()
    await voiceIntentTask?.value
    voiceIntentTask = nil
    return voiceIntentTranscript.isEmpty ? nil : voiceIntentTranscript
}

private func draftAndStream(mode: ReplyMode, intent: String, windowContext: String?) async {
    let tonePrefix = (try? String(contentsOf: ToneProfile.toneFileURL(), encoding: .utf8))
        .map { ToneProfile.promptPrefix(from: $0) }
    let style = Self.draftStyle(mode: mode, windowContext: windowContext, tonePrefix: tonePrefix)
    guard SystemLLM.isAvailable(), polishBackend == .system else {
        errorMessage = "Reply assist needs the System backend enabled in AI settings."
        return
    }
    let drafted: String
    do {
        drafted = try await systemLLM.polish(intent, style: style, targetLanguage: nil)
    } catch {
        log.error("draftAndStream — polish failed: \(error)")
        errorMessage = "Reply assist: draft failed (\(error.localizedDescription))."
        return
    }
    let result = await replyStreamTypist.stream(drafted)
    if case .declinedSentinel(let sentinel) = result {
        log.warning("draftAndStream — declined on sentinel: \(sentinel)")
        errorMessage = "Reply assist: the draft looked like an error, nothing was typed."
    }
}

private static func draftStyle(mode: ReplyMode, windowContext: String?, tonePrefix: String?) -> PolishStyle {
    var instructions = "You draft a reply/message for the user, writing AS the user in first person. Respond with ONLY the drafted text -- no preamble, no quotes, no explanation.\n\n"
    switch mode {
    case .reply:
        instructions += "Draft a new reply appropriate to the conversation context below.\n"
    case .continueDraft(let draft):
        instructions += "Continue this unfinished draft naturally, in the same voice:\n\(draft)\n"
    case .rewrite(let selection):
        instructions += "Rewrite this selected text, keeping its meaning:\n\(selection)\n"
    }
    if let windowContext { instructions += "\nOn-screen context:\n\(windowContext)\n" }
    if let tonePrefix { instructions += "\nWriting tone to match:\n\(tonePrefix)\n" }
    return PolishStyle(
        id: UUID(uuidString: "7610B7A2-5DAA-4017-A135-45B67089A0FB")!,
        name: "Reply Draft",
        prompt: instructions,
        isBuiltIn: true
    )
}
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: all passing (103 from Task 5 + no new tests this task = 103).

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/UI/ReplyAssistPanel.swift omwhisper-native/UI/ReplyAssistSettingsView.swift omwhisper-native/AppState.swift omwhisper-native/UI/SettingsView.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(reply-assist): wire ReplyAssistPanel + AppState + Settings tab" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 7: Live verification + docs

**Files:**
- Modify: `CLAUDE.md` (Progress Tracker)

No new code — this task is entirely live verification and documentation, matching S3 sub-project 1's Task 7.

- [ ] **Step 1: Build and launch**

```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```
Launch the built app (find the freshest `OmWhisper.app` across DerivedData by mtime — multiple stale DerivedData dirs can exist, don't assume `find | head -1` picks the right one).

- [ ] **Step 2: Enable and test the silent-draft path**

Settings → Reply Assist → toggle on. Open a real text field (Notes, Messages, or a web field like Gmail's compose box). Double-tap right ⌥. Confirm the panel appears near the screen corner, showing the correct mode title (Draft a reply / Continue this draft / Rewrite selection) for an empty field, a field with unsent draft text, and a field with a selection. Leave the intent field blank and press Draft — confirm text streams into the field character-by-character (not a single paste flash), and it reads as a plausible reply given on-screen context.

- [ ] **Step 3: Test the voice path**

Double-tap right ⌥ again, press and hold "Hold to speak", say a short reply intent aloud, release. Confirm the spoken intent is transcribed and used to draft, and that regular dictation (Cmd+Shift+V) still works normally afterward — the scoped `startVoiceIntentCapture()`/`stopVoiceIntentCapture()` pair must not leave `audioCapture`/`engine` in a bad state for the next real dictation session.

- [ ] **Step 4: Test cancel and error paths**

Start a draft, press Escape mid-stream — confirm already-typed characters remain and no more are typed. Toggle the AI backend to Disabled in AI settings, try reply assist — confirm the inline error appears and nothing is typed. Test with dictation active (start dictation, then double-tap right ⌥ while recording) — confirm the panel does NOT appear, matching the suppression contract.

- [ ] **Step 5: Test across app types**

Repeat the silent-draft test in at least one Electron app (Slack, Discord, or similar) if available — confirms the placeholder-vs-value and AXManualAccessibility fallback logic actually holds outside a native field.

- [ ] **Step 6: Update `CLAUDE.md`**

Update the S1–S6 Progress Tracker row: mark S4 shipped, describe what was built (mirroring the level of detail in the S2/S3 entries — architecture ported from smriti with the two deliberate deviations: NSEvent monitors over CGEventSource polling, tone.md from HistoryStore over screen capture), note real bugs found during Steps 2-5 and how they were fixed, and record the live-verification results.

```bash
git add CLAUDE.md
git commit -m "$(printf '%s\n\n%s' "📝 docs: mark S4 (reply assist, voice-first) shipped" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```
