# D2b — Hub Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish D2 — absorb General/Audio/Transcription/MCP/About into a
Settings section inside the hub, then remove the now-superseded `Settings`
scene and `Window("History")`/`Window("Memory")` scenes entirely, collapsing
their three menu items (plus D2a's "Hub (Preview)…") into one canonical
"Open OmWhisper…" entry. This is the point-of-no-return half of D2 —
deliberately sequenced after D2a shipped and was available to try live.

**Architecture:** No new subsystems. Adds an 8th `HubSection` case
(`.settings`) whose content is the existing `SettingsView`'s `TabView`,
trimmed from 10 tabs down to the 5 that are genuinely app-wide configuration
(Vocabulary/AI/Meetings/Reply Assist/Memory already moved to their own hub
sections in D2a — trimming `SettingsView` removes the now-duplicate tabs, it
doesn't touch the underlying feature views themselves). Then deletes the
scenes/menu items/actions that are fully superseded by the hub, plus one
piece of dead code discovered while researching blast radius.

**Tech Stack:** SwiftUI (`NavigationSplitView`, `TabView`), AppKit (`NSMenu`).

## Global Constraints

- Design already approved, not re-litigated here: `docs/DESIGN_DIRECTION.md`
  §2 ("Settings section absorbs General/Audio/Transcription/MCP/About; old
  Settings/Window scenes removed; menu items updated"), §4.
- `SettingsView`'s 5 remaining tabs (`GeneralSettingsView`, `AudioSettingsView`,
  `TranscriptionSettingsView`, `MCPSettingsView`, `AboutSettingsView`) and
  their own internal logic are **not modified** — only the tab list they're
  hosted under changes. `VocabularySettingsView`/`AISettingsView`/
  `MeetingsSettingsView`/`ReplyAssistSettingsView`/`MemorySettingsView` are
  untouched too — they already moved to their own `HubSection` cases in D2a
  and this plan doesn't touch them again.
- One canonical menu entry replaces four: "Settings…", "History…", "Memory…",
  and D2a's "Hub (Preview)…" all become a single "Open OmWhisper…" (key `,` —
  keeps the standard macOS Preferences shortcut, now opening the hub the
  Settings section lives inside).
- New declarations default to `@MainActor` per this project's
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — everything in this plan is
  UI-only, no `nonisolated` annotations needed.

## Task 1: Add the Settings section to the hub

**Files:**
- Modify: `omwhisper-native/UI/HubShellView.swift`
- Modify: `omwhisper-native/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `GeneralSettingsView`, `AudioSettingsView`, `TranscriptionSettingsView`, `MCPSettingsView`, `AboutSettingsView` (existing, unmodified).
- Produces: `HubSection.settings` case; `HubShellView`'s sidebar footer (Settings row + a live privacy-status line); trimmed `SettingsView` (5 tabs, no fixed frame) as the section's content.

- [ ] **Step 1: Trim `SettingsView` to the 5 absorbed tabs**

Replace the full contents of `omwhisper-native/UI/SettingsView.swift`:

```swift
//
//  SettingsView.swift
//  OmWhisper
//
//  App-wide configuration only -- Vocabulary/AI/Meetings/Reply Assist/Memory
//  moved to their own hub sidebar sections in D2a (docs/superpowers/plans/
//  2026-07-10-d2a-hub-shell-migrations.md). This is now embedded as the
//  hub's Settings section content (HubShellView), not a standalone window --
//  the fixed frame that made sense for a standalone Settings window is gone;
//  it flows within the hub's own content area now.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Audio", systemImage: "waveform") {
                AudioSettingsView()
            }
            Tab("Transcription", systemImage: "waveform.badge.mic") {
                TranscriptionSettingsView()
            }
            Tab("MCP", systemImage: "point.3.connected.trianglepath.dotted") {
                MCPSettingsView()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettingsView()
            }
        }
    }
}

#Preview {
    SettingsView().environment(AppState())
}
```

- [ ] **Step 2: Add the `.settings` case to `HubSection`**

In `omwhisper-native/UI/HubShellView.swift`, add `settings` to the enum and
its three switches:

```swift
enum HubSection: String, CaseIterable, Identifiable {
    case home, history, meetings, vocabulary, aiPolish, replyAssist, memory, settings

    var id: String { rawValue }

    /// The main sidebar list -- everything except `.settings`, which renders
    /// separately in the footer (hub-concept.html's `.side-foot` treatment).
    static var contentSections: [HubSection] {
        allCases.filter { $0 != .settings }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .meetings: "Meetings"
        case .vocabulary: "Vocabulary"
        case .aiPolish: "AI Polish"
        case .replyAssist: "Reply Assist"
        case .memory: "Memory"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .meetings: "person.2"
        case .vocabulary: "textformat.abc"
        case .aiPolish: "sparkles"
        case .replyAssist: "text.bubble"
        case .memory: "brain"
        case .settings: "gearshape"
        }
    }

    /// Matches hub-concept.html's "soon" badge -- Meetings' browse UI (S3
    /// sub-project 2) hasn't shipped yet, so this section is toggle-only today.
    var badge: String? {
        self == .meetings ? "S3" : nil
    }
}
```

- [ ] **Step 3: Split the sidebar into main list + footer, add the Settings row and privacy line**

Replace `HubShellView`'s `sidebar` property:

```swift
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brandRow
            ForEach(HubSection.contentSections) { section in
                NavRow(icon: section.icon, title: section.title, isSelected: selection == section, badge: section.badge)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = section }
            }
            Spacer()
            Divider().padding(.vertical, 4)
            NavRow(icon: HubSection.settings.icon, title: HubSection.settings.title, isSelected: selection == .settings)
                .contentShape(Rectangle())
                .onTapGesture { selection = .settings }
            privacyStatusLine
        }
        .padding(12)
        .navigationSplitViewColumnWidth(min: 200, ideal: 224)
        // ponytail: DESIGN_DIRECTION.md §4 specifies an emerald-tinted "aurora"
        // underlay behind the glass material; simplified to a flat tint here
        // and left for D4's polish pass (motion/contrast) to refine into the
        // real radial-gradient treatment -- structural correctness now,
        // visual polish later matches this project's D1-D4 phasing.
        .background(
            ZStack {
                Color.Porcelain.emerald.opacity(0.06)
                Rectangle().fill(.ultraThinMaterial)
            }
        )
    }

    /// hub-concept.html's "🔒 All processing on this Mac" line -- made live
    /// rather than copied verbatim, since that copy predates M4.2's CloudEngine:
    /// it would be actively misleading if the user has Cloud selected.
    private var privacyStatusLine: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(appState.engineKind == .cloud ? Color.Porcelain.dim : Color.Porcelain.emerald)
                .frame(width: 6, height: 6)
            Text(appState.engineKind == .cloud ? "Cloud transcription active — audio leaves this Mac" : "All processing on this Mac")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.Porcelain.dim)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
```

- [ ] **Step 4: Add the `.settings` case to the content switch**

In `HubShellView`'s `content` property, add the new case:

```swift
    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home: HubHomeView()
        case .history: HistoryView()
        case .meetings: MeetingsSettingsView()
        case .vocabulary: VocabularySettingsView()
        case .aiPolish: AISettingsView()
        case .replyAssist: ReplyAssistSettingsView()
        case .memory: HubMemorySectionView()
        case .settings: SettingsView()
        }
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/UI/HubShellView.swift omwhisper-native/UI/SettingsView.swift
git commit -m "feat(hub): absorb General/Audio/Transcription/MCP/About into hub Settings section (D2b)"
```

## Task 2: Remove the superseded scenes, menu items, and dead code

**Files:**
- Modify: `omwhisper-native/OmWhisperApp.swift`
- Delete: `omwhisper-native/UI/MenuContent.swift`
- Modify: `omwhisper-native/UI/MemorySettingsView.swift`

**Interfaces:** None new — this task only removes now-superseded code. Every
symbol removed here was confirmed to have no other callers before this plan
was written (`SettingsView()`, `openSettingsAction`/`openHistoryAction`/
`openMemoryAction`, and `MenuContent` were grepped across the whole app and
test targets — `MenuContent` had zero references anywhere, confirming it's
dead code left over from the pre-AppKit-menu era, not something this plan is
newly orphaning).

- [ ] **Step 1: Remove the three old scenes + rename the hub action wiring**

In `omwhisper-native/OmWhisperApp.swift`, replace the whole `makeScene()`
body:

```swift
    @SceneBuilder
    private func makeScene() -> some Scene {
        let _ = {
            delegate.openHubAction = openWindow
            #if DEBUG
            delegate.openDesignGalleryAction = openWindow
            #endif
        }()
        Window("OmWhisper", id: "hub") {
            HubShellView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
        #if DEBUG
        Window("Design Gallery", id: "design-gallery") {
            DesignGalleryView()
        }
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
```

Remove the now-unused `@Environment(\.openSettings) private var openSettings`
property from `OmWhisperApp` too (only `openWindow` is still needed):

```swift
struct OmWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        makeScene()
    }
```

- [ ] **Step 2: Remove the now-unused action properties**

In `AppDelegate`, remove `openSettingsAction`/`openHistoryAction`/
`openMemoryAction` (keep `openHubAction` and the `#if DEBUG` gallery action):

```swift
    // Set by OmWhisperApp.makeScene() so AppKit menu can open the hub/gallery scenes.
    var openHubAction: OpenWindowAction?
    #if DEBUG
    var openDesignGalleryAction: OpenWindowAction?
    #endif
```

- [ ] **Step 3: Collapse the four menu items into one**

In `menuNeedsUpdate`, replace:

```swift
        addItem(to: menu, title: "Settings…", action: #selector(openSettings), key: ",")
        addItem(to: menu, title: "History…", action: #selector(openHistory))
        addItem(to: menu, title: "Memory…", action: #selector(openMemory))
        addItem(to: menu, title: "Hub (Preview)…", action: #selector(openHub))
        addItem(to: menu, title: "Check for Updates…", action: #selector(checkForUpdates))
            .isEnabled = updaterController.updater.canCheckForUpdates
```

with:

```swift
        addItem(to: menu, title: "Open OmWhisper…", action: #selector(openHub), key: ",")
        addItem(to: menu, title: "Check for Updates…", action: #selector(checkForUpdates))
            .isEnabled = updaterController.updater.canCheckForUpdates
```

- [ ] **Step 4: Remove the now-unused action methods**

Remove `openSettings()`, `openHistory()`, `openMemory()` entirely (the
`openHub()` method added in D2a stays unchanged):

```swift
    @objc private func openHub() {
        NSApp.activate(ignoringOtherApps: true)
        openHubAction?(id: "hub")
    }
```

(this replaces the four methods that previously sat here —
`openSettings`/`openHistory`/`openMemory`/`openHub` — with just `openHub`.)

- [ ] **Step 5: Delete the dead `MenuContent.swift`**

```bash
git rm omwhisper-native/UI/MenuContent.swift
```

It has zero references anywhere in the app or test targets — the pre-AppKit-menu
SwiftUI `MenuBarExtra` content view, fully superseded by `AppDelegate`'s
`NSMenu`-based `menuNeedsUpdate()` since the M1 MenuBarExtra-broken-on-Tahoe fix
(see `CLAUDE.md`'s M1 row) — this plan's scene/action removals are what finally
made its last remaining reason to exist (referencing `openSettings`) moot,
so this is the moment to actually remove it rather than let it keep rotting.

- [ ] **Step 6: Fix the one stale doc-comment this touches**

In `omwhisper-native/UI/MemorySettingsView.swift`, update the file header
comment (currently: `"in MemoryView.swift (Window("Memory"), opened from the
menu bar)."`) to reflect that `MemoryView` is now composed inside
`HubMemorySectionView`, not a standalone window:

```swift
//
//  MemorySettingsView.swift
//  OmWhisper
//
//  Just the toggle, pause, and retention controls -- search/browse UI lives
//  in MemoryView.swift, composed together with these controls inside
//  HubMemorySectionView.swift (the hub's Memory section).
//
```

- [ ] **Step 7: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/OmWhisperApp.swift omwhisper-native/UI/MemorySettingsView.swift
git commit -m "feat(hub): remove superseded Settings/History/Memory scenes, collapse menu to one entry, delete dead MenuContent.swift (D2b)"
```

(the `git rm` from Step 5 stages the deletion; it lands in this same commit.)

## Task 3: Full verification pass + docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED, all 205 existing tests still pass (this plan adds
no new tests — pure SwiftUI/AppKit-menu wiring, matching D1/D2a's established
convention; passing confirms nothing this plan touches is exercised by the
test suite, and that no other file broke from the removals).

- [ ] **Step 2: Update `CLAUDE.md`'s D1–D4 Progress Tracker row**

Update the status cell to `✅ D1 + D2 shipped, D3–D4 not started` (D2a + D2b
together complete D2). Append a new paragraph to the row's notes cell
covering: D2b shipped 2026-07-10 per
`docs/superpowers/plans/2026-07-10-d2b-hub-cutover.md`, executed inline (3
tasks) in `.worktrees/d2b-hub-cutover` — the cutover half of D2, gated on D2a
having shipped first. `SettingsView.swift` trimmed from 10 tabs to the 5
genuinely app-wide ones (General/Audio/Transcription/MCP/About — the other 5
already moved to their own hub sections in D2a), embedded as `HubShellView`'s
new `.settings` `HubSection` case, rendered separately in the sidebar's
footer (below a divider) rather than the main content-section list, matching
`hub-concept.html`'s `.side-foot` treatment; the fixed 720×440 frame that
made sense for a standalone Settings window was dropped since it now flows
inside the hub's own content area. Added a live privacy-status line in the
sidebar footer (`hub-concept.html`'s static "🔒 All processing on this Mac"
copy would have been actively misleading now that M4.2's CloudEngine is real
— made it read `appState.engineKind` and show a different, honest line when
Cloud is selected, rather than copying stale mockup text verbatim). The
actual cutover: removed the `Settings`/`Window("History")`/`Window("Memory")`
scenes and their `openSettingsAction`/`openHistoryAction`/`openMemoryAction`
plumbing entirely, collapsed four menu items ("Settings…"/"History…"/
"Memory…"/D2a's "Hub (Preview)…") into one "Open OmWhisper…" (keeping the
`,` key equivalent). Blast-radius research before writing the plan (grepping
every call site of `SettingsView(`/the three removed actions/`MenuContent`
across both the app and test targets) turned up one real piece of pre-existing
dead code — `UI/MenuContent.swift`, the original pre-AppKit-menu SwiftUI
`MenuBarExtra` content view from the M0/M1 era, fully superseded since the
"MenuBarExtra silently drops real clicks on macOS 26" fix but never actually
deleted — removed outright now that this plan's changes made its last
reference (`openSettings`) go away too. No new tests (pure UI/menu wiring);
the existing 205 tests staying green confirms nothing else in the app
depended on what was removed. **Live-verification status**: D2a itself was
still unverified live when D2b started (the user gave explicit go-ahead to
proceed without waiting) — so neither D2a's hub shell nor D2b's cutover has
been opened in a running app yet. This is now the single most important
thing to check next: does the real "Open OmWhisper…" flow work end-to-end,
does every migrated section render correctly, and does the Settings section's
5 tabs work identically to how they did in the old standalone window.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: mark D2 (D2a+D2b) fully shipped"
```
