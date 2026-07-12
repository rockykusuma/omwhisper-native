# F5 Brain-dump Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a brain-dump dictation mode — ramble for minutes, get a structured email / ticket / outline / to-do / agenda / journal pasted into the frontmost app.

**Architecture:** A third `SessionMode` on the existing capture pipeline. On stop, a `BrainDumpStructurer` map-reduces the ramble (chunk → notes → target shape) through `activePolishBackend()`, grounded in S2 screen context, then pastes — falling back to the raw ramble on any failure. Shapes reuse `PolishStyle` + its CRUD, stored separately.

**Tech Stack:** Swift 6, SwiftUI, `@Observable` AppState, Foundation Models / Ollama / Cloud via `PolishBackend`.

## Global Constraints

- **Xcode scheme is `omwhisper-native`.** Build/test: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`.
- **Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** — mark pure enums/helpers `nonisolated` (e.g. `BrainDumpStructurer`, `BrainDumpShapes`, `SessionMode`), matching `MeetingSummarizer`.
- **Fallback rule (absolute):** any structuring failure — backend Disabled/unavailable, timeout, empty result — pastes the **raw ramble**. Never drop the user's words.
- **Off unless a polish backend is enabled** — `activePolishBackend()` returns nil → raw paste.
- **Map-reduce budget:** every `polish()` call stays ≤1800 chars, matching `MeetingSummarizer`/`Chronicler` (SystemLLM's ~2000-char/5s envelope).
- **No new overlay colors** (OVERLAY_SPEC §2) — brain-dump reuses the existing `.polishing` phase while structuring.
- **Hotkey:** ⌘⇧D = kVK_ANSI_D = **keyCode 2** (V/B/P = 9/11/35 already used).
- **Fixed UUIDs** for all built-in shapes + the hidden chunk-notes style — never regenerate (they back `activeBrainDumpShapeID` across relaunches).
- Full suite is currently **290** tests; must stay green after every task.

---

## File Structure

| File | Responsibility |
|---|---|
| `omwhisper-native/Polish/BrainDumpShapes.swift` | New — 6 built-in shape `PolishStyle`s + hidden chunk-notes style + `all`/`shape` helpers |
| `omwhisper-native/Polish/BrainDumpStructurer.swift` | New — `chunk` + `structure` map-reduce |
| `omwhisper-nativeTests/BrainDumpStructurerTests.swift` | New — `chunk` + `structure` branch tests |
| `omwhisper-native/AppState.swift` | `SessionMode` enum, brain-dump settings, `beginBrainDump()`, ⌘⇧D hotkey, `brainDumpStructured`, `stopDictation` hook, `sessionScreenTerms` |
| `omwhisper-native/UI/OverlayView.swift` | Word-count + elapsed content in `FullStyleOverlay` for brain-dump |
| `omwhisper-native/UI/AISettingsView.swift` | Brain-dump shapes subsection (active picker + CRUD) |
| `omwhisper-native/UI/MiniPanelView.swift` | Brain-dump row (shape dropdown + start) |

---

## Task 1: BrainDumpShapes + BrainDumpStructurer (pure core)

**Files:**
- Create: `omwhisper-native/Polish/BrainDumpShapes.swift`
- Create: `omwhisper-native/Polish/BrainDumpStructurer.swift`
- Test: `omwhisper-nativeTests/BrainDumpStructurerTests.swift`

**Interfaces:**
- Produces:
  - `BrainDumpShapes.builtIns: [PolishStyle]` (6), `.chunkNotesStyle: PolishStyle`, `.all(customShapes:) -> [PolishStyle]`, `.shape(id:customShapes:) -> PolishStyle?`
  - `BrainDumpStructurer.chunk(_:limit:) -> [String]`, `.structure(transcript:shape:context:polish:) async throws -> String`

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/BrainDumpStructurerTests.swift`:

```swift
import Testing
@testable import OmWhisper

struct BrainDumpStructurerTests {
    // Echoes which style processed what, so we can assert the map/reduce path.
    struct EchoBackend: PolishBackend {
        func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
            "[\(style.name)] \(text)"
        }
    }

    @Test func chunkPacksWordsUnderLimit() {
        let groups = BrainDumpStructurer.chunk("one two three four five", limit: 9)
        #expect(groups == ["one two", "three", "four five"])
    }

    @Test func chunkKeepsOversizeWordAsOwnGroup() {
        let groups = BrainDumpStructurer.chunk("hi supercalifragilistic ok", limit: 5)
        #expect(groups == ["hi", "supercalifragilistic", "ok"])
    }

    @Test func singleChunkSkipsMapAndAppliesShapeDirectly() async throws {
        let shape = BrainDumpShapes.builtIns[0]  // Email
        let out = try await BrainDumpStructurer.structure(
            transcript: "quick note", shape: shape, context: nil, polish: EchoBackend())
        // One chunk → no chunk-notes pass; shape applied to the raw transcript.
        #expect(out == "[\(shape.name)] quick note")
    }

    @Test func multiChunkMapsThenReduces() async throws {
        let shape = BrainDumpShapes.builtIns[0]
        let long = String(repeating: "word ", count: 800)  // > one 1800-char chunk
        let out = try await BrainDumpStructurer.structure(
            transcript: long, shape: shape, context: nil, polish: EchoBackend())
        // Reduce input is the joined chunk-notes, so the final output is the shape
        // applied to text containing the chunk-notes style marker.
        #expect(out.hasPrefix("[\(shape.name)] "))
        #expect(out.contains("[\(BrainDumpShapes.chunkNotesStyle.name)]"))
    }

    @Test func contextIsAppendedToReduceInput() async throws {
        let shape = BrainDumpShapes.builtIns[0]
        let out = try await BrainDumpStructurer.structure(
            transcript: "note", shape: shape, context: "Target app: Mail", polish: EchoBackend())
        #expect(out.contains("Target app: Mail"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "BrainDump|error:"`
Expected: FAIL — `Cannot find 'BrainDumpStructurer'`/`BrainDumpShapes` in scope.

- [ ] **Step 3: Create BrainDumpShapes.swift**

```swift
//
//  BrainDumpShapes.swift
//  OmWhisper
//
//  Built-in target shapes for brain-dump mode. Each shape IS a named structuring
//  prompt (reusing PolishStyle). Fixed UUIDs so activeBrainDumpShapeID survives
//  relaunches. Kept OUT of PolishStyles.builtIns — brain-dump shapes and polish
//  styles are different concepts and never share a picker. The chunk-notes style
//  is hidden (map step of the map-reduce), same pattern as MeetingSummarizer.
//

import Foundation

nonisolated enum BrainDumpShapes {
    static let builtIns: [PolishStyle] = [
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000001")!,
            name: "Email",
            prompt: """
                Turn the following (a rambling spoken brain-dump, or terse notes from \
                one) into a clear, ready-to-send email. Add a subject line only if \
                useful. Keep the user's intent; drop filler and false starts. \
                Output ONLY the email.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000002")!,
            name: "Ticket",
            prompt: """
                Turn the following into a work/bug ticket in markdown with sections: \
                **Summary**, **Steps to reproduce** (numbered), **Expected result**, \
                **Actual result**. Omit a section only if there is genuinely nothing \
                for it. Output ONLY the ticket.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000003")!,
            name: "Outline",
            prompt: """
                Turn the following into a structured markdown outline — nested bullet \
                points grouped by topic. Preserve every distinct idea; drop filler. \
                Output ONLY the outline.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000004")!,
            name: "To-do list",
            prompt: """
                Turn the following into a markdown checklist of concrete, actionable \
                to-do items (`- [ ] …`), one action each, in a sensible order. Drop \
                filler. Output ONLY the list.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000005")!,
            name: "Meeting agenda",
            prompt: """
                Turn the following into a meeting agenda: a one-line purpose, then a \
                numbered list of agenda items (with sub-bullets for talking points \
                where useful). Output ONLY the agenda.
                """,
            isBuiltIn: true),
        PolishStyle(
            id: UUID(uuidString: "F5B0DA00-0000-4000-8000-000000000006")!,
            name: "Journal",
            prompt: """
                Turn the following into a clean first-person journal entry: flowing \
                prose in a few short paragraphs, preserving the user's voice and \
                reflections. Drop filler and false starts. Output ONLY the entry.
                """,
            isBuiltIn: true),
    ]

    /// Hidden map-step style — condenses each chunk of a long ramble to notes so
    /// the reduce (shape) call stays inside SystemLLM's budget. Never shown in a picker.
    static let chunkNotesStyle = PolishStyle(
        id: UUID(uuidString: "F5B0DA00-0000-4000-8000-0000000000FF")!,
        name: "Brain-dump Chunk Notes",
        prompt: """
            Extract the key points and concrete content from this portion of a spoken \
            brain-dump into terse notes (short bullet points). Preserve names, numbers, \
            and specifics. No preamble, just the notes.
            """,
        isBuiltIn: true)

    static func all(customShapes: [PolishStyle]) -> [PolishStyle] {
        builtIns + customShapes
    }

    static func shape(id: UUID, customShapes: [PolishStyle]) -> PolishStyle? {
        all(customShapes: customShapes).first { $0.id == id }
    }
}
```

- [ ] **Step 4: Create BrainDumpStructurer.swift**

```swift
//
//  BrainDumpStructurer.swift
//  OmWhisper
//
//  Map-reduce a spoken brain-dump into a structured artifact, mirroring
//  MeetingSummarizer for the same reason: a multi-minute ramble far exceeds
//  SystemLLM's ~2,000-char/5s envelope. Short rambles (one chunk) skip the map
//  and apply the shape prompt directly. Effectful structure() propagates the
//  first polish() failure to the caller, which falls back to the raw ramble.
//

import Foundation

nonisolated enum BrainDumpStructurer {
    static let chunkCharLimit = 1_800
    static let reduceCharLimit = 1_800

    /// Pure: greedily pack words into <=limit-char groups (verbatim from
    /// MeetingSummarizer.chunk — no content lost even for one long line).
    static func chunk(_ text: String, limit: Int = chunkCharLimit) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var groups: [String] = []
        var current = ""
        for word in words {
            let added = word.count + (current.isEmpty ? 0 : 1)
            if !current.isEmpty && current.count + added > limit {
                groups.append(current)
                current = word
            } else {
                current = current.isEmpty ? word : current + " " + word
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Map (long only) → reduce into `shape`. `context` (target app + screen terms)
    /// is appended to the reduce input. Returns "" for empty input.
    static func structure(transcript: String, shape: PolishStyle,
                          context: String?, polish: PolishBackend) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let chunks = chunk(trimmed)
        let material: String
        if chunks.count <= 1 {
            material = trimmed
        } else {
            var notes: [String] = []
            for group in chunks {
                notes.append(try await polish.polish(group, style: chunkNotesStyle, targetLanguage: nil))
            }
            material = String(notes.joined(separator: "\n").prefix(reduceCharLimit))
        }

        let input = context.map { "\(material)\n\n[Context: \($0)]" } ?? material
        let out = try await polish.polish(input, style: shape, targetLanguage: nil)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let chunkNotesStyle = BrainDumpShapes.chunkNotesStyle
}
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "BrainDumpStructurerTests|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: PASS; test count **295** (290 + 5).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Polish/BrainDumpShapes.swift omwhisper-native/Polish/BrainDumpStructurer.swift omwhisper-nativeTests/BrainDumpStructurerTests.swift
git commit -m "✨ feat(braindump): shapes catalog + map-reduce structurer"
```

---

## Task 2: SessionMode refactor (behavior-preserving)

Replace the `isSmartDictationSession: Bool` with a `SessionMode` enum, no behavior change. Suite staying green is the proof.

**Files:**
- Modify: `omwhisper-native/AppState.swift` (lines ~57–63 for the enum home; ~763, ~897–915, ~919–931, ~1136, ~1171)

**Interfaces:**
- Produces: `nonisolated enum SessionMode { case normal, smart, brainDump }`; `AppState.sessionMode: SessionMode` (`private(set)`, observable); `toggleOrStop(mode:)`.

- [ ] **Step 1: Add the SessionMode enum**

In `AppState.swift`, next to the `OverlayPhase` enum (~line 57), add:

```swift
nonisolated enum SessionMode { case normal, smart, brainDump }
```

- [ ] **Step 2: Replace the stored flag**

Replace `private var isSmartDictationSession = false` (~line 763) with:

```swift
    /// The current dictation session's mode — drives what stopDictation does with
    /// the text and what the overlay renders. private(set) so the overlay observes it.
    private(set) var sessionMode: SessionMode = .normal
```

- [ ] **Step 3: Retarget toggleOrStop + its callers**

Change `toggleOrStop(smart: Bool)` (~line 897) to take a mode, and update the `.idle` case:

```swift
    private func toggleOrStop(mode: SessionMode) {
        switch dictation {
        case .idle:
            overlayPreviewTask?.cancel()
            pttPressedAt = nil
            sessionMode = mode
            dictation = .starting
            sessionOverlayStyle = overlayStyle
            overlay.show(appState: self)
            contextCaptureTask = startContextCapture(enabled: contextAwareDictationEnabled)
            Task { await startDictation() }
        case .recording:
            Task { await stopDictation() }
        case .starting, .finalizing:
            break
        }
    }
```

Update `toggleDictation()` (~line 886) body to `toggleOrStop(mode: .normal)` and `beginSmartDictation()` (~line 893) body to `toggleOrStop(mode: .smart)`.

- [ ] **Step 4: Set mode on the PTT path**

In `beginPushToTalk()` (~line 919), add `sessionMode = .normal` right after `pttPressedAt = .now` (PTT is always normal dictation; be explicit rather than inheriting a stale mode):

```swift
        pttPressedAt = .now
        sessionMode = .normal
```

- [ ] **Step 5: Update the stopDictation reads**

Line ~1136: change `if phase == .pasting, isSmartDictationSession, !Self.tooShortForPolish(text) {` to `if phase == .pasting, sessionMode == .smart, !Self.tooShortForPolish(text) {`.

Line ~1171: change `isSmartDictationSession = false` to `sessionMode = .normal`.

- [ ] **Step 6: Build + full suite (regression)**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`, **295** tests (no behavior change).

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "♻️ refactor(dictation): SessionMode enum replaces isSmartDictationSession bool"
```

---

## Task 3: AppState brain-dump wiring

Settings, hotkey, `beginBrainDump()`, the structuring path, and the `stopDictation` hook. No new unit tests (hardware/LLM path — verified live; pure structurer already covered).

**Files:**
- Modify: `omwhisper-native/AppState.swift` (settings block ~248; hotkeys ~702/796; `beginSmartDictation` region ~895; `stopDictation` ~1136; `polishedText` region ~1284; `startDictation` context ~1055; `SettingsKeys` ~1418)

**Interfaces:**
- Consumes: `BrainDumpShapes`, `BrainDumpStructurer.structure`, `activePolishBackend()`, `SessionMode` (Task 2).
- Produces: `AppState.brainDumpShapes: [PolishStyle]`, `.activeBrainDumpShapeID: UUID`, `.activeBrainDumpShape: PolishStyle?`, `.beginBrainDump()`.

- [ ] **Step 1: Add brain-dump settings**

In `AppState.swift`, after the `customPolishStyles` computed property (~line 261), add (mirroring the existing style settings, with `access`/`withMutation`):

```swift
    var activeBrainDumpShapeID: UUID {
        get {
            access(keyPath: \.activeBrainDumpShapeID)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.activeBrainDumpShapeID),
                  let id = UUID(uuidString: raw) else { return BrainDumpShapes.builtIns[0].id }
            return id
        }
        set {
            withMutation(keyPath: \.activeBrainDumpShapeID) {
                UserDefaults.standard.set(newValue.uuidString, forKey: SettingsKeys.activeBrainDumpShapeID)
            }
        }
    }
    var activeBrainDumpShape: PolishStyle? {
        BrainDumpShapes.shape(id: activeBrainDumpShapeID, customShapes: brainDumpShapes)
    }
    var brainDumpShapes: [PolishStyle] {
        get {
            access(keyPath: \.brainDumpShapes)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.brainDumpShapes) else { return [] }
            return (try? JSONDecoder().decode([PolishStyle].self, from: data)) ?? []
        }
        set {
            withMutation(keyPath: \.brainDumpShapes) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.brainDumpShapes)
            }
        }
    }
```

- [ ] **Step 2: Add the SettingsKeys**

In the `SettingsKeys` enum (~line 1418, next to `customPolishStyles`), add:

```swift
    static let activeBrainDumpShapeID = "activeBrainDumpShapeID"
    static let brainDumpShapes = "brainDumpShapes"
```

- [ ] **Step 3: Add the ⌘⇧D hotkey**

After the `polishSelectedTextHotkey` declaration (~line 715), add:

```swift
    /// kVK_ANSI_D — Brain-dump mode: ramble, then structure into the active shape.
    @ObservationIgnored private lazy var brainDumpHotkey = GlobalHotkey(
        keyCode: 2,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.beginBrainDump()
    }
```

In the hotkey-start block (where `smartDictationHotkey.start()` is, ~line 796), add `brainDumpHotkey.start()`.

- [ ] **Step 4: Add beginBrainDump()**

After `beginSmartDictation()` (~line 895), add:

```swift
    /// ⌘⇧D — capture a long ramble, then structure it into the active brain-dump
    /// shape on stop. Toggle-style, like ⌘⇧V/⌘⇧B.
    func beginBrainDump() {
        toggleOrStop(mode: .brainDump)
    }
```

- [ ] **Step 5: Stash screen terms for the structuring context**

Add a stored property near `sessionMode` (~line 763):

```swift
    /// S2 salient screen terms captured at session start, reused by brain-dump's
    /// structuring prompt (they already bias the engine at capture time).
    private var sessionScreenTerms: [String] = []
```

In `startDictation()`, right after `let screenTerms = await contextCaptureTask?.value ?? []` (~line 1055), add:

```swift
            sessionScreenTerms = screenTerms
```

- [ ] **Step 6: Add the structuring method**

After `polishedText(for:)` (~line 1302), add:

```swift
    /// Structure a brain-dump ramble into the active shape via the active backend,
    /// grounded in the target app + captured screen terms. Any failure returns the
    /// raw ramble — words are never dropped (same rule as polishedText).
    private func brainDumpStructured(for original: String) async -> String {
        if polishBackend == .system, !SystemLLM.isAvailable() {
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = "Apple Intelligence is off — enable it in Settings > AI to structure brain-dumps, or pasted raw text for now."
            }
            return original
        }
        guard let backend = activePolishBackend(), let shape = activeBrainDumpShape else { return original }
        var parts: [String] = []
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName { parts.append("Target app: \(app)") }
        if !sessionScreenTerms.isEmpty { parts.append("On-screen terms: \(sessionScreenTerms.prefix(20).joined(separator: ", "))") }
        let context = parts.isEmpty ? nil : parts.joined(separator: ". ")
        do {
            return try await BrainDumpStructurer.structure(transcript: original, shape: shape, context: context, polish: backend)
        } catch {
            log.error("brainDumpStructured — failed: \(error)")
            return original
        }
    }
```

- [ ] **Step 7: Hook it into stopDictation**

Replace the smart-only polish block (~line 1136):

```swift
        if phase == .pasting, sessionMode == .smart, !Self.tooShortForPolish(text) {
            overlayPhase = .polishing
            text = await polishedText(for: text)
            overlayPhase = phase
        }
```

with a mode switch:

```swift
        if phase == .pasting {
            switch sessionMode {
            case .smart where !Self.tooShortForPolish(text):
                overlayPhase = .polishing
                text = await polishedText(for: text)
                overlayPhase = phase
            case .brainDump:
                overlayPhase = .polishing
                text = await brainDumpStructured(for: text)
                overlayPhase = phase
            default:
                break
            }
        }
```

- [ ] **Step 8: Build + full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`, **295** tests.

- [ ] **Step 9: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(braindump): AppState wiring — settings, ⌘⇧D, structuring hook"
```

---

## Task 4: Relaxed overlay (word count + elapsed)

While a brain-dump is recording, show "N words · M:SS" instead of the 2-line transcript.

**Files:**
- Modify: `omwhisper-native/UI/OverlayView.swift` (`FullStyleOverlay`, ~lines 132–174)
- Modify: `omwhisper-native/AppState.swift` (expose `recordingStartedAt`)

**Interfaces:**
- Consumes: `appState.sessionMode` (Task 2), `appState.recordingStartedAt`, `appState.finalizedTranscript`/`volatileTranscript`.

- [ ] **Step 1: Expose recordingStartedAt**

In `AppState.swift`, find `private var recordingStartedAt` (search `recordingStartedAt`) and change it to `private(set) var recordingStartedAt` so the overlay can read it. (It's a `ContinuousClock.Instant?`.)

- [ ] **Step 2: Add the brain-dump zone + swap it in**

In `FullStyleOverlay` (`OverlayView.swift`), add a computed view after `transcriptZone` (~line 174):

```swift
    private var brainDumpZone: some View {
        let words = (appState.finalizedTranscript + " " + appState.volatileTranscript)
            .split(whereSeparator: { $0.isWhitespace }).count
        return TimelineView(.periodic(from: .now, by: 1)) { _ in
            let secs = appState.recordingStartedAt.map { Int($0.duration(to: .now).components.seconds) } ?? 0
            Text("\(words) words · \(secs / 60):\(String(format: "%02d", secs % 60))")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.omGlyphCore)
        }
    }
```

In `body`, replace `transcriptZone` (~line 142) with a conditional:

```swift
                if appState.sessionMode == .brainDump, appState.dictation == .recording {
                    brainDumpZone
                } else {
                    transcriptZone
                }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/OverlayView.swift omwhisper-native/AppState.swift
git commit -m "💄 feat(braindump): relaxed overlay shows word count + elapsed"
```

---

## Task 5: AI settings — brain-dump shapes subsection

Active-shape picker + shape CRUD, mirroring the custom-polish-style section.

**Files:**
- Modify: `omwhisper-native/UI/AISettingsView.swift` (add `@State` fields ~19; a new `PorcelainSection` after Custom Styles ~168; `addShape`/`removeShape` after `removeStyle` ~231)

**Interfaces:**
- Consumes: `state.activeBrainDumpShapeID`, `state.brainDumpShapes` (Task 3); `BrainDumpShapes`.

- [ ] **Step 1: Add editor state fields**

In `AISettingsView`, next to `newStyleName`/`newStylePrompt` (~line 19), add:

```swift
    @State private var newShapeName = ""
    @State private var newShapePrompt = ""
```

- [ ] **Step 2: Add the Brain-dump section**

After the "Custom Styles" `PorcelainSection` (~line 168, before the closing `}` of the outer container), add:

```swift
            PorcelainSection(eyebrow: "Brain-dump") {
                Picker("Default shape", selection: $state.activeBrainDumpShapeID) {
                    ForEach(BrainDumpShapes.all(customShapes: state.brainDumpShapes)) { shape in
                        Text(shape.name).tag(shape.id)
                    }
                }
                .tint(Color.Porcelain.emerald)
                ForEach(state.brainDumpShapes) { shape in
                    HStack {
                        Text(shape.name).foregroundStyle(Color.Porcelain.ink)
                        Spacer()
                        Button { removeShape(shape) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.Porcelain.dim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(shape.name)")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Shape name", text: $newShapeName).porcelainField()
                    TextField("Prompt", text: $newShapePrompt, axis: .vertical)
                        .porcelainField()
                        .lineLimit(2...4)
                    Button("Add Shape", action: addShape)
                        .disabled(trimmed(newShapeName).isEmpty || trimmed(newShapePrompt).isEmpty)
                }
            }
```

- [ ] **Step 3: Add the CRUD helpers**

After `removeStyle(_:)` (~line 231), add:

```swift
    private func addShape() {
        let name = trimmed(newShapeName)
        let prompt = trimmed(newShapePrompt)
        guard !name.isEmpty, !prompt.isEmpty else { return }
        appState.brainDumpShapes.append(PolishStyle(id: UUID(), name: name, prompt: prompt, isBuiltIn: false))
        newShapeName = ""
        newShapePrompt = ""
    }

    private func removeShape(_ shape: PolishStyle) {
        appState.brainDumpShapes.removeAll { $0.id == shape.id }
        // Fall back to the first built-in if the removed shape was active.
        if appState.activeBrainDumpShapeID == shape.id {
            appState.activeBrainDumpShapeID = BrainDumpShapes.builtIns[0].id
        }
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/AISettingsView.swift
git commit -m "✨ feat(braindump): AI settings shapes picker + CRUD"
```

---

## Task 6: Menu-bar mini-panel brain-dump row

A shape dropdown + Start, so brain-dump is reachable without the hotkey.

**Files:**
- Modify: `omwhisper-native/UI/MiniPanelView.swift` (body ~35; a `brainDumpRow` computed view after `styleRow` ~114)

**Interfaces:**
- Consumes: `appState.activeBrainDumpShape`, `appState.brainDumpShapes`, `appState.activeBrainDumpShapeID`, `appState.beginBrainDump()`.

- [ ] **Step 1: Insert the row into the body**

In `MiniPanelView.body`, after `styleRow` (and after the `meetingRecordRow` conditional), add `brainDumpRow`:

```swift
            styleRow
            if appState.meetingsEnabled {
                meetingRecordRow
            }
            brainDumpRow
```

- [ ] **Step 2: Add the brainDumpRow view**

After the `styleRow` computed property (~line 114), add:

```swift
    private var brainDumpRow: some View {
        HStack {
            Text("Brain-dump")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Porcelain.dim)
            Menu(appState.activeBrainDumpShape?.name ?? "—") {
                ForEach(BrainDumpShapes.all(customShapes: appState.brainDumpShapes)) { shape in
                    Button(shape.name) { appState.activeBrainDumpShapeID = shape.id }
                }
            }
            .font(.system(size: 11.5))
            Spacer()
            Button("Start") { appState.beginBrainDump() }
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Porcelain.mint)
                .buttonStyle(.plain)
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/MiniPanelView.swift
git commit -m "✨ feat(braindump): mini-panel brain-dump row (shape + start)"
```

---

## Live verification (after all tasks, on real hardware)

1. **Basic dump** — set shape = Email in AI settings; press ⌘⇧D, ramble a few sentences, press ⌘⇧D again → a structured email pastes into the frontmost app. Overlay showed "N words · M:SS" while recording, then POLISHING.
2. **Long dump** — a 2–3 minute ramble structures (map-reduce) without a timeout error.
3. **Shape variety** — Ticket / To-do produce visibly different structure from the same ramble.
4. **Mini-panel path** — the Brain-dump row's Start begins a dump with the dropdown's shape.
5. **Fallback** — with polish backend Disabled, a brain-dump pastes the raw ramble (no structuring).
6. **No regression** — normal ⌘⇧V dictation and ⌘⇧B smart dictation still behave exactly as before (SessionMode refactor).

## Self-Review

- **Spec coverage:** shapes + structurer → Task 1; SessionMode → Task 2; settings/hotkey/hook → Task 3; relaxed overlay → Task 4; settings CRUD → Task 5; mini-panel → Task 6. All spec sections mapped.
- **Placeholders:** none — every code step is complete, reusing verified patterns (`MeetingSummarizer.chunk`, the style settings get/set, the AISettings CRUD, the hotkey/`GlobalHotkey` shape, the overlay transcript zone).
- **Type consistency:** `sessionMode`/`SessionMode`, `beginBrainDump()`, `activeBrainDumpShapeID`/`activeBrainDumpShape`/`brainDumpShapes`, `BrainDumpStructurer.structure`/`chunk`, `BrainDumpShapes.builtIns`/`chunkNotesStyle`/`all`/`shape` are named identically across every task and call site. Note: `BrainDumpStructurer` re-exposes `chunkNotesStyle` as a private alias to `BrainDumpShapes.chunkNotesStyle` so the tests' `BrainDumpShapes.chunkNotesStyle.name` and the structurer agree.
