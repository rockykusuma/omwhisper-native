# Memory — User-Editable Exclusions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user exclude a particular app, site or window-title keyword from Memory capture, from one Exclusions sheet.

**Architecture:** A new pure `MemoryExclusions` value type answers "should this window be skipped?" from a bundle ID and a window title. `WindowSnapshotReader` consults it **before** the text walk, so an excluded app's content is never read. Two new `AppState` settings feed it, wired exactly like the existing `memoryExcludedDomains`. The UI replaces today's single-purpose `ExcludedDomainsEditor` sheet with a three-section `ExclusionsEditor`.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSWorkspace.runningApplications`), UserDefaults, Swift Testing.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-01-memory-exclusions-design.md`. Read it before Task 1.
- **The hardcoded floor is never displaced.** `ScreenContextReader.isExcluded(bundleID:windowTitle:)` (password managers, Private Browsing/Incognito, `.env`) keeps running exactly as it does now. The user's lists only ever **add** exclusions, and hardcoded entries never appear in the UI as removable rows.
- **Deviation from the spec, deliberate:** the spec's architecture table describes `MemoryExclusions` as carrying "the user's three lists". It carries **two** — apps and title keywords. Domains stay in `MemoryCapture.isDomainExcluded` because a URL is only known *after* the window is read, which is the same reason the spec itself says "Domain exclusion stays where it is". Behaviour matches the spec; only that one-line description does not.
- **`access(keyPath:)` / `withMutation(keyPath:)` is mandatory** on every new `AppState` setting. `@Observable` only auto-instruments *stored* properties; a plain computed property over `UserDefaults` never notifies, which has caused real "the row didn't disappear" bugs in this codebase (see the M5 row in `CLAUDE.md`).
- **`nonisolated`.** This project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. `MemoryExclusions` is used from `WindowSnapshotReader`'s nonisolated code and compared with `==` in tests — mark it `nonisolated`.
- **Empty lists change nothing.** With all three lists empty, capture must behave exactly as it does today.
- **Build/test:** `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteName>`.
- Suite is at **433 tests in 57 suites** before this plan. It must never go down.

---

### Task 1: The pure exclusion decision

**Files:**
- Create: `omwhisper-native/Memory/MemoryExclusions.swift`
- Test: `omwhisper-nativeTests/MemoryExclusionsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `MemoryExclusions(apps: Set<String>, titleKeywords: [String])` — `Equatable`, memberwise init with both parameters defaulting to empty
  - `MemoryExclusions.none` — the empty value
  - `MemoryExclusions.excludes(bundleID: String, windowTitle: String) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/MemoryExclusionsTests.swift`:

```swift
//
//  MemoryExclusionsTests.swift
//  omwhisper-nativeTests
//
//  The user's own additions to the hardcoded exclusion floor.
//

import Testing
@testable import OmWhisper

struct MemoryExclusionsTests {
    @Test func emptyExclusionsExcludeNothing() {
        #expect(!MemoryExclusions.none.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Untitled"))
    }

    @Test func excludesAppByExactBundleID() {
        let e = MemoryExclusions(apps: ["com.apple.MobileSMS"])
        #expect(e.excludes(bundleID: "com.apple.MobileSMS", windowTitle: "Messages"))
        // Exact match only -- a prefix must not sweep up a different app.
        #expect(!e.excludes(bundleID: "com.apple.MobileSMS.helper", windowTitle: "Messages"))
        #expect(!e.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Messages"))
    }

    @Test func excludesTitleKeywordCaseInsensitively() {
        let e = MemoryExclusions(titleKeywords: ["Salary"])
        #expect(e.excludes(bundleID: "com.apple.Numbers", windowTitle: "Salary review 2026"))
        #expect(e.excludes(bundleID: "com.apple.Numbers", windowTitle: "team salary.numbers"))
        #expect(!e.excludes(bundleID: "com.apple.Numbers", windowTitle: "Budget 2026"))
    }

    @Test func blankKeywordNeverMatchesEverything() {
        // A user who adds a row and clears it must not silently disable all
        // capture -- an empty needle is contained in every string.
        for blank in ["", "   ", "\n", "\t "] {
            let e = MemoryExclusions(titleKeywords: [blank])
            #expect(!e.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Untitled"),
                    "blank keyword \(blank.debugDescription) must not match")
        }
    }

    @Test func keywordIsTrimmedBeforeMatching() {
        let e = MemoryExclusions(titleKeywords: ["  Salary  "])
        #expect(e.excludes(bundleID: "com.apple.Numbers", windowTitle: "Salary review"))
    }

    @Test func appAndKeywordListsAreIndependent() {
        let e = MemoryExclusions(apps: ["com.apple.MobileSMS"], titleKeywords: ["Salary"])
        #expect(e.excludes(bundleID: "com.apple.MobileSMS", windowTitle: "anything"))
        #expect(e.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Salary review"))
        #expect(!e.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Untitled"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/MemoryExclusionsTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: build FAILS with "cannot find 'MemoryExclusions' in scope".

- [ ] **Step 3: Write the implementation**

Create `omwhisper-native/Memory/MemoryExclusions.swift`:

```swift
//
//  MemoryExclusions.swift
//  OmWhisper
//
//  The user's own additions to the exclusion floor. ScreenContextReader's
//  hardcoded set (password managers, private browsing, .env) is a safety
//  floor that stays hardcoded and un-removable; this only ever ADDS.
//
//  Apps and title keywords are checked BEFORE the accessibility text walk,
//  so an excluded app's content is never read. Domains are checked after,
//  in MemoryCapture -- the URL isn't known until the window has been read.
//
//  nonisolated: consulted from WindowSnapshotReader's nonisolated capture path.
//

import Foundation

nonisolated struct MemoryExclusions: Equatable {
    /// Bundle IDs, matched exactly.
    var apps: Set<String> = []
    /// Matched case-insensitively as substrings of the window title -- the same
    /// mechanism as the built-in "Private Browsing" / "Incognito" entries.
    var titleKeywords: [String] = []

    static let none = MemoryExclusions()

    func excludes(bundleID: String, windowTitle: String) -> Bool {
        if apps.contains(bundleID) { return true }
        return titleKeywords.contains { keyword in
            let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank needle is contained in every string. Without this guard a
            // user who adds a row and clears it silently disables all capture.
            guard !needle.isEmpty else { return false }
            return windowTitle.localizedCaseInsensitiveContains(needle)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/MemoryExclusionsTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/MemoryExclusions.swift omwhisper-nativeTests/MemoryExclusionsTests.swift
git commit -m "✨ feat(memory): pure user-exclusion decision"
```

---

### Task 2: Consult exclusions before the text walk, and wire the settings

**Files:**
- Modify: `omwhisper-native/Memory/WindowSnapshotReader.swift`
- Modify: `omwhisper-native/Memory/MemoryCapture.swift`
- Modify: `omwhisper-native/AppState.swift`
- Test: `omwhisper-nativeTests/MemoryExclusionsTests.swift` (append)

**Interfaces:**
- Consumes: `MemoryExclusions(apps:titleKeywords:)`, `.none`, `.excludes(bundleID:windowTitle:)`.
- Produces:
  - `WindowSnapshotReader.captureVisible(exclusions:totalBudget:focusedBudget:perWindowBudget:)`
  - `WindowSnapshotReader.captureFrontmost(exclusions:timeBudget:)`
  - `MemoryCapture.exclusions: MemoryExclusions`
  - `AppState.memoryExcludedApps: [String]`, `AppState.memoryExcludedTitleKeywords: [String]`
  - `SettingsKeys.memoryExcludedApps`, `SettingsKeys.memoryExcludedTitleKeywords`

- [ ] **Step 1: Write the failing regression test**

The pure type is already covered. What this task must not break is the hardcoded floor. Append to `omwhisper-nativeTests/MemoryExclusionsTests.swift`, inside the existing `struct MemoryExclusionsTests`, before its closing brace:

```swift
    // MARK: - The hardcoded floor is additive, not replaced

    @Test func hardcodedFloorStillAppliesWithEmptyUserLists() {
        // If a refactor ever routes capture through MemoryExclusions ALONE,
        // these stop being excluded and secrets start getting captured.
        #expect(ScreenContextReader.isExcluded(bundleID: "com.1password.1password", windowTitle: "Vault"))
        #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.Safari", windowTitle: "Private Browsing"))
        #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.TextEdit", windowTitle: ".env"))
        #expect(!MemoryExclusions.none.excludes(bundleID: "com.1password.1password", windowTitle: "Vault"))
    }
```

- [ ] **Step 2: Run it to confirm it passes already**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test -only-testing:omwhisper-nativeTests/MemoryExclusionsTests 2>&1 | grep -E "^.*error: |\*\* BUILD|Test run with"`

Expected: 7 tests PASS. This one is a *pin*, not a red-then-green test — it must keep passing after every edit below. Note it is the only guard against the floor being silently replaced.

- [ ] **Step 3: Thread exclusions through `WindowSnapshotReader`**

In `omwhisper-native/Memory/WindowSnapshotReader.swift`, make four edits.

(a) `captureFrontmost` — add the parameter and pass it on. Replace its signature line and its `return capture(` call:

```swift
    static func captureFrontmost(
        exclusions: MemoryExclusions = .none,
        timeBudget: TimeInterval = 2.0
    ) -> Snapshot? {
```

and

```swift
        return capture(
            window: window as! AXUIElement,
            appElement: appElement,
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            deadline: Date().addingTimeInterval(timeBudget),
            exclusions: exclusions
        )
```

(b) `capture(window:appElement:bundleID:appName:deadline:)` — add the parameter and the check. Replace its signature and the exclusion guard that follows:

```swift
    static func capture(
        window windowElement: AXUIElement,
        appElement: AXUIElement,
        bundleID: String,
        appName: String,
        deadline: Date,
        exclusions: MemoryExclusions = .none
    ) -> Snapshot? {
        let title = (ScreenContextReader.copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        // Hardcoded floor first, then the user's own list. Both run BEFORE
        // collectText, so an excluded window's text is never read -- not read
        // and then discarded.
        guard !ScreenContextReader.isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }
        guard !exclusions.excludes(bundleID: bundleID, windowTitle: title) else {
            snapshotLog.debug("user-excluded: \(appName, privacy: .public)")
            return nil
        }
```

(c) `captureVisible` — add the parameter and pass it to both call sites. Replace its signature, its `captureFrontmost(` call, and its `capture(descriptor:` call:

```swift
    static func captureVisible(
        exclusions: MemoryExclusions = .none,
        totalBudget: TimeInterval = 3.0,
        focusedBudget: TimeInterval = 2.0,
        perWindowBudget: TimeInterval = 1.0
    ) -> [Snapshot] {
        let tickDeadline = Date().addingTimeInterval(totalBudget)
        var snapshots: [Snapshot] = []
        if let focused = captureFrontmost(exclusions: exclusions,
                                          timeBudget: min(focusedBudget, totalBudget)) {
            snapshots.append(focused)
        }
```

and, inside the `for (index, descriptor)` loop:

```swift
            if let snapshot = capture(descriptor: descriptor, deadline: deadline, exclusions: exclusions) {
                snapshots.append(snapshot)
            }
```

(d) `capture(descriptor:deadline:)` — add the parameter, and short-circuit on the app before any AX call at all. Replace its signature and the line after the `guard let app =` block:

```swift
    private static func capture(
        descriptor: VisibleWindows.Descriptor,
        deadline: Date,
        exclusions: MemoryExclusions = .none
    ) -> Snapshot? {
        guard let app = NSRunningApplication(processIdentifier: descriptor.pid),
              let bundleID = app.bundleIdentifier else { return nil }
        // An excluded app is skipped before we even open its AX tree.
        guard !exclusions.apps.contains(bundleID),
              !ScreenContextReader.excludedBundleIDs.contains(bundleID) else { return nil }

        let appElement = AXUIElementCreateApplication(descriptor.pid)
```

- [ ] **Step 4: Wire `MemoryCapture`**

In `omwhisper-native/Memory/MemoryCapture.swift`, add a stored property beside `excludedDomains`:

```swift
    var excludedDomains: [String] = []
    /// The user's app / window-title exclusions. Checked before the text walk,
    /// unlike excludedDomains above, which needs a URL and so runs after.
    var exclusions: MemoryExclusions = .none
```

and pass it in `tick()` — replace the `captureVisible()` call:

```swift
        let snapshots = WindowSnapshotReader.captureVisible(exclusions: exclusions)
```

- [ ] **Step 5: Add the two settings to `AppState`**

In `omwhisper-native/AppState.swift`, immediately after the `memoryExcludedDomains` computed property (which ends with `memoryCapture.excludedDomains = newValue` and a closing brace), add:

```swift
    /// Bundle IDs whose windows are never captured into memory. Adds to the
    /// hardcoded floor in ScreenContextReader.isExcluded; never replaces it.
    /// Empty by default.
    var memoryExcludedApps: [String] {
        get {
            access(keyPath: \.memoryExcludedApps)
            return UserDefaults.standard.stringArray(forKey: SettingsKeys.memoryExcludedApps) ?? []
        }
        set {
            withMutation(keyPath: \.memoryExcludedApps) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryExcludedApps)
            }
            memoryCapture.exclusions = currentMemoryExclusions(apps: newValue)
        }
    }

    /// Case-insensitive substrings; a window whose title contains any of them is
    /// never captured. Matches the TITLE only, never page content. Empty by default.
    var memoryExcludedTitleKeywords: [String] {
        get {
            access(keyPath: \.memoryExcludedTitleKeywords)
            return UserDefaults.standard.stringArray(forKey: SettingsKeys.memoryExcludedTitleKeywords) ?? []
        }
        set {
            withMutation(keyPath: \.memoryExcludedTitleKeywords) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryExcludedTitleKeywords)
            }
            memoryCapture.exclusions = currentMemoryExclusions(keywords: newValue)
        }
    }

    /// One place that builds the value, so the two setters above cannot drift
    /// (each one only knows its own new value; the other must be read fresh).
    private func currentMemoryExclusions(apps: [String]? = nil, keywords: [String]? = nil) -> MemoryExclusions {
        MemoryExclusions(
            apps: Set(apps ?? memoryExcludedApps),
            titleKeywords: keywords ?? memoryExcludedTitleKeywords
        )
    }
```

Then, in the `memoryEnabled` setter's `if newValue {` block, add one line directly after the existing `memoryCapture.excludedDomains = memoryExcludedDomains`:

```swift
                memoryCapture.exclusions = currentMemoryExclusions()
```

Finally add the two keys to the `SettingsKeys` enum, beside `memoryExcludedDomains`:

```swift
        static let memoryExcludedApps = "memoryExcludedApps"
        static let memoryExcludedTitleKeywords = "memoryExcludedTitleKeywords"
```

- [ ] **Step 6: Run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 434 tests PASS (433 + the pin from Step 1). `MemorySelfTest.swift` calls `captureFrontmost()` with no arguments and must still compile — that is what the `= .none` defaults are for.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Memory/WindowSnapshotReader.swift omwhisper-native/Memory/MemoryCapture.swift omwhisper-native/AppState.swift omwhisper-nativeTests/MemoryExclusionsTests.swift
git commit -m "✨ feat(memory): honour user app/title exclusions before the text walk"
```

---

### Task 3: The Exclusions sheet

**Files:**
- Modify: `omwhisper-native/UI/HubMemorySectionView.swift`

**Interfaces:**
- Consumes: `AppState.memoryExcludedApps`, `AppState.memoryExcludedTitleKeywords`, `AppState.memoryExcludedDomains`.
- Produces: nothing for later tasks.

No unit tests — pure SwiftUI composition, verified live, matching this project's standing convention (`PorcelainComponents.swift`, `HubHomeView.swift`, `MiniPanelView.swift` set the precedent). The existing suite staying green is the regression proof that no binding or store wiring changed.

- [ ] **Step 1: Rename the sheet's trigger**

In `omwhisper-native/UI/HubMemorySectionView.swift`, rename the state flag and the menu item so the sheet covers all three lists.

Replace line 16:

```swift
    @State private var showExclusions = false
```

Replace the `.sheet` modifier (lines 33-36):

```swift
        .sheet(isPresented: $showExclusions) {
            ExclusionsEditor()
                .environment(appState)
        }
```

Replace the menu button (line 49):

```swift
                    Button("Exclusions…") { showExclusions = true }
```

- [ ] **Step 2: Replace `ExcludedDomainsEditor` with `ExclusionsEditor`**

In the same file, replace the entire `private struct ExcludedDomainsEditor: View { … }` declaration — from its doc comment through its closing brace, i.e. everything from `/// Sheet editor for the domains never captured into memory.` down to and including the `}` that closes the struct, just above `#Preview` — with:

```swift
/// Sheet editor for everything the user has chosen never to capture: apps,
/// sites and window-title keywords. Add/remove rows, same idiom as
/// VocabularySettingsView's word list.
///
/// The hardcoded floor (password managers, private browsing, .env) is
/// deliberately NOT listed here -- those are a safety floor, not a preference,
/// and must not be switchable off by mistake.
private struct ExclusionsEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var newDomain = ""
    @State private var newKeyword = ""

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            HStack {
                Text("Exclusions")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    appsSection(state: state)
                    sitesSection(state: state)
                    keywordsSection(state: state)
                    Text("Adding an exclusion stops future capture. Anything already saved stays until you clear memory or it ages out after \(state.memoryRetentionDays) days.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    // MARK: - Apps

    private func appsSection(state: AppState) -> some View {
        PorcelainSection(eyebrow: "Apps") {
            Text("Windows belonging to these apps are never captured. Password managers are always excluded and aren't listed here.")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
            ForEach(state.memoryExcludedApps, id: \.self) { bundleID in
                HStack {
                    Text(Self.displayName(for: bundleID))
                        .foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    Button { removeApp(bundleID) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop excluding \(Self.displayName(for: bundleID))")
                }
            }
            if state.memoryExcludedApps.isEmpty {
                Text("No apps excluded yet.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            Menu("Add app…") {
                ForEach(addableApps, id: \.bundleID) { app in
                    Button(app.name) { addApp(app.bundleID) }
                }
            }
            .disabled(addableApps.isEmpty)
        }
    }

    /// Running apps the user could pick, minus those already excluded.
    /// `.regular` only, so background agents and daemons never show up --
    /// OmWhisper itself is `.accessory` and so is excluded from the list too.
    private var addableApps: [(bundleID: String, name: String)] {
        let already = Set(appState.memoryExcludedApps)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let id = app.bundleIdentifier, !already.contains(id) else { return nil }
                return (bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An excluded app that isn't running right now has no resolvable name --
    /// show its bundle ID rather than dropping the row, so the rule stays
    /// visible and removable.
    static func displayName(for bundleID: String) -> String {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .localizedName ?? bundleID
    }

    private func addApp(_ bundleID: String) {
        guard !appState.memoryExcludedApps.contains(bundleID) else { return }
        appState.memoryExcludedApps.append(bundleID)
    }

    private func removeApp(_ bundleID: String) {
        appState.memoryExcludedApps.removeAll { $0 == bundleID }
    }

    // MARK: - Sites

    private func sitesSection(state: AppState) -> some View {
        PorcelainSection(eyebrow: "Sites") {
            Text("Pages on these sites are never saved to memory. Subdomains are covered too — excluding example.com also excludes docs.example.com. Only browser windows are matched.")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
            ForEach(state.memoryExcludedDomains, id: \.self) { domain in
                HStack {
                    Text(domain).foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    Button { removeDomain(domain) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop excluding \(domain)")
                }
            }
            if state.memoryExcludedDomains.isEmpty {
                Text("No sites excluded yet.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            HStack {
                TextField("example.com", text: $newDomain)
                    .porcelainField()
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .disabled(Self.normalizedDomain(newDomain).isEmpty)
            }
        }
    }

    private func addDomain() {
        let domain = Self.normalizedDomain(newDomain)
        guard !domain.isEmpty, !appState.memoryExcludedDomains.contains(domain) else { return }
        appState.memoryExcludedDomains.append(domain)
        newDomain = ""
    }

    private func removeDomain(_ domain: String) {
        appState.memoryExcludedDomains.removeAll { $0 == domain }
    }

    /// Bare lowercased host from freeform input ("https://www.example.com/x",
    /// "www.example.com", "example.com" all -> "example.com"). Reuses
    /// BrowserURL.domain(of:), which strips scheme/path and a leading "www.".
    static func normalizedDomain(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }
        let withScheme = s.contains("://") ? s : "https://" + s
        if let host = BrowserURL.domain(of: withScheme) { return host }
        // Fallback for inputs URL(string:) can't parse: take the first path
        // segment and drop a leading www.
        var host = s.split(separator: "/").first.map(String.init) ?? s
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    // MARK: - Window title keywords

    private func keywordsSection(state: AppState) -> some View {
        PorcelainSection(eyebrow: "Window Title Contains") {
            Text("A window whose title contains any of these is never captured. Matching is case-insensitive, and it checks the window TITLE only — not what's on the page.")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
            ForEach(state.memoryExcludedTitleKeywords, id: \.self) { keyword in
                HStack {
                    Text(keyword).foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    Button { removeKeyword(keyword) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop excluding \(keyword)")
                }
            }
            if state.memoryExcludedTitleKeywords.isEmpty {
                Text("No keywords yet.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            HStack {
                TextField("Salary", text: $newKeyword)
                    .porcelainField()
                    .onSubmit(addKeyword)
                Button("Add", action: addKeyword)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addKeyword() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !appState.memoryExcludedTitleKeywords.contains(keyword) else { return }
        appState.memoryExcludedTitleKeywords.append(keyword)
        newKeyword = ""
    }

    private func removeKeyword(_ keyword: String) {
        appState.memoryExcludedTitleKeywords.removeAll { $0 == keyword }
    }
}
```

- [ ] **Step 3: Run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "^.*error: |\*\* BUILD|\*\* TEST|Test run with"`

Expected: BUILD SUCCEEDED, 434 tests PASS. If the compiler cannot find `NSWorkspace`, add `import AppKit` at the top of the file — `import SwiftUI` re-exports it on macOS, so this is only a fallback.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/HubMemorySectionView.swift
git commit -m "✨ feat(memory): one Exclusions sheet for apps, sites and title keywords"
```

- [ ] **Step 5: Live verification — a check that can fail**

The unit tests prove the decision function. They cannot prove the setting reaches the capture daemon. This check can come back negative in both directions.

1. Run the debug build (⌘R) and open Hub → Memory. Confirm Memory is on.
2. Open the ⋯ menu → **Exclusions…**. Confirm the sheet shows three sections, and that "Add app…" lists your **real running apps by name** (not bundle IDs, and with no background daemons in the list).
3. Pick an app you have visibly open — say TextEdit — and Done.
4. Note the current row count and let the daemon run for 60 seconds with that app visible on a display:

```bash
DB=~/Library/Application\ Support/com.omwhisper.mac.dev/memory.db
CUT=$(sqlite3 "$DB" "SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now');")
# …wait 60s, then:
sqlite3 "$DB" "SELECT appName, COUNT(*) FROM snapshots WHERE lastSeenAt > '$CUT' GROUP BY appName;"
```

**Pass:** the excluded app has **zero** rows, while *other* apps have some. Both halves matter — zero rows for everything would mean capture is simply broken, which looks identical to a working exclusion if you only check the one app.

**Note the date-comparison trap:** `datetime('now','-60 seconds')` returns `2026-08-01 13:58:42` (a space) while `lastSeenAt` is `…T13:58:02Z`, and `'T' > ' '` lexicographically — so that form matches **every row** and the filter does nothing. Always use `strftime('%Y-%m-%dT%H:%M:%SZ', …)` against this column.

5. Remove the app from the list, wait another 60 seconds, and confirm its rows come back. An exclusion that cannot be undone is its own bug.
6. Repeat step 4 with a **title keyword**: add a keyword, retitle a document to contain it, and confirm that window stops producing rows while its app's other windows keep producing them.

- [ ] **Step 6: Record the result**

Append the outcome to the Progress Tracker's S1–S6 row in `CLAUDE.md` and commit. If step 4 or 5 failed, stop and debug rather than recording the feature as shipped.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| One sheet, three lists, replacing "Excluded sites…" | 3 |
| Apps picked from running apps, stored as bundle IDs | 3 |
| Sites list moved in unchanged | 3 |
| Title keywords, case-insensitive substring | 1 (logic), 3 (UI) |
| App/title checked **before** the AX walk | 2 (steps 3b, 3d) |
| Domain check stays in `MemoryCapture.tick()` | unchanged — no task needed |
| Hardcoded floor still applies, not user-removable | 2 (pin test), 3 (not listed in UI) |
| `access`/`withMutation` on new settings | 2 (step 5) |
| Empty lists change nothing | 1 (`emptyExclusionsExcludeNothing`), 2 (`.none` defaults) |
| Blank keyword must not match everything | 1 (`blankKeywordNeverMatchesEverything`) |
| Sheet states title-only matching | 3 (keywords section copy) |
| Sheet states nothing is removed retroactively | 3 (footer copy) |
| Bundle-ID de-duplication on add | 3 (`addApp` guard) |
| Live check that can fail | 3 step 5 |

**Placeholders:** none — every code step carries full source.

**Type consistency:** `MemoryExclusions(apps:titleKeywords:)` and `.excludes(bundleID:windowTitle:)` are defined in Task 1 and used with those exact labels in Task 2. `memoryExcludedApps` / `memoryExcludedTitleKeywords` are defined in Task 2 step 5 and read in Task 3 under the same names. `captureFrontmost(exclusions:timeBudget:)` keeps `exclusions` first so `MemorySelfTest`'s no-argument call still compiles.

**One risk called out rather than designed away:** Task 2 step 3(d) duplicates the `excludedBundleIDs` check that `capture(window:…)` already performs, to skip an excluded app before its AX tree is opened. That is intentional redundancy on a privacy path — if the two ever disagree, the inner check still holds, so the failure mode is a wasted AX call, never a leak.
