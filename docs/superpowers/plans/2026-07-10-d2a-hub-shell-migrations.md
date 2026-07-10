# D2a — Hub Shell + Migrations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the real hub window — `NavigationSplitView` shell, Porcelain
sidebar, seven content sections — as a genuinely new, safely-reachable window
that reuses every existing Settings/History/Memory view verbatim wherever
possible, **without removing or changing anything that exists today**. The
old `Settings`/`Window("History")`/`Window("Memory")` scenes and their menu
items stay exactly as they are; this is D2b's job. D2a's own exit criterion:
every migrated section is reachable and working inside the new hub, reached
via a new, clearly-labeled "Hub (Preview)…" menu item, while the app's
existing behavior is completely unaffected.

**Architecture:** No new subsystems — this composes D1's Porcelain
foundations (`Color.Porcelain`, `OrbPalette`, `omCard`/`NavRow`) with the
existing, already-shipped-and-tested feature views. A new `HubSection` enum
drives a sidebar list + content switch; six of the seven sections embed an
existing view completely unchanged (`HistoryView`, `MeetingsSettingsView`,
`VocabularySettingsView`, `AISettingsView`, `ReplyAssistSettingsView`); the
seventh (Memory) needs a small new wrapper merging `MemorySettingsView`'s
toggle/pause/retention controls with `MemoryView`'s browse UI into one pane,
per `docs/DESIGN_DIRECTION.md` §2's explicit "migrate MemoryView + Chronicles
+ MemorySettings" instruction. Home gets a placeholder — the real dashboard
with live stats is D3's job (`docs/DESIGN_DIRECTION.md` §5 lists it under
"New surfaces," explicitly separate from D2's "migrations").

**Tech Stack:** SwiftUI (`NavigationSplitView`), reusing D1's `OmOrbView`/`OrbPalette`/`omCard`/`NavRow`.

## Global Constraints

- **Nothing existing changes behavior.** The `Settings` scene, `Window("History")`,
  `Window("Memory")`, and every menu item they're reached from must work
  identically after this plan as before it. This is the difference between D2a
  and D2b — D2a is purely additive.
- Design is already approved, not re-litigated here: `docs/DESIGN_DIRECTION.md`
  §1/§2/§4, `docs/hub-concept.html`, `.claude/skills/omwhisper-design/SKILL.md`.
  Three gaps the source docs didn't cover were resolved by applying the docs'
  own stated rules, not invented from scratch:
  - `ReplyAssistSettingsView` isn't in `DESIGN_DIRECTION.md`'s sidebar list (it
    postdates that doc) — added as a sidebar section per the doc's own sorting
    rule ("content sections get sidebar slots; configuration collapses under
    Settings") — a feature toggle exactly like Meetings/Memory.
  - `hub-concept.html`'s actual `<nav>` list omits Memory even though the mockup
    *has* a full Memory empty-state section (`v-memory`/`orbMem`) unreachable
    from that nav — treated as a mockup oversight; `DESIGN_DIRECTION.md`'s own
    ASCII sidebar diagram includes Memory, so Memory is a sidebar section here.
  - Home's content in D2a is a placeholder only — the real dashboard
    (`statsSummary` query, stat cards, recent-dictations rows) is out of scope,
    D3's job per `docs/DESIGN_DIRECTION.md` §5.
- Only Porcelain tokens/components from D1 are used for new chrome (sidebar,
  Home placeholder, Memory's settings bar) — migrated content views keep their
  existing native `Form`/`List` styling untouched (this plan doesn't re-skin
  them, it re-homes them).
- New declarations default to `@MainActor` per this project's
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all SwiftUI view code in this
  plan is UI-only and needs no `nonisolated` annotations.

## Task 1: `HubSection` + `HubShellView` (sidebar shell)

**Files:**
- Create: `omwhisper-native/UI/HubShellView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain`, `NavRow` (D1, `PorcelainComponents.swift`); `OmOrbView`/`OrbPalette.porcelain` (D1); `HistoryView`, `MeetingsSettingsView`, `VocabularySettingsView`, `AISettingsView`, `ReplyAssistSettingsView` (existing, unmodified); `HubHomeView` (Task 2), `HubMemorySectionView` (Task 3).
- Produces: `struct HubShellView: View` — consumed by Task 4's window scene.

No unit tests — pure SwiftUI layout/navigation, matching this project's
established no-tests-for-view-code convention (D1's `PorcelainComponents.swift`
set this precedent explicitly).

- [ ] **Step 1: Write the shell**

Create `omwhisper-native/UI/HubShellView.swift`:

```swift
//
//  HubShellView.swift
//  OmWhisper
//
//  The hub window: a Porcelain NavigationSplitView shell around seven content
//  sections. D2a only -- purely additive, reached via a new "Hub (Preview)…"
//  menu item alongside the existing Settings/History/Memory windows, which
//  this does not touch. See docs/DESIGN_DIRECTION.md §2 for the approved IA
//  and docs/superpowers/plans/2026-07-10-d2a-hub-shell-migrations.md's Global
//  Constraints for the three gaps this plan resolved (Reply Assist, Memory's
//  nav presence, Home-is-a-placeholder).
//

import SwiftUI

enum HubSection: String, CaseIterable, Identifiable {
    case home, history, meetings, vocabulary, aiPolish, replyAssist, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .meetings: "Meetings"
        case .vocabulary: "Vocabulary"
        case .aiPolish: "AI Polish"
        case .replyAssist: "Reply Assist"
        case .memory: "Memory"
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
        }
    }

    /// Matches hub-concept.html's "soon" badge -- Meetings' browse UI (S3
    /// sub-project 2) hasn't shipped yet, so this section is toggle-only today.
    var badge: String? {
        self == .meetings ? "S3" : nil
    }
}

struct HubShellView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: HubSection = .home

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .frame(minWidth: 480, minHeight: 520)
                .background(Color.Porcelain.bg)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brandRow
            ForEach(HubSection.allCases) { section in
                NavRow(icon: section.icon, title: section.title, isSelected: selection == section, badge: section.badge)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = section }
            }
            Spacer()
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

    private var brandRow: some View {
        HStack(spacing: 10) {
            OmOrbView(appState: appState, palette: .porcelain)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("OmWhisper")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Text("2.0 · listening locally")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Porcelain.dim)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

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
        }
    }
}

#Preview {
    HubShellView().environment(AppState())
}
```

- [ ] **Step 2: Build to verify it compiles**

This will fail until Task 2/3 add `HubHomeView`/`HubMemorySectionView` — that's
expected. Run:

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — "Cannot find 'HubHomeView' in scope" / "Cannot find 'HubMemorySectionView' in scope" (both, until Tasks 2-3 land)

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/HubShellView.swift
git commit -m "feat(hub): add HubSection + HubShellView shell (D2a)"
```

## Task 2: `HubHomeView` placeholder

**Files:**
- Create: `omwhisper-native/UI/HubHomeView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain`, `OmOrbView`/`OrbPalette.porcelain` (D1).
- Produces: `struct HubHomeView: View` — consumed by Task 1's `HubShellView`.

- [ ] **Step 1: Write the placeholder**

Create `omwhisper-native/UI/HubHomeView.swift`:

```swift
//
//  HubHomeView.swift
//  OmWhisper
//
//  Placeholder only -- the real dashboard (stats cards, streak line, recent
//  dictations) is D3's job per docs/DESIGN_DIRECTION.md §5 ("New surfaces,"
//  explicitly separate from D2's "migrations"). This exists so Home has
//  somewhere to land as the hub's default selection in D2a.
//

import SwiftUI

struct HubHomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            OmOrbView(appState: appState, palette: .porcelain)
                .frame(width: 64, height: 64)
            Text("The Home dashboard arrives in D3.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Porcelain.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    HubHomeView().environment(AppState())
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: still FAIL — "Cannot find 'HubMemorySectionView' in scope" (Task 3 not done yet)

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/HubHomeView.swift
git commit -m "feat(hub): add HubHomeView placeholder (D2a, real dashboard is D3)"
```

## Task 3: `HubMemorySectionView` (merges settings + browse)

**Files:**
- Create: `omwhisper-native/UI/HubMemorySectionView.swift`

**Interfaces:**
- Consumes: `AppState.memoryEnabled`/`memoryPaused`/`memoryRetentionDays` (existing); `MemoryView` (existing, unmodified, embedded when enabled).
- Produces: `struct HubMemorySectionView: View` — consumed by Task 1's `HubShellView`.

Merges `MemorySettingsView`'s toggle/pause/retention controls with
`MemoryView`'s Snapshots/Chronicles browse UI into one pane, per
`docs/DESIGN_DIRECTION.md` §2's explicit instruction to migrate
"MemoryView + Chronicles + MemorySettings" together into one sidebar section.
`MemorySettingsView.swift` itself is untouched — it still backs the old
Settings tab's Memory row, unaffected by this plan (D2a doesn't remove
anything).

- [ ] **Step 1: Write the merged section**

Create `omwhisper-native/UI/HubMemorySectionView.swift`:

```swift
//
//  HubMemorySectionView.swift
//  OmWhisper
//
//  Merges MemorySettingsView's toggle/pause/retention controls with
//  MemoryView's Snapshots/Chronicles browse UI into one hub sidebar section,
//  per docs/DESIGN_DIRECTION.md §2. MemorySettingsView.swift itself is
//  untouched -- it still backs the old Settings tab's Memory row (D2a is
//  purely additive, nothing existing is removed).
//

import SwiftUI

struct HubMemorySectionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            settingsBar
            Divider()
            if state.memoryEnabled {
                MemoryView()
            } else {
                disabledEmptyState
            }
        }
    }

    private var settingsBar: some View {
        @Bindable var state = appState
        return HStack {
            Toggle("Remember what's on screen", isOn: $state.memoryEnabled)
            Spacer()
            if state.memoryEnabled {
                Menu {
                    Toggle("Pause capture", isOn: $state.memoryPaused)
                    Stepper("Keep for \(state.memoryRetentionDays) days", value: $state.memoryRetentionDays, in: 1...365)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .accessibilityLabel("Memory settings")
            }
        }
        .padding(10)
    }

    private var disabledEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("🧠").font(.system(size: 40))
            Text("Periodically captures the frontmost window's visible text into a private, local, searchable memory — never leaves this Mac. Password managers and private/incognito browsing are always excluded.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    HubMemorySectionView().environment(AppState())
}
```

- [ ] **Step 2: Build to verify the full hub shell now compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED (Tasks 1-3 together resolve every symbol `HubShellView` needs)

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/HubMemorySectionView.swift
git commit -m "feat(hub): add HubMemorySectionView (merges settings + browse, D2a)"
```

## Task 4: Wire the hub window + preview menu item

**Files:**
- Modify: `omwhisper-native/OmWhisperApp.swift`

**Interfaces:**
- Consumes: `HubShellView` (Task 1).
- Produces: a new `Window("OmWhisper", id: "hub")` scene + "Hub (Preview)…" menu item, following the exact same pattern as the existing `Window("History", ...)`/`Window("Memory", ...)` scenes and their menu wiring — **not** `#if DEBUG` gated, since D2a's whole point is that this must be genuinely reachable and clickable to verify live, unlike D1's internal-only Design Gallery.

- [ ] **Step 1: Add the action-setting line**

In `omwhisper-native/OmWhisperApp.swift`, in `makeScene()`'s `let _ = { ... }()`
block, add alongside the existing three (before the `#if DEBUG` line):

```swift
        let _ = {
            delegate.openSettingsAction = openSettings
            delegate.openHistoryAction = openWindow
            delegate.openMemoryAction = openWindow
            delegate.openHubAction = openWindow
            #if DEBUG
            delegate.openDesignGalleryAction = openWindow
            #endif
        }()
```

- [ ] **Step 2: Add the window scene**

Add after the existing `Window("Memory", ...)` scene, before the `#if DEBUG`
Design Gallery scene:

```swift
        Window("Memory", id: "memory") {
            MemoryView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
        Window("OmWhisper", id: "hub") {
            HubShellView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
        #if DEBUG
        Window("Design Gallery", id: "design-gallery") {
```

(only the new `Window("OmWhisper", ...)` block is new — the surrounding
`Window("Memory", ...)` and `#if DEBUG` lines already exist and are shown
here only to anchor the insertion point.)

- [ ] **Step 3: Add the stored property**

In `AppDelegate`, alongside the existing action properties:

```swift
    var openHistoryAction: OpenWindowAction?
    var openMemoryAction: OpenWindowAction?
    var openHubAction: OpenWindowAction?
    #if DEBUG
    var openDesignGalleryAction: OpenWindowAction?
    #endif
```

- [ ] **Step 4: Add the menu item**

In `menuNeedsUpdate`, add right after the existing "Memory…" item (before
"Check for Updates…"):

```swift
        addItem(to: menu, title: "Settings…", action: #selector(openSettings), key: ",")
        addItem(to: menu, title: "History…", action: #selector(openHistory))
        addItem(to: menu, title: "Memory…", action: #selector(openMemory))
        addItem(to: menu, title: "Hub (Preview)…", action: #selector(openHub))
        addItem(to: menu, title: "Check for Updates…", action: #selector(checkForUpdates))
            .isEnabled = updaterController.updater.canCheckForUpdates
```

- [ ] **Step 5: Add the action**

Alongside `openMemory()`:

```swift
    @objc private func openMemory() {
        NSApp.activate(ignoringOtherApps: true)
        openMemoryAction?(id: "memory")
    }

    @objc private func openHub() {
        NSApp.activate(ignoringOtherApps: true)
        openHubAction?(id: "hub")
    }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/OmWhisperApp.swift
git commit -m "feat(hub): wire hub window scene + Hub (Preview)… menu item (D2a)"
```

## Task 5: Full verification pass + docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED, all 205 existing tests still pass (this plan adds
no new tests — pure SwiftUI view code, matching D1's established convention).
Passing confirms the existing `Settings`/`History`/`Memory` scenes and their
menu items are completely unaffected — the actual regression guarantee for
"purely additive."

- [ ] **Step 2: Update `CLAUDE.md`'s D1–D4 Progress Tracker row**

Update the `D1–D4 — Hub Window / Porcelain (Phase D)` row's status cell to
`🔶 D1 + D2a shipped, D2b–D4 not started`. Append a new paragraph to the
row's notes cell covering: D2a shipped 2026-07-10 per
`docs/superpowers/plans/2026-07-10-d2a-hub-shell-migrations.md`, executed
inline (5 tasks) in `.worktrees/d2a-hub-shell-migrations`; the real hub shell
(`HubShellView`, `NavigationSplitView`, seven sidebar sections) is now
reachable via a new "Hub (Preview)…" menu item, with the existing
Settings/History/Memory windows completely untouched — this is deliberately
the safe half of D2, gated ahead of D2b's settings-absorption-and-cutover;
three real gaps the source design docs didn't cover were resolved by applying
the docs' own stated rules rather than inventing new ones (`ReplyAssistSettingsView`
added as a sidebar section — postdates `DESIGN_DIRECTION.md`, but is a feature
toggle exactly like Meetings/Memory per the doc's own sorting rule; Memory kept
as a sidebar section despite `hub-concept.html`'s actual `<nav>` list omitting
it, since that mockup still *has* an unreachable `v-memory` section and
`DESIGN_DIRECTION.md`'s own ASCII sidebar diagram includes Memory — treated as
a mockup oversight, not a decision; Home is a placeholder only, the real
dashboard is D3's explicit job per §5); `HubMemorySectionView` (new) merges
`MemorySettingsView`'s toggle/pause/retention controls with `MemoryView`'s
browse UI into one pane, per `DESIGN_DIRECTION.md`'s explicit instruction to
migrate them together — `MemorySettingsView.swift` itself is untouched, still
backing the old Settings tab. Note honestly: **not yet live-verified** — the
hub window has never actually been opened in a running app in this pass (no
Swift toolchain live-run in this environment); whether the sidebar reads
right, the Porcelain orb renders correctly at 34pt, and each migrated section
looks correct inside the new shell are all real open questions. This is the
step to close before D2b (settings absorption + removing the old windows +
menu cutover) begins — D2b is the point of no return, so D2a should be seen
live first.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: mark D2a (hub shell + migrations) shipped"
```
