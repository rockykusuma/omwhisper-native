# Memory — Capture Visible Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Memory captures the focused window *plus* the frontmost window on each other display, so reference material on a second monitor becomes searchable.

**Architecture:** A new `Memory/VisibleWindows.swift` splits into a pure selection function (fully unit-tested) and a thin `CGWindowList`/`CGDisplayBounds` enumeration wrapper. `WindowSnapshotReader` grows a `captureVisible()` entry point that captures the focused window through the existing unchanged path, then AX-reads each selected other-display window by matching its geometry to a CG window. `MemoryCapture.tick()` loops over the results inside one shared per-tick time budget.

**Tech Stack:** Swift 6, CoreGraphics (`CGWindowListCopyWindowInfo`, `CGDisplayBounds`), ApplicationServices (AX), Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-01-memory-visible-windows-design.md`. Read it before Task 1.
- **Coordinate space:** window bounds from `CGWindowListCopyWindowInfo` and display bounds from `CGDisplayBounds` are BOTH top-left-origin with y growing downward. **Never mix `NSScreen.frame` into this code** — it is bottom-left-origin and will silently misassign every window on a secondary display.
- **No new permission.** Read only `kCGWindowNumber`, `kCGWindowOwnerPID`, `kCGWindowLayer`, `kCGWindowBounds` — these need none. **Never read `kCGWindowName`**; it requires Screen Recording and comes back empty without it. Window titles come from AX, as they do today.
- **Exclusions are per window.** `ScreenContextReader.isExcluded(bundleID:windowTitle:)` and `MemoryCapture.isDomainExcluded(url:excludedDomains:)` must run for every captured window, never once per tick.
- **`nonisolated`.** This project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. AX and CGWindowList calls have no MainActor affinity — mark new types `nonisolated`, matching `WindowSnapshotReader` and `ScreenContextReader`. If the compiler complains that a nested struct is MainActor-isolated when compared with `==` from a test, mark that struct `nonisolated` too (the `HomeStats` / `TranscriptEvent` precedent).
- **No new settings toggle.** Deliberate — see the spec's Privacy section. The settings copy changes instead (Task 4).
- **Build/test:** `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteName>`.
- Test suite is at 399 tests before this plan. It must never go down.

---

### Task 1: Pure window selection

**Files:**
- Create: `omwhisper-native/Memory/VisibleWindows.swift`
- Test: `omwhisper-nativeTests/VisibleWindowsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `VisibleWindows.Descriptor(windowID: CGWindowID, pid: pid_t, bounds: CGRect, layer: Int)` — `Equatable`
  - `VisibleWindows.Display(id: CGDirectDisplayID, bounds: CGRect)` — `Equatable`
  - `VisibleWindows.display(containing: CGRect, in: [Display]) -> CGDirectDisplayID?`
  - `VisibleWindows.select(windows: [Descriptor], displays: [Display], focusedDisplayID: CGDirectDisplayID?, ownPID: pid_t) -> [Descriptor]`
  - `VisibleWindows.minimumWindowSize: CGSize`

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/VisibleWindowsTests.swift`:

```swift
//
//  VisibleWindowsTests.swift
//  omwhisper-nativeTests
//
//  Pure selection logic for multi-display capture. The display layout used
//  here is the real one this feature was built for: a 1920x1080 main display
//  at the origin and a 2056x1290 display to its LEFT, at negative x.
//

import CoreGraphics
import Testing
@testable import OmWhisper

struct VisibleWindowsTests {
    private let mainDisplay = VisibleWindows.Display(
        id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let secondDisplay = VisibleWindows.Display(
        id: 2, bounds: CGRect(x: -2056, y: 0, width: 2056, height: 1290))

    private func window(
        _ id: CGWindowID, pid: pid_t = 100,
        x: CGFloat, y: CGFloat = 0, w: CGFloat = 1200, h: CGFloat = 800,
        layer: Int = 0
    ) -> VisibleWindows.Descriptor {
        VisibleWindows.Descriptor(
            windowID: id, pid: pid,
            bounds: CGRect(x: x, y: y, width: w, height: h), layer: layer)
    }

    @Test func assignsWindowOnNegativeOriginDisplay() {
        let onSecond = window(1, x: -2000)
        #expect(VisibleWindows.display(containing: onSecond.bounds,
                                       in: [mainDisplay, secondDisplay]) == 2)
        let onMain = window(2, x: 100)
        #expect(VisibleWindows.display(containing: onMain.bounds,
                                       in: [mainDisplay, secondDisplay]) == 1)
    }

    @Test func picksFrontmostOnEachOtherDisplay() {
        let focused = window(1, x: 0)
        let onSecond = window(2, pid: 200, x: -2000)
        let selected = VisibleWindows.select(
            windows: [focused, onSecond],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected == [onSecond])
    }

    @Test func singleDisplaySelectsNothingExtra() {
        let focused = window(1, x: 0)
        let selected = VisibleWindows.select(
            windows: [focused], displays: [mainDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }

    @Test func skipsOccludedWindowOnSameDisplay() {
        // Front-to-back order, both on the second display: only the front one.
        let front = window(2, pid: 200, x: -2000)
        let behind = window(3, pid: 300, x: -1900)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), front, behind],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected == [front])
    }

    @Test func filtersNonZeroLayer() {
        let panel = window(2, pid: 200, x: -2000, layer: 25)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), panel],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }

    @Test func filtersUndersizedWindows() {
        let palette = window(2, pid: 200, x: -2000, w: 120, h: 90)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), palette],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }

    @Test func neverSelectsOurOwnWindows() {
        let ours = window(2, pid: 999, x: -2000)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), ours],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }

    @Test func withNoFocusedDisplayPicksFrontmostOnEvery() {
        let onMain = window(1, x: 0)
        let onSecond = window(2, pid: 200, x: -2000)
        let selected = VisibleWindows.select(
            windows: [onMain, onSecond],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: nil, ownPID: 999)
        #expect(selected == [onMain, onSecond])
    }

    @Test func ignoresWindowsOnNoKnownDisplay() {
        // A window entirely off every display (e.g. a just-disconnected monitor).
        let orphan = window(2, pid: 200, x: 9000, y: 9000)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), orphan],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/VisibleWindowsTests 2>&1 | tail -30`

Expected: build FAILS with "cannot find 'VisibleWindows' in scope".

- [ ] **Step 3: Write the pure implementation**

Create `omwhisper-native/Memory/VisibleWindows.swift`:

```swift
//
//  VisibleWindows.swift
//  OmWhisper
//
//  Which windows Memory should capture on a multi-display desk: the frontmost
//  normal window on each display OTHER than the focused one (the focused
//  window itself is captured by WindowSnapshotReader.captureFrontmost).
//
//  Occluded windows on the same display are deliberately skipped -- they are
//  listed as on-screen but you cannot see them, so they are not "what is in
//  front of me".
//
//  COORDINATE SPACE: every CGRect here is top-left-origin with y growing
//  downward -- the space CGWindowListCopyWindowInfo and CGDisplayBounds both
//  use. NSScreen.frame is bottom-left-origin and must never be mixed in.
//
//  nonisolated: CGWindowList is cross-process IPC with no MainActor affinity,
//  same rationale as ScreenContextReader.
//

import CoreGraphics
import Foundation

nonisolated enum VisibleWindows {
    struct Descriptor: Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let layer: Int
    }

    struct Display: Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect
    }

    /// Below this, a window is a palette, inspector or HUD rather than content
    /// worth indexing. ponytail: a constant, not a setting -- nobody tunes this.
    static let minimumWindowSize = CGSize(width: 300, height: 200)

    /// The display whose bounds contain the rect's centre. nil when none do,
    /// which happens for windows on a display that was just disconnected.
    static func display(containing bounds: CGRect, in displays: [Display]) -> CGDirectDisplayID? {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        return displays.first { $0.bounds.contains(centre) }?.id
    }

    /// Frontmost normal window on each display other than `focusedDisplayID`.
    ///
    /// `windows` MUST be in front-to-back order -- CGWindowListCopyWindowInfo's
    /// own ordering, which is what makes "first per display" mean "frontmost".
    static func select(
        windows: [Descriptor],
        displays: [Display],
        focusedDisplayID: CGDirectDisplayID?,
        ownPID: pid_t
    ) -> [Descriptor] {
        var covered: Set<CGDirectDisplayID> = []
        if let focusedDisplayID { covered.insert(focusedDisplayID) }

        var picked: [Descriptor] = []
        for window in windows {
            guard window.layer == 0,
                  window.pid != ownPID,
                  window.bounds.width >= minimumWindowSize.width,
                  window.bounds.height >= minimumWindowSize.height,
                  let displayID = display(containing: window.bounds, in: displays),
                  !covered.contains(displayID)
            else { continue }
            covered.insert(displayID)
            picked.append(window)
        }
        return picked
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/VisibleWindowsTests 2>&1 | tail -30`

Expected: 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/VisibleWindows.swift omwhisper-nativeTests/VisibleWindowsTests.swift
git commit -m "✨ feat(memory): pure multi-display window selection"
```

---

### Task 2: Extract a deadline-based capture body

Pure refactor. `captureFrontmost` keeps its exact behaviour; the shared body becomes callable for any window, taking a `deadline` instead of a `timeBudget` so a tick can share one budget across several windows.

**Files:**
- Modify: `omwhisper-native/Memory/WindowSnapshotReader.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `WindowSnapshotReader.capture(window: AXUIElement, appElement: AXUIElement, bundleID: String, appName: String, deadline: Date) -> Snapshot?`

- [ ] **Step 1: Replace the body of `WindowSnapshotReader`**

Replace everything from `static func captureFrontmost` to the end of the enum in `omwhisper-native/Memory/WindowSnapshotReader.swift` with:

```swift
    /// nil when there's nothing meaningful, the app/window is excluded, or the
    /// walk hits its deadline before finding anything. Never throws.
    static func captureFrontmost(timeBudget: TimeInterval = 2.0) -> Snapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium apps (Teams, Slack, Discord, VS Code, …) don't expose
        // their AX tree until an assistive tech asks. Set the Chromium hydration
        // flag so their window/text become readable — idempotent, native apps
        // ignore it. The tree may still be empty on the very first tick after
        // switching (hydration lag), but the flag persists on the app, so the next
        // 5s poll captures. Mirrors ReplyContext's Electron handling.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = ScreenContextReader.copyAttribute(appElement, kAXFocusedWindowAttribute) else {
            snapshotLog.debug("no focused window: \(app.localizedName ?? bundleID, privacy: .public)")
            return nil
        }

        return capture(
            window: window as! AXUIElement,
            appElement: appElement,
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            deadline: Date().addingTimeInterval(timeBudget)
        )
    }

    /// Reads one already-resolved window. Takes a `deadline` rather than a
    /// budget so a single capture tick can share one allowance across several
    /// windows without their walks compounding past the poll interval.
    static func capture(
        window windowElement: AXUIElement,
        appElement: AXUIElement,
        bundleID: String,
        appName: String,
        deadline: Date
    ) -> Snapshot? {
        let title = (ScreenContextReader.copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        guard !ScreenContextReader.isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }

        // Walk the page, not the window. Measured on the real store, 58% of a
        // median Arc snapshot was sidebar and pinned-tab chrome -- indexing that
        // buried the actual content and produced search hits like
        // "Footer (c) 2026 GitHub, Inc.". Any app exposing a web area benefits,
        // including Electron ones; native apps find none and behave as before.
        let webArea = BrowserURL.findWebArea(windowElement)
        var lines: [String] = []
        var budget = 50_000
        ScreenContextReader.collectText(webArea ?? windowElement, depth: 0,
                                        into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // A web area that yielded nothing means a page mid-load, a canvas app or
        // a PDF viewer. Skip the tick rather than falling back to the window
        // walk: a snapshot that is 100% chrome is worse than no snapshot, and
        // the 5s poll retries almost immediately.
        if webArea != nil, content.isEmpty {
            snapshotLog.debug("web area empty, skipping tick: \(appName, privacy: .public)")
            return nil
        }
        guard !content.isEmpty else {
            // Escalate: the window is exposed (we read its title) but its WebView
            // content isn't — some apps (new Teams) only surface web text under
            // the full "assistive tech active" flag, not the lighter Chromium one.
            // Set it so the NEXT 5s poll reads them. Scoped to apps that already
            // came back empty, so apps that work with the light flag (Arc / Chrome
            // / Claude / …) never get this heavier, more side-effectful flag.
            // Idempotent; a genuine wall just stays empty.
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            snapshotLog.debug("empty content, escalating a11y: \(appName, privacy: .public)")
            return nil
        }

        let url = BrowserURL.url(bundleId: bundleID, window: windowElement)
        return Snapshot(
            bundleID: bundleID,
            appName: appName,
            windowTitle: title,
            content: content,
            url: url
        )
    }
}
```

- [ ] **Step 2: Run the full suite to prove the refactor changed nothing**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`

Expected: PASS, count unchanged from before this plan (399 + the 9 from Task 1 = 408).

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Memory/WindowSnapshotReader.swift
git commit -m "♻️ refactor(memory): deadline-based single-window capture body"
```

---

### Task 3: Enumerate on-screen windows and capture the selected ones

**Files:**
- Modify: `omwhisper-native/Memory/VisibleWindows.swift`
- Modify: `omwhisper-native/Memory/WindowSnapshotReader.swift`

**Interfaces:**
- Consumes: `VisibleWindows.select(windows:displays:focusedDisplayID:ownPID:)`, `VisibleWindows.display(containing:in:)`, `WindowSnapshotReader.capture(window:appElement:bundleID:appName:deadline:)`.
- Produces:
  - `VisibleWindows.onScreen() -> [Descriptor]`
  - `VisibleWindows.activeDisplays() -> [Display]`
  - `WindowSnapshotReader.captureVisible(totalBudget:focusedBudget:perWindowBudget:) -> [Snapshot]`

- [ ] **Step 1: Add enumeration to `VisibleWindows`**

Append inside `nonisolated enum VisibleWindows` in `omwhisper-native/Memory/VisibleWindows.swift`, after `select(...)`:

```swift
    // MARK: - Enumeration (effectful)

    /// On-screen windows, front-to-back. Deliberately reads only the four keys
    /// that need NO permission -- kCGWindowName is gated behind Screen Recording
    /// and comes back empty without it, so titles come from AX instead.
    static func onScreen() -> [Descriptor] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return info.compactMap { entry in
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return Descriptor(windowID: windowID, pid: pid, bounds: bounds, layer: layer)
        }
    }

    /// Active displays in CGDisplayBounds' space -- the SAME top-left-origin
    /// space as the window bounds above. NSScreen.frame is not interchangeable.
    static func activeDisplays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { Display(id: $0, bounds: CGDisplayBounds($0)) }
    }
```

- [ ] **Step 2: Add `captureVisible` to `WindowSnapshotReader`**

Append inside `nonisolated enum WindowSnapshotReader` in `omwhisper-native/Memory/WindowSnapshotReader.swift`, after `capture(window:appElement:bundleID:appName:deadline:)`:

```swift
    // MARK: - Multi-display capture

    /// The focused window, plus the frontmost window on each OTHER display.
    ///
    /// `totalBudget` is shared across the whole tick, so attaching more monitors
    /// cannot push a capture past MemoryCapture's 5s poll -- windows that don't
    /// fit are simply picked up next tick.
    static func captureVisible(
        totalBudget: TimeInterval = 3.0,
        focusedBudget: TimeInterval = 2.0,
        perWindowBudget: TimeInterval = 1.0
    ) -> [Snapshot] {
        let tickDeadline = Date().addingTimeInterval(totalBudget)
        var snapshots: [Snapshot] = []
        if let focused = captureFrontmost(timeBudget: min(focusedBudget, totalBudget)) {
            snapshots.append(focused)
        }

        let displays = VisibleWindows.activeDisplays()
        guard displays.count > 1 else { return snapshots }

        let windows = VisibleWindows.onScreen()
        // The focused window is the frontmost normal window of the frontmost app.
        // Derived from the CG list rather than AX geometry so the display lookup
        // uses one coordinate space throughout.
        let focusedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedDisplayID = windows
            .first { $0.pid == focusedPID && $0.layer == 0 }
            .flatMap { VisibleWindows.display(containing: $0.bounds, in: displays) }

        let selected = VisibleWindows.select(
            windows: windows,
            displays: displays,
            focusedDisplayID: focusedDisplayID,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )

        for descriptor in selected {
            guard Date() < tickDeadline else {
                snapshotLog.debug("tick budget spent, \(selected.count - snapshots.count) window(s) deferred")
                break
            }
            let deadline = min(Date().addingTimeInterval(perWindowBudget), tickDeadline)
            if let snapshot = capture(descriptor: descriptor, deadline: deadline) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    /// AX-reads a specific CG window. AX exposes no window number, so the link
    /// is geometric: find the app's AX window whose frame matches the CG bounds.
    private static func capture(descriptor: VisibleWindows.Descriptor, deadline: Date) -> Snapshot? {
        guard let app = NSRunningApplication(processIdentifier: descriptor.pid),
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(descriptor.pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windows = ScreenContextReader.copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement],
              let windowElement = windows.first(where: { frameMatches(descriptor.bounds, $0) })
        else {
            snapshotLog.debug("no AX window matching bounds: \(app.localizedName ?? bundleID, privacy: .public)")
            return nil
        }

        return capture(
            window: windowElement,
            appElement: appElement,
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            deadline: deadline
        )
    }

    /// AX window position/size are in the same top-left-origin screen space as
    /// CG window bounds. 2pt tolerance absorbs rounding, not a different window.
    private static func frameMatches(_ bounds: CGRect, _ window: AXUIElement) -> Bool {
        guard let positionValue = ScreenContextReader.copyAttribute(window, kAXPositionAttribute),
              let sizeValue = ScreenContextReader.copyAttribute(window, kAXSizeAttribute)
        else { return false }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return false }

        return abs(origin.x - bounds.origin.x) < 2 && abs(origin.y - bounds.origin.y) < 2
            && abs(size.width - bounds.width) < 2 && abs(size.height - bounds.height) < 2
    }
```

- [ ] **Step 3: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`

Expected: BUILD SUCCEEDED, 408 tests PASS. If the compiler reports an actor-isolation error on `VisibleWindows.Descriptor`, mark that struct `nonisolated` (see Global Constraints).

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/Memory/VisibleWindows.swift omwhisper-native/Memory/WindowSnapshotReader.swift
git commit -m "✨ feat(memory): capture the frontmost window on each other display"
```

---

### Task 4: Wire the capture loop and correct the settings copy

**Files:**
- Modify: `omwhisper-native/Memory/MemoryCapture.swift:69-99`
- Modify: `omwhisper-native/UI/HubMemorySectionView.swift:90`
- Modify: `omwhisper-native/UI/MemorySettingsView.swift:23`

**Interfaces:**
- Consumes: `WindowSnapshotReader.captureVisible(totalBudget:focusedBudget:perWindowBudget:)`.
- Produces: nothing for later tasks.

- [ ] **Step 1: Replace `MemoryCapture.tick()`**

In `omwhisper-native/Memory/MemoryCapture.swift`, replace the whole `private func tick()` with:

```swift
    private func tick() {
        guard !isSuppressed(), let store else { return }
        // Silent empty here is the #1 reason "nothing was captured" -- most often
        // a missing Accessibility grant (the AX walk can't read other apps'
        // trees), which produces no error, just nothing. Log it so the daemon is
        // observable (`log stream --predicate 'category == "MemoryCapture"'`).
        let snapshots = WindowSnapshotReader.captureVisible()
        guard !snapshots.isEmpty else {
            memoryLog.debug("tick — no snapshots (no focused window, excluded, empty text, or missing Accessibility permission)")
            return
        }

        var stored = 0
        for snapshot in snapshots {
            // Per window, never per tick: a password manager or excluded domain on
            // the second display must be filtered independently of the first.
            guard !Self.isDomainExcluded(url: snapshot.url, excludedDomains: excludedDomains) else {
                memoryLog.debug("tick — skipped excluded domain")
                continue
            }
            let content = String(snapshot.content.prefix(Self.maxContentLength))
            do {
                try store.upsert(
                    appName: snapshot.appName, bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle,
                    content: content, url: snapshot.url ?? ""
                )
                stored += 1
                memoryLog.debug("tick — captured \(snapshot.appName, privacy: .public)")
            } catch {
                memoryLog.error("tick — upsert failed: \(error)")
            }
        }

        // Let the semantic indexer catch up. It works from "snapshots with no
        // passages yet", so this is just a nudge -- the same code path that
        // backfills, which means a missed nudge self-heals rather than leaving a
        // permanently unindexed snapshot.
        if stored > 0 { onSnapshotStored() }
    }
```

- [ ] **Step 2: Correct the settings copy in both views**

The old copy says "the frontmost window", which is no longer true and would understate what Memory stores.

In `omwhisper-native/UI/HubMemorySectionView.swift` line 90, replace the `Text(...)` string with:

```swift
            Text("Periodically captures visible windows' text — the one you're working in, plus the frontmost window on each other display — into a private, local, searchable memory. Never leaves this Mac. Password managers and private/incognito browsing are always excluded.")
```

In `omwhisper-native/UI/MemorySettingsView.swift` line 23, replace the `Text(...)` string with:

```swift
            Text("Periodically captures visible windows' text — the one you're working in, plus the frontmost window on each other display — into a private, local, searchable memory. Never leaves this Mac, off by default. Password managers and private/incognito browsing are always excluded.")
```

- [ ] **Step 3: Run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`

Expected: BUILD SUCCEEDED, 408 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/Memory/MemoryCapture.swift omwhisper-native/UI/HubMemorySectionView.swift omwhisper-native/UI/MemorySettingsView.swift
git commit -m "✨ feat(memory): store every visible window per tick"
```

- [ ] **Step 5: Live verification — a check that can fail**

Unit tests cover selection with synthetic geometry. They cannot prove a real second-monitor window is read and stored. This check can come back negative, and the behaviour it replaces produces exactly zero rows.

1. Note the baseline row count:

```bash
sqlite3 ~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db \
  "SELECT COUNT(*) FROM snapshots;"
```

2. Run the debug build (⌘R). Enable Memory in the hub if it is off, and grant Accessibility to **OmWhisper-Dev** if prompted.
3. Put a distinctive page on the **second display** — one whose text does not appear anywhere else.
4. Work in a **different app on the main display** for at least 60 seconds. Do not click the second-display window; focus must stay on the main display the whole time.
5. Query for the second-display app's rows written during that window:

```bash
sqlite3 ~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db \
  "SELECT appName, windowTitle, substr(content,1,80) FROM snapshots
   ORDER BY lastSeenAt DESC LIMIT 15;"
```

**Pass:** rows from the second-display app are present, with real page text.
**Fail:** only the focused app appears — which is exactly today's behaviour, so a passing-looking "Memory still captures things" observation would prove nothing.

6. Confirm the budget holds — capture must not overrun the 5s poll:

```bash
log stream --predicate 'subsystem == "com.omwhisper.mac" AND category == "MemoryCapture"' --style compact
```

Ticks should appear roughly every 5 seconds, with no `tick budget spent` message in the steady state on a two-display setup.

7. Confirm exclusions still hold per window: open a password manager or a private/incognito window on the **second** display, leave focus on the main display for a minute, and verify no rows for it appear in the query from step 5.

- [ ] **Step 6: Record the live-verification result**

Append the outcome (pass/fail, plus the actual second-display app name observed) to the Progress Tracker's S1–S6 row in `CLAUDE.md`, and commit. If step 5 failed, stop and debug rather than recording the feature as shipped.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Pure `select`, layer/size/own-PID filters, centre-based display assignment | 1 |
| Negative-origin display handling | 1 (test), 3 (`CGDisplayBounds`) |
| `captureFrontmost` unchanged, shared deadline-based body | 2 |
| `CGWindowListCopyWindowInfo`, no `kCGWindowName`, no new permission | 3 |
| CG↔AX window link by geometry | 3 |
| Per-tick shared budget (~3s / 2s focused / 1s each) | 3 |
| Per-window exclusion (bundle/title in `capture`, domain in `tick`) | 2, 4 |
| No new toggle; settings copy says "visible windows" | 4 |
| Live check that can fail | 4 step 5 |
| Storage/dedup unchanged | no change needed — `upsert` already hashes content |

**Placeholders:** none — every code step carries full source.

**Type consistency:** `Descriptor`/`Display` field names and `select`/`display(containing:in:)` signatures match between Tasks 1 and 3; `capture(window:appElement:bundleID:appName:deadline:)` is defined in Task 2 and called with those exact labels in Task 3.

One deliberate early-exit added in Task 3 beyond the spec: `guard displays.count > 1` skips all enumeration on a single-display Mac, so the common case pays nothing.
