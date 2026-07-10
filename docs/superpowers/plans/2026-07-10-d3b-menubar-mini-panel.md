# D3b — Menu-Bar Mini-Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the status item's single click behavior (always shows the
`NSMenu`) with a split interaction: left-click shows a Porcelain `NSPopover`
mini-panel (orb + Ready/Listening state, Start/Stop, active polish style,
last transcription with copy, Open OmWhisper), right-click still shows the
existing full menu unchanged — per `docs/DESIGN_DIRECTION.md` §3's "menu
stays as right-click fallback." D3's own exit criterion for this half:
"panel start/stop round-trip works."

**Architecture:** D3 (Home + mini-panel) was split into D3a (shipped) and
D3b (this) — no shared code, entirely different mechanics (SwiftUI content
pane vs. AppKit `NSPopover` on the status item). `AppDelegate` gains a
manual click router (`statusItemClicked`) replacing the always-on
`item.menu = menu` assignment; a new `MiniPanelView` (Porcelain, hosted via
`NSHostingController`) is the popover's content, rebuilt fresh on every
open so it always reflects current state — the same "read fresh, no
caching" principle `menuNeedsUpdate` already uses for the traditional menu.

**Tech Stack:** AppKit (`NSPopover`, `NSHostingController`, manual
`NSStatusItem` click routing), SwiftUI (Porcelain).

## Global Constraints

- Right-click behavior must be **pixel-identical** to today — same menu,
  same items, same `menuNeedsUpdate` rebuild-on-open logic, completely
  unchanged. This plan only changes what a *left*-click does.
- Menu-bar icon states (idle/recording/finalizing via `updateIcon()`) are
  explicitly out of scope — `DESIGN_DIRECTION.md` says they "already exist
  and stay," and `updateIcon()` isn't touched by this plan.
- The mini-panel's "click = cycle, right-click = menu" spec for the polish
  style chip (`DESIGN_DIRECTION.md` §3) is simplified to a single SwiftUI
  `Menu` (click opens the full style list) — true right-click detection
  inside a SwiftUI view embedded in an `NSPopover` needs custom AppKit
  gesture-recognizer bridging with no natural SwiftUI equivalent on macOS;
  a `Menu` satisfies the actual need (pick a style from the panel) without
  that complexity. Documented here as a deliberate simplification, not an
  oversight.
- The `NSStatusItem.menu`-assign-then-`performClick`-then-nil trick used to
  synthesize the right-click menu without permanently binding it (which
  would hijack left-clicks too) is a well-established AppKit pattern, but
  its exact runtime behavior can't be executed in this environment — flagged
  for live verification, same honesty standard as every other Phase D
  surface so far.
- New declarations default to `@MainActor` per this project's
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — the one pure function this
  plan adds is explicitly `nonisolated` for testability, matching
  `ParakeetEngine.mapUpdate`/`CloudEngine.parseServerMessage`'s precedent.

## Task 1: `miniPanelStateLine(for:)` (TDD)

**Files:**
- Create: `omwhisper-native/UI/MiniPanelView.swift` (helper function only in this task; the view itself is Task 2)
- Test: `omwhisper-nativeTests/MiniPanelStateLineTests.swift`

**Interfaces:**
- Produces: `nonisolated func miniPanelStateLine(for dictation: DictationState) -> String` — consumed by Task 2's `MiniPanelView`.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/MiniPanelStateLineTests.swift`:

```swift
import Testing
@testable import OmWhisper

@Suite("miniPanelStateLine")
struct MiniPanelStateLineTests {
    @Test("idle reads Ready")
    func idleReadsReady() {
        #expect(miniPanelStateLine(for: .idle) == "Ready")
    }

    @Test("starting reads Starting")
    func startingReadsStarting() {
        #expect(miniPanelStateLine(for: .starting) == "Starting…")
    }

    @Test("recording reads Listening")
    func recordingReadsListening() {
        #expect(miniPanelStateLine(for: .recording) == "Listening…")
    }

    @Test("finalizing reads Finishing")
    func finalizingReadsFinishing() {
        #expect(miniPanelStateLine(for: .finalizing) == "Finishing…")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/MiniPanelStateLineTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — "Cannot find 'miniPanelStateLine' in scope"

- [ ] **Step 3: Create the file with just the pure function**

Create `omwhisper-native/UI/MiniPanelView.swift`:

```swift
//
//  MiniPanelView.swift
//  OmWhisper
//
//  The menu-bar mini-panel (D3b): shown in an NSPopover on left-click of the
//  status item, right-click still shows the traditional NSMenu unchanged.
//  See docs/DESIGN_DIRECTION.md §3 and docs/hub-concept.html's minipanel
//  mockup. Rebuilt fresh on every open (AppDelegate.togglePopover) so it
//  always reflects current state -- same principle menuNeedsUpdate already
//  uses for the traditional menu.
//

import SwiftUI

/// Pure state->label mapping, extracted for direct testing.
nonisolated func miniPanelStateLine(for dictation: DictationState) -> String {
    switch dictation {
    case .idle: "Ready"
    case .starting: "Starting…"
    case .recording: "Listening…"
    case .finalizing: "Finishing…"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/MiniPanelStateLineTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS (4/4)

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/MiniPanelView.swift omwhisper-nativeTests/MiniPanelStateLineTests.swift
git commit -m "feat(hub): add miniPanelStateLine pure function (D3b)"
```

## Task 2: `MiniPanelView`

**Files:**
- Modify: `omwhisper-native/UI/MiniPanelView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain`/`OmOrbView`/`OrbPalette.porcelain`/`omCard()` (D1), `AppState.dictation`/`toggleDictation()`/`activePolishStyle`/`activePolishStyleID`/`customPolishStyles`/`historyStore` (existing), `PolishStyles.all(customStyles:)` (existing), `miniPanelStateLine(for:)` (Task 1).
- Produces: `struct MiniPanelView: View { let onOpenHub: () -> Void }` — consumed by Task 3's `AppDelegate.togglePopover()`.

No new tests — pure SwiftUI view code, matching this project's established
convention (D1/D2a/D3a all left view-layer code untested, verified visually).

- [ ] **Step 1: Add the view to `MiniPanelView.swift`**

Append to `omwhisper-native/UI/MiniPanelView.swift` (after the pure function
from Task 1):

```swift
struct MiniPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var lastEntry: TranscriptionEntry?
    @State private var copied = false
    let onOpenHub: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            startStopButton
            styleRow
            if let lastEntry {
                lastTranscriptionCard(lastEntry)
            }
            Divider()
            openHubRow
        }
        .padding(16)
        .frame(width: 270)
        .background(Color.Porcelain.bg)
        .task { load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OmOrbView(appState: appState, palette: .porcelain)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("OmWhisper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Text(miniPanelStateLine(for: appState.dictation))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Porcelain.dim)
            }
        }
    }

    private var startStopButton: some View {
        Button {
            appState.toggleDictation()
        } label: {
            Text(appState.dictation == .idle ? "Start Dictating" : "Stop")
                .font(.system(size: 13.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color.Porcelain.emerald, Color.Porcelain.teal], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // ponytail: DESIGN_DIRECTION.md §3 specs "click = cycle, right-click =
    // menu" for this chip -- simplified to a single Menu (click opens the
    // full style list). True right-click detection in a SwiftUI view hosted
    // inside an NSPopover needs custom AppKit gesture bridging with no
    // natural SwiftUI equivalent on macOS; a Menu satisfies the actual need
    // (pick a style) without that complexity.
    private var styleRow: some View {
        HStack {
            Text("Polish style")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Porcelain.dim)
            Spacer()
            Menu(appState.activePolishStyle?.name ?? "None") {
                ForEach(PolishStyles.all(customStyles: appState.customPolishStyles)) { style in
                    Button(style.name) { appState.activePolishStyleID = style.id }
                }
            }
            .font(.system(size: 11.5))
        }
    }

    private func lastTranscriptionCard(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .font(.system(size: 12))
                .foregroundStyle(Color.Porcelain.ink)
                .lineLimit(2)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = true
            }
            .font(.system(size: 10.5))
            .buttonStyle(.plain)
            .foregroundStyle(Color.Porcelain.mint)
        }
        .padding(10)
        .omCard()
    }

    private var openHubRow: some View {
        Button(action: onOpenHub) {
            HStack {
                Text("Open OmWhisper")
                    .font(.system(size: 12.5))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10.5))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.Porcelain.ink)
    }

    private func load() {
        lastEntry = try? appState.historyStore?.fetchPage(offset: 0, limit: 1).first
    }
}

#Preview {
    MiniPanelView(onOpenHub: {}).environment(AppState())
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/MiniPanelView.swift
git commit -m "feat(hub): add MiniPanelView (D3b)"
```

## Task 3: Wire the popover + click routing

**Files:**
- Modify: `omwhisper-native/OmWhisperApp.swift`

**Interfaces:**
- Consumes: `MiniPanelView` (Task 2), existing `openHub()`/`openHubAction`.
- Produces: split left/right-click behavior on the status item — left opens
  the popover, right opens the unchanged traditional menu.

- [ ] **Step 1: Store the menu as a property, add the popover**

In `omwhisper-native/OmWhisperApp.swift`, replace the `AppDelegate`'s stored
properties:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let popover = NSPopover()
```

- [ ] **Step 2: Replace `applicationDidFinishLaunching`'s click wiring**

Replace the body of `applicationDidFinishLaunching`:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip entirely under XCTest — see isRunningUnderTests in AppState.swift.
        // Without this, every `xcodebuild test` run launches a real, interactive
        // menu-bar instance that outlives the test run.
        guard !isRunningUnderTests else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self          // rebuilt on each open — reflects live state
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        popover.behavior = .transient        // closes on outside click
        observeDictationState()             // keep the icon in sync while the menu is closed
    }
```

- [ ] **Step 3: Add the click router and popover toggle**

Add these methods, placed right after `applicationDidFinishLaunching`:

```swift
    // MARK: Click routing — left-click shows the mini-panel popover,
    // right-click shows the traditional menu (docs/DESIGN_DIRECTION.md §3:
    // "menu stays as right-click fallback"). Neither is ever assigned to
    // `statusItem.menu` permanently -- doing that hands ALL clicks to the
    // menu and this button action never fires again.

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    /// Synthesizes the menu popup for a right-click without permanently
    /// binding `statusItem.menu` (which would hijack left-clicks too):
    /// assign, perform, un-assign. `menuNeedsUpdate` fires automatically
    /// during `performClick` since `statusMenu.delegate` is set once at launch.
    private func showMenu() {
        guard let item = statusItem else { return }
        item.menu = statusMenu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// Rebuilds the popover's content fresh on every open, matching
    /// `menuNeedsUpdate`'s "read live state, never cache" principle.
    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.contentSize = NSSize(width: 270, height: 340)
        popover.contentViewController = NSHostingController(
            rootView: MiniPanelView(onOpenHub: { [weak self] in
                self?.popover.performClose(nil)
                self?.openHub()
            }).environment(appState)
        )
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/OmWhisperApp.swift
git commit -m "feat(hub): wire mini-panel popover + left/right-click routing (D3b)"
```

## Task 4: Full verification pass + docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED, all tests pass (existing 215 + 4 new `MiniPanelStateLineTests` = 219).

- [ ] **Step 2: Update `CLAUDE.md`'s D1–D4 Progress Tracker row**

Update the status cell to `✅ D1 + D2 + D3 shipped, D4 not started` (D3a + D3b
together complete D3). Append a new paragraph covering: D3b shipped
2026-07-10 per `docs/superpowers/plans/2026-07-10-d3b-menubar-mini-panel.md`,
executed inline (4 tasks) in `.worktrees/d3b-menubar-mini-panel` — the
mini-panel half of D3, no shared code with D3a's Home dashboard. The real
work was AppKit click routing, not SwiftUI: `AppDelegate` previously
permanently assigned `item.menu = menu`, which hands every click (left AND
right) to the menu with no way to distinguish them — replaced with manual
`button.action`/`sendAction(on: [.leftMouseUp, .rightMouseUp])` routing plus
a `statusItemClicked()` dispatcher that checks `NSApp.currentEvent?.type`;
right-clicks synthesize the traditional menu via the "assign `.menu`,
`performClick`, un-assign" trick (so it never permanently hijacks left-clicks
again), left-clicks toggle a `transient` `NSPopover` whose content is a fresh
`NSHostingController(rootView: MiniPanelView(...))` rebuilt on every open —
matching `menuNeedsUpdate`'s existing "read live state, never cache"
principle, now applied to the popover too. `MiniPanelView.swift` (new):
40pt Porcelain-palette orb + a `miniPanelStateLine(for:)` pure function
(4 directly-tested cases: Ready/Starting/Listening/Finishing) for the state
line, an emerald→teal gradient Start/Stop button, the active polish style
via a `Menu` (simplified from the design doc's "click = cycle, right-click =
menu" — true right-click detection inside a SwiftUI view hosted in an
`NSPopover` needs custom AppKit gesture bridging with no natural SwiftUI
equivalent on macOS, documented as a deliberate simplification, not an
oversight), the last dictation with copy, and an "Open OmWhisper" row wired
through a closure back to `AppDelegate.openHub()` (SwiftUI's
`@Environment(\.openWindow)` doesn't work here — this view isn't part of the
App's Scene graph, it's manually hosted via `NSHostingController`). 4 new
tests (`MiniPanelStateLineTests`), all passing (219 total in the full
suite). Menu-bar icon states (`updateIcon()`) were explicitly untouched per
`DESIGN_DIRECTION.md`'s "already exist and stay." **Live-verification
status, and a real limit of this environment**: the `NSStatusItem.menu`-
assign-`performClick`-unassign trick used to synthesize the right-click menu
is a well-established AppKit pattern but its exact runtime behavior has not
been (and cannot be, in this environment) executed — whether right-click
still shows the full menu correctly and left-click cleanly shows/hides the
popover without visual glitches are real open questions, more load-bearing
here than D1-D3a's "haven't looked at it yet" gaps, since this task changes
*input routing*, not just rendering. This is the most important thing to
verify live before considering D3 fully done — Phase D as a whole (D1-D3) is
now feature-complete and pushed, with D4 (motion/a11y polish) the only
remaining phase.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: mark D3 (D3a+D3b) fully shipped"
```
