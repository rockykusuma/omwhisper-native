# D4a — Porcelain Re-skin of Legacy-Themed Hub Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace native `List`/`Form` chrome in `HistoryView`, `MemoryView` (Snapshots + Chronicles),
`MeetingsSettingsView`, `VocabularySettingsView`, and `AISettingsView` with fixed, non-adaptive
Porcelain-styled layouts — closing the gap where these five hub sections currently render in
macOS's system dark/light appearance instead of the Porcelain design system, confirmed via live
screenshots on 2026-07-10 (system was in Dark Mode; these sections rendered dark while Home and
the hub chrome correctly stayed fixed-light Porcelain).

**Architecture:** `List`/`Form` on macOS draw their own opaque internal backgrounds/materials that
follow `NSAppearance` (system dark/light mode) regardless of any SwiftUI `.background()` color
declared around them — there is no supported way to force these controls' internal chrome to a
fixed hex color. `HubHomeView`/`HubMemorySectionView`'s settings bar/`PorcelainComponents.swift`
already prove the alternative: plain `ScrollView`/`VStack` layouts with `omCard()`-wrapped
sections and explicit `Color.Porcelain.*` foreground colors are genuinely non-adaptive. This plan
applies that same pattern to the five remaining sections. Per the user's explicit direction
(2026-07-10), rebuilding away from native `List`/`NavigationSplitView` selection means the new
custom rows must reimplement the accessibility floor native controls gave for free: every
tappable row becomes a real `Button` (not `.onTapGesture`, which has no default accessibility
trait), so VoiceOver and keyboard (Tab + Space/Return) can reach and activate it.

**Tech Stack:** SwiftUI (macOS 26), existing `UI/PorcelainComponents.swift` (`omCard()`, `NavRow`)
and `UI/OmColors.swift` (`Color.Porcelain.*`) — no new dependencies.

## Global Constraints

- Every `@State`/`@Bindable`/action method in the five views is a **re-skin, not a rewrite** —
  keep names, signatures, and behavior identical; only the container/text-color/background
  changes. (`docs/DESIGN_DIRECTION.md` §4 migration principle.)
- All colors come from `Color.Porcelain.*` (`UI/OmColors.swift`) — fixed values, never
  `.secondary`/`.primary`/other adaptive system colors, and never a raw hex literal outside that
  file. (`docs/DESIGN_DIRECTION.md` §4: "Fixed values, NOT adaptive.")
- Every row that responds to a tap becomes a real `Button` with `.buttonStyle(.plain)` — never
  bare `.onTapGesture` — so it is keyboard-focusable and has a VoiceOver trait by default.
- No new automated tests: this project's established convention (see `PorcelainComponents.swift`,
  `HubHomeView.swift`, `MiniPanelView.swift`) is that pure SwiftUI styling/layout is verified
  live, not unit-tested. The existing 219-test suite staying green after every task is the
  regression proof that no `@State`/action logic changed.
- Run `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test` after
  every task; it must say `** TEST SUCCEEDED **` with 219 tests before moving on.

---

### Task 1: Add `omRowCard()` to `PorcelainComponents.swift`

**Files:**
- Modify: `omwhisper-native/UI/PorcelainComponents.swift`

**Interfaces:**
- Produces: `View.omRowCard() -> some View` — a lighter card than `omCard()` (no shadow), used by
  every list row task below (Tasks 2, 3, 4).

Matches `docs/hub-concept.html`'s `.rowc` rule exactly: `background:var(--panel);
border:1px solid var(--hair);border-radius:13px;padding:13px 16px` — no shadow (unlike `.card`).

- [ ] **Step 1: Add the modifier**

Add this block after the existing `OmCardModifier`/`omCard()` extension (around line 36):

```swift
// MARK: - omRowCard

private struct OmRowCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color.Porcelain.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Color.Porcelain.hair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

extension View {
    /// hub-concept.html `.rowc`: panel bg, 1pt hair border, 13pt radius, no
    /// shadow (lighter than `omCard()`) — used for list rows (history,
    /// memory snapshots, chronicle days).
    func omRowCard() -> some View {
        modifier(OmRowCardModifier())
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/PorcelainComponents.swift
git commit -m "feat(hub): add omRowCard() modifier (D4a)"
```

---

### Task 2: Re-skin `HistoryView.swift`

**Files:**
- Modify: `omwhisper-native/UI/HistoryView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain.*` (`UI/OmColors.swift`), `View.omRowCard()` (Task 1).
- No change to `TranscriptionEntry`, `HistoryStore`, or any method signature — `reload()`,
  `loadFirstPage()`, `loadNextPageIfNeeded(current:)`, `search()`, `toggleSelect(_:)`,
  `toggleExpand(_:)`, `copy(_:)`, `delete(_:)`, `deleteSelected()`, `clearAll()`, `export(...)`,
  `formatBytes(_:)`, `autoDeleteBinding` all stay exactly as they are — only `list`, `emptyState`,
  `footer`, and `HistoryRow`'s body change.

- [ ] **Step 1: Replace `list` with a Porcelain-styled `ScrollView`**

Replace the `list` computed property (currently a `List { ForEach ... }`):

```swift
private var list: some View {
    ScrollView {
        LazyVStack(spacing: 8) {
            ForEach(entries) { entry in
                HistoryRow(
                    entry: entry,
                    isSelecting: isSelecting,
                    isSelected: entry.id.map { selectedIDs.contains($0) } ?? false,
                    isExpanded: expandedID == entry.id,
                    onToggleSelect: { toggleSelect(entry) },
                    onToggleExpand: { toggleExpand(entry) },
                    onCopy: { copy(entry) },
                    onDelete: { delete(entry) }
                )
                .onAppear { loadNextPageIfNeeded(current: entry) }
            }
        }
        .padding(16)
    }
    .background(Color.Porcelain.bg)
}
```

- [ ] **Step 2: Recolor `emptyState` and `footer`**

```swift
private var emptyState: some View {
    VStack(spacing: 8) {
        Spacer()
        Text("🕐").font(.system(size: 40))
        Text("No transcriptions yet").foregroundStyle(Color.Porcelain.dim)
        Spacer()
    }
    .frame(maxWidth: .infinity)
    .background(Color.Porcelain.bg)
}
```

In `footer`, change `.foregroundStyle(.secondary)` → `.foregroundStyle(Color.Porcelain.dim)` on
the storage-info `Text`, and wrap the returned `HStack` with `.background(Color.Porcelain.bg)`.

- [ ] **Step 3: Rebuild `HistoryRow` as a real `Button` with Porcelain colors**

Replace the whole `HistoryRow` struct:

```swift
private struct HistoryRow: View {
    let entry: TranscriptionEntry
    let isSelecting: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            isSelecting ? onToggleSelect() : onToggleExpand()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.Porcelain.emerald : Color.Porcelain.dim)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .lineLimit(isExpanded ? nil : 2)
                        .foregroundStyle(Color.Porcelain.ink)
                    Text("\(entry.createdAt) · \(entry.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    if isExpanded, !isSelecting {
                        HStack {
                            Button("Copy", action: onCopy)
                            Button("Delete", role: .destructive, action: onDelete)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .omRowCard()
        .accessibilityLabel("\(entry.text), \(entry.createdAt), \(entry.wordCount) words")
    }
}
```

- [ ] **Step 4: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: `** TEST SUCCEEDED **`, 219 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/HistoryView.swift
git commit -m "feat(hub): re-skin HistoryView to fixed Porcelain (D4a)"
```

---

### Task 3: Re-skin `MemoryView.swift` (Snapshots tab)

**Files:**
- Modify: `omwhisper-native/UI/MemoryView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain.*`, `View.omRowCard()` (Task 1).
- No change to `MemorySnapshot`, `MemoryStore`, or any method — `reload()`, `loadFirstPage()`,
  `loadNextPageIfNeeded(current:)`, `search()`, `copy(_:)`, `delete(_:)`, `clearAll()`,
  `formatBytes(_:)` all stay exactly as they are. The top-level `Tab` picker (`.pickerStyle
  (.segmented)`) is left as native chrome — it's a two-item control, not list/form content, and
  isn't part of the dark-render bug shown in the screenshots.

- [ ] **Step 1: Replace `list` (inside `MemorySnapshotsView`) with a Porcelain-styled `ScrollView`**

Same transformation as Task 2 Step 1, applied to `MemorySnapshotsView.list`:

```swift
private var list: some View {
    ScrollView {
        LazyVStack(spacing: 8) {
            ForEach(entries) { entry in
                MemorySnapshotRow(
                    entry: entry,
                    isExpanded: expandedID == entry.id,
                    onToggleExpand: { expandedID = expandedID == entry.id ? nil : entry.id },
                    onCopy: { copy(entry) },
                    onDelete: { delete(entry) }
                )
                .onAppear { loadNextPageIfNeeded(current: entry) }
            }
        }
        .padding(16)
    }
    .background(Color.Porcelain.bg)
}
```

- [ ] **Step 2: Recolor `emptyState` and `footer`**

Same pattern as Task 2 Step 2: `.foregroundStyle(.secondary)` → `.foregroundStyle(Color.Porcelain.dim)`,
add `.background(Color.Porcelain.bg)` to both.

- [ ] **Step 3: Rebuild `MemorySnapshotRow` as a real `Button`**

```swift
private struct MemorySnapshotRow: View {
    let entry: MemorySnapshot
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onToggleExpand) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.appName).fontWeight(.medium).foregroundStyle(Color.Porcelain.ink)
                    Text(entry.windowTitle).foregroundStyle(Color.Porcelain.dim)
                }
                .font(.callout)
                Text(entry.content)
                    .lineLimit(isExpanded ? nil : 2)
                    .font(.body)
                    .foregroundStyle(Color.Porcelain.ink)
                HStack(spacing: 4) {
                    Text(entry.lastSeenAt)
                    if !entry.url.isEmpty {
                        Text("· \(entry.url)")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
                if isExpanded {
                    HStack {
                        Button("Copy", action: onCopy)
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .omRowCard()
        .accessibilityLabel("\(entry.appName), \(entry.windowTitle), \(entry.lastSeenAt)")
    }
}
```

- [ ] **Step 4: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: `** TEST SUCCEEDED **`, 219 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/MemoryView.swift
git commit -m "feat(hub): re-skin MemoryView snapshots to fixed Porcelain (D4a)"
```

---

### Task 4: Re-skin `MemoryChroniclesView.swift`

**Files:**
- Modify: `omwhisper-native/UI/MemoryChroniclesView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain.*`, `View.omRowCard()` (Task 1).
- No change to `MemoryChronicle`, `MemoryStore.listChronicles`, `appState.regenerateChronicle`,
  or `Chronicler.dayString()` — `load()` and `generateTodaysChronicle()` stay exactly as they are.
  `selectedDay: String?` stays the source of truth; only how it's set (real `Button` instead of
  `List` selection binding) and how the row looks change.

- [ ] **Step 1: Replace the sidebar `List` with a Porcelain-styled day picker**

Replace the `NavigationSplitView`'s sidebar closure (currently `List(chronicles, selection:
$selectedDay) { ... }`):

```swift
NavigationSplitView {
    ScrollView {
        LazyVStack(spacing: 6) {
            ForEach(chronicles) { chronicle in
                Button {
                    selectedDay = chronicle.day
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chronicle.day)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.Porcelain.ink)
                        Text("\(chronicle.snapshotCount) snapshot\(chronicle.snapshotCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(selectedDay == chronicle.day ? Color.Porcelain.accentTint2 : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chronicle.day), \(chronicle.snapshotCount) snapshots")
                .accessibilityAddTraits(selectedDay == chronicle.day ? .isSelected : [])
            }
        }
        .padding(10)
    }
    .background(Color.Porcelain.bg)
    .navigationSplitViewColumnWidth(min: 160, ideal: 200)
} detail: {
    detail
}
```

(Keep the existing `.toolbar { ... }`, `.task { load() }`, and `.alert(...)` modifiers on
`NavigationSplitView` exactly as they are — only the sidebar closure's content changes.)

- [ ] **Step 2: Recolor the detail pane and empty state**

In `detail`, wrap the `ScrollView`'s `Text(.init(chronicle.summary))` case with a background and
fixed ink color:

```swift
ScrollView {
    Text(.init(chronicle.summary))
        .textSelection(.enabled)
        .foregroundStyle(Color.Porcelain.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
}
.background(Color.Porcelain.bg)
```

Change the `Text("Select a day").foregroundStyle(.secondary)` case to
`.foregroundStyle(Color.Porcelain.dim)`, and in `emptyState`, change `.foregroundStyle(.secondary)`
→ `.foregroundStyle(Color.Porcelain.dim)`. Add `.background(Color.Porcelain.bg)` to both the
`Text("Select a day")` case and `emptyState`.

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: `** TEST SUCCEEDED **`, 219 tests.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/MemoryChroniclesView.swift
git commit -m "feat(hub): re-skin MemoryChroniclesView to fixed Porcelain (D4a)"
```

---

### Task 5: Re-skin `MeetingsSettingsView.swift`

**Files:**
- Modify: `omwhisper-native/UI/MeetingsSettingsView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain.*`, `View.omCard()` (existing, `PorcelainComponents.swift`).
- No change to `appState.meetingsEnabled` or any binding.

- [ ] **Step 1: Replace the `Form` with an `omCard()`-wrapped `ScrollView`**

Replace the whole `body`:

```swift
var body: some View {
    @Bindable var state = appState
    return ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Detect and record meetings", isOn: $state.meetingsEnabled)
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
            Text("When a recognized call app is active, you'll be asked for consent before anything is recorded — a 10-second countdown, and no response means nothing is recorded. Recordings stay on this Mac.")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
        }
        .padding(16)
        .omCard()
        .padding(20)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.Porcelain.bg)
}
```

- [ ] **Step 2: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: `** TEST SUCCEEDED **`, 219 tests.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/MeetingsSettingsView.swift
git commit -m "feat(hub): re-skin MeetingsSettingsView to fixed Porcelain (D4a)"
```

---

### Task 6: Re-skin `VocabularySettingsView.swift`

**Files:**
- Modify: `omwhisper-native/UI/VocabularySettingsView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain.*`, `View.omCard()`.
- No change to `trimmed(_:)`, `addWord()`, `removeWord(_:)`, `replaceWord(_:with:)`,
  `addReplacement()`, `removeReplacement(_:)`, `saveReplacement(_:)` — identical.

- [ ] **Step 1: Replace the `Form` with three `omCard()`-wrapped sections**

Replace the whole `body`:

```swift
var body: some View {
    @Bindable var state = appState
    return ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CUSTOM WORDS").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Color.Porcelain.dim)
                ForEach(state.customVocabulary, id: \.self) { word in
                    VocabularyWordRow(
                        word: word,
                        onSave: { updated in replaceWord(word, with: updated) },
                        onDelete: { removeWord(word) }
                    )
                }
                HStack {
                    TextField("Add a word or phrase", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .disabled(trimmed(newWord).isEmpty)
                }
            }
            .padding(16)
            .omCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("AUTO-REPLACEMENTS").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Color.Porcelain.dim)
                ForEach(state.wordReplacements, id: \.from) { rule in
                    ReplacementRuleRow(
                        rule: rule,
                        onSave: { updated in saveReplacement(updated) },
                        onDelete: { removeReplacement(rule) }
                    )
                }
                HStack {
                    TextField("Replace…", text: $newFrom).textFieldStyle(.roundedBorder)
                    Text("→").foregroundStyle(Color.Porcelain.dim)
                    TextField("With…", text: $newTo)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addReplacement)
                    Button("Add", action: addReplacement)
                        .disabled(trimmed(newFrom).isEmpty)
                }
            }
            .padding(16)
            .omCard()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Fuzzy-match near-miss words", isOn: $state.fuzzyVocabCorrection)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                Text("Auto-correct near-misses to your terms. Off by default.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
                Text("Examples: \"okay\" → \"OK\" · \"gonna\" → \"going to\" · \"OmWhisper\" as a custom word")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
                Divider().padding(.vertical, 4)
                Toggle("Use On-Screen Context", isOn: $state.contextAwareDictationEnabled)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                Text("Reads the frontmost window's visible text when dictation starts, to bias recognition toward names and terms already on screen. Nothing is stored. Off by default.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            .padding(16)
            .omCard()
        }
        .padding(20)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.Porcelain.bg)
}
```

- [ ] **Step 2: Recolor `VocabularyWordRow` and `ReplacementRuleRow`**

In both private row structs, change every `.foregroundStyle(.secondary)` →
`.foregroundStyle(Color.Porcelain.dim)`, and add `.foregroundStyle(Color.Porcelain.ink)` to the
non-editing `Text(word)` / `Text(rule.from)` / `Text(rule.to)` cases. Leave `TextField`,
`Button`, and all existing logic untouched.

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: `** TEST SUCCEEDED **`, 219 tests.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/VocabularySettingsView.swift
git commit -m "feat(hub): re-skin VocabularySettingsView to fixed Porcelain (D4a)"
```

---

### Task 7: Re-skin `AISettingsView.swift`

**Files:**
- Modify: `omwhisper-native/UI/AISettingsView.swift`

**Interfaces:**
- Consumes: `Color.Porcelain.*`, `View.omCard()`.
- No change to `trimmed(_:)`, `addStyle()`, `removeStyle(_:)` — identical.

- [ ] **Step 1: Replace the `Form` with four `omCard()`-wrapped sections**

Replace the whole `body`:

```swift
var body: some View {
    @Bindable var state = appState
    return ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("BACKEND").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Color.Porcelain.dim)
                Picker("Polish backend", selection: $state.polishBackend) {
                    Text("Disabled").tag(PolishBackendKind.disabled)
                    Text("System (Apple Intelligence)").tag(PolishBackendKind.system)
                }
                .pickerStyle(.radioGroup)
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
            }
            .padding(16)
            .omCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("SMART DICTATION & POLISH SELECTED TEXT").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Color.Porcelain.dim)
                Picker("Default style", selection: $state.activePolishStyleID) {
                    ForEach(PolishStyles.all(customStyles: state.customPolishStyles)) { style in
                        Text(style.name).tag(style.id)
                    }
                }
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
                if appState.activePolishStyle?.requiresTargetLanguage == true {
                    Picker("Target language", selection: $state.translateTargetLanguage) {
                        ForEach(translateLanguages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                }
                Text("Cmd+Shift+B always polishes what you just said. Cmd+Shift+P polishes whatever's selected in the frontmost app.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            .padding(16)
            .omCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("BUILT-IN STYLES").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Color.Porcelain.dim)
                ForEach(PolishStyles.builtIns) { style in
                    Text(style.name).foregroundStyle(Color.Porcelain.ink)
                }
            }
            .padding(16)
            .omCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("CUSTOM STYLES").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Color.Porcelain.dim)
                ForEach(state.customPolishStyles) { style in
                    HStack {
                        Text(style.name).foregroundStyle(Color.Porcelain.ink)
                        Spacer()
                        Button {
                            removeStyle(style)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.Porcelain.dim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(style.name)")
                    }
                }
                VStack(alignment: .leading) {
                    TextField("Style name", text: $newStyleName).textFieldStyle(.roundedBorder)
                    TextField("Prompt", text: $newStylePrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Button("Add Style", action: addStyle)
                        .disabled(trimmed(newStyleName).isEmpty || trimmed(newStylePrompt).isEmpty)
                }
            }
            .padding(16)
            .omCard()
        }
        .padding(20)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.Porcelain.bg)
}
```

- [ ] **Step 2: Build and run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`
Expected: `** TEST SUCCEEDED **`, 219 tests.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/AISettingsView.swift
git commit -m "feat(hub): re-skin AISettingsView to fixed Porcelain (D4a)"
```

---

### Task 8: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Append a D4a entry to the Phase D Progress Tracker row**

Summarize: all five sections (History, Memory Snapshots + Chronicles, Meetings, Vocabulary, AI
Polish) rebuilt from native `List`/`Form` to fixed Porcelain (`omCard()`/`omRowCard()`), every
tappable row is now a real `Button` (keyboard + VoiceOver accessible, closing part of D4's
"keyboard navigation"/"VoiceOver labels" goals as a side effect of the rebuild); note what's
still open for D4b (motion/spring family, remaining explicit VoiceOver labels/hints, Dynamic
Type check, contrast verification) and that this has **not yet been live-verified** on real
hardware.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: mark D4a (Porcelain re-skin) shipped"
```
