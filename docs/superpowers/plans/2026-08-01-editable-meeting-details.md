# Editable Meeting Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A meeting's title and attendees can be typed, corrected and cleared in the detail pane — persisting, surviving re-transcription, retitling the list row, and feeding SP1's speaker-rename chips. Per `docs/superpowers/specs/2026-08-01-editable-meeting-details-design.md`.

**Architecture:** No migration — SP1's `title`/`attendees` columns already exist and are simply never user-written today. Adds one store method (`setDetails`), one pure parser (`parseAttendees`), and an "Edit details" popover in the meeting detail header, matching the popover/inline-edit affordances SP1 and SP2 already established in that file.

**Tech Stack:** Swift 6 (MainActor-by-default), GRDB, SwiftUI, Swift Testing.

## Global Constraints

- Branch: `worktree-sp2-meeting-details` — the existing SP2 worktree branch (SP2 is implemented, not yet live-verified; both edit the same header region).
- Empty/blank input persists as `nil`, never `""` — a cleared title must fall back to `appName` exactly like an unmatched meeting.
- `transcribeMeeting` must keep writing transcript/summary/speakerNames only; Task 3 pins that with a test.
- Full-suite command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`.
- Commit style: emoji conventional commits.

---

### Task 1: `parseAttendees` — pure comma-separated parsing

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingStore.swift` (add to the file's existing `nonisolated enum` scope — see Step 3 for exact placement)
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `MeetingDetails.parseAttendees(_ line: String) -> [String]` — splits on commas, trims each, drops empties. A blank line yields `[]` (callers convert `[]` → `nil` when storing).
- Consumes: nothing.

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MeetingStoreTests.swift`:

```swift
    @Test func parseAttendeesSplitsTrimsAndDropsEmpties() {
        #expect(MeetingDetails.parseAttendees("Alice, Bob Kumar,  Priya ")
            == ["Alice", "Bob Kumar", "Priya"])
        #expect(MeetingDetails.parseAttendees("Alice,,Bob, ,") == ["Alice", "Bob"])
    }

    @Test func parseAttendeesOnBlankLineIsEmpty() {
        #expect(MeetingDetails.parseAttendees("").isEmpty)
        #expect(MeetingDetails.parseAttendees("   ,  , ").isEmpty)
    }

    @Test func parseAttendeesKeepsASingleName() {
        #expect(MeetingDetails.parseAttendees("Alice") == ["Alice"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'MeetingDetails' in scope`.

- [ ] **Step 3: Implement**

In `MeetingStore.swift`, directly above `nonisolated final class MeetingStore`:

```swift
/// Parsing for user-typed meeting details. Separate from MeetingStore so the
/// logic is testable without touching a database, matching how
/// MeetingDiarization holds the pure half of the transcript pipeline.
nonisolated enum MeetingDetails {
    /// "Alice, Bob Kumar,  Priya " -> ["Alice", "Bob Kumar", "Priya"].
    /// Empty entries are dropped, so trailing commas and stray spaces while
    /// typing never produce blank attendees. A blank line yields [] — callers
    /// store nil for that, never an empty array.
    static func parseAttendees(_ line: String) -> [String] {
        line.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "✨ feat(meetings): pure attendee-line parsing"
```

---

### Task 2: `setDetails` — the write path

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingStore.swift`
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `MeetingStore.setDetails(id: Int64, title: String?, attendees: [String]?) throws`. Blank-or-empty inputs are normalised to `nil` inside the method, so no caller can accidentally store `""` or `[]`.
- Consumes: Task 1's parser (at the call site, not inside the store).

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MeetingStoreTests.swift`:

```swift
    @Test func setDetailsRoundTripsTitleAndAttendees() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Zoom")
        try store.setDetails(id: id, title: "Q3 Planning", attendees: ["Alice", "Bob"])
        let got = try store.get(id: id)
        #expect(got?.title == "Q3 Planning")
        #expect(got?.attendees == ["Alice", "Bob"])
        // Title is FTS-indexed (SP1) — a typed title must be searchable too.
        #expect(try store.search("Planning", limit: 10).count == 1)
    }

    /// A cleared title must fall back to appName in the UI, which keys off nil —
    /// storing "" would render an empty header instead.
    @Test func setDetailsNormalisesBlanksToNil() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Meet")
        try store.setDetails(id: id, title: "Temp", attendees: ["X"])
        try store.setDetails(id: id, title: "   ", attendees: [])
        let got = try store.get(id: id)
        #expect(got?.title == nil)
        #expect(got?.attendees == nil)
    }

    @Test func setDetailsLeavesTranscriptAndSummaryAlone() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Teams")
        try store.setTranscriptAndSummary(id: id, transcript: "**You:**\nhi", summary: "## Summary\ns")
        try store.setDetails(id: id, title: "Retro", attendees: nil)
        let got = try store.get(id: id)
        #expect(got?.transcript == "**You:**\nhi")
        #expect(got?.summary == "## Summary\ns")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | grep -E "error:" | head -3`
Expected: `value of type 'MeetingStore' has no member 'setDetails'`.

- [ ] **Step 3: Implement**

In `MeetingStore.swift`, after `setSummary`:

```swift
    /// User-typed title/attendees. Blank input is normalised to nil here rather
    /// than at the call site, so no caller can persist "" (which would render an
    /// empty header) or [] (which would show an empty "With …" line). Never
    /// touches transcript/summary/speakerNames.
    func setDetails(id: Int64, title: String?, attendees: [String]?) throws {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAttendees = attendees?.filter { !$0.isEmpty }
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.title = (cleanTitle?.isEmpty ?? true) ? nil : cleanTitle
            m.attendees = (cleanAttendees?.isEmpty ?? true) ? nil : cleanAttendees
            try m.update(db)
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "✨ feat(meetings): setDetails write path, blanks normalised to nil"
```

---

### Task 3: Pin "manual edits survive re-transcribe"

**Files:**
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:** none — this task adds only a regression test.

The spec promises typed details survive re-transcription. `transcribeMeeting` is
effectful (real ASR) and cannot run in a unit test, but the *store-level* claim
it depends on is testable: the writes that re-transcription performs
(`setSpeakerNames`, `setTranscriptAndSummary`) must not disturb title/attendees.
That is the part that could silently regress if someone later "simplifies" those
methods into one update.

- [ ] **Step 1: Write the test**

```swift
    /// Re-transcribing writes transcript, summary and speaker names — and must
    /// leave user-typed details untouched. Guards the spec's promise against a
    /// future refactor that merges these writes into one update.
    @Test func retranscribeWritesDoNotClobberTypedDetails() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Zoom")
        try store.setDetails(id: id, title: "Q3 Planning", attendees: ["Alice"])
        // Exactly what transcribeMeeting does, in order.
        try store.setSpeakerNames(id: id, nil)
        try store.setTranscriptAndSummary(id: id, transcript: "**Speaker 1:**\nnew", summary: "new")
        let got = try store.get(id: id)
        #expect(got?.title == "Q3 Planning")
        #expect(got?.attendees == ["Alice"])
    }
```

- [ ] **Step 2: Run it**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: TEST SUCCEEDED (passes immediately — it documents and locks existing behaviour rather than driving new code).

- [ ] **Step 3: Commit**

```bash
git add omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "✅ test(meetings): typed details survive the re-transcribe writes"
```

---

### Task 4: "Edit details" popover

**Files:**
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift`

**Interfaces:**
- Consumes: `MeetingStore.setDetails`, `MeetingDetails.parseAttendees`, `appState.meetingStore`, the existing `onChanged` reload closure.
- Produces: no new API. Pure SwiftUI — no unit tests per project convention; the suite staying green plus the live checklist is the verification.

- [ ] **Step 1: Add state and the button**

In `MeetingDetailView`, beside the existing `editingSummary`/`summaryDraft` state (SP2):

```swift
    @State private var editingDetails = false
    @State private var titleDraft = ""
    @State private var attendeesDraft = ""
```

In `MeetingDetailView.header`'s button row, after the Delete button:

```swift
                Button("Edit details") { beginEditingDetails() }
                    .disabled(busy)
                    .popover(isPresented: $editingDetails, arrowEdge: .bottom) {
                        detailsEditor
                    }
```

- [ ] **Step 2: Add the editor and its actions**

Add to `MeetingDetailView`:

```swift
    /// Prefill from what's shown today, so editing corrects rather than retypes.
    /// An unset title prefills empty (not appName) — appName is a fallback for
    /// display, not a value the user chose.
    private func beginEditingDetails() {
        titleDraft = meeting.title ?? ""
        attendeesDraft = (meeting.attendees ?? []).joined(separator: ", ")
        editingDetails = true
    }

    private var detailsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting details")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)
            TextField("Title", text: $titleDraft)
                .frame(width: 260)
                .onSubmit { saveDetails() }
            TextField("Attendees, comma separated", text: $attendeesDraft)
                .frame(width: 260)
                .onSubmit { saveDetails() }
            Text("Attendees appear as one-tap names when renaming speakers.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.Porcelain.dim)
                .frame(width: 260, alignment: .leading)
            HStack {
                Button("Cancel") { editingDetails = false }
                    .controlSize(.small)
                Spacer()
                Button("Save") { saveDetails() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    private func saveDetails() {
        editingDetails = false
        guard let id = meeting.id, let store = appState.meetingStore else { return }
        do {
            try store.setDetails(
                id: id,
                title: titleDraft,
                attendees: MeetingDetails.parseAttendees(attendeesDraft))
        } catch {
            errorMessage = error.localizedDescription
        }
        Task { await onChanged() }
    }
```

(`porcelainField()` is deliberately not applied to these two `TextField`s: they sit inside a popover, not a Porcelain card, and the plain field is what the SP1 rename popover uses two views away. Keep the two popovers consistent.)

- [ ] **Step 3: Full build + suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/HubMeetingsSectionView.swift
git commit -m "✨ feat(meetings): edit a meeting's title and attendees by hand"
```

---

### Task 5: Rebuild the dev app and hand over the live checklist

- [ ] **Step 1: Rebuild and relaunch OmWhisper-Dev**

```bash
osascript -e 'tell application id "com.omwhisper.mac.dev" to quit' 2>/dev/null
DD=$(xcodebuild -showBuildSettings -scheme omwhisper-native -project omwhisper-native.xcodeproj -configuration Debug 2>/dev/null | grep -m1 "  BUILT_PRODUCTS_DIR" | sed 's/.*= //')
open "$DD/OmWhisper-Dev.app"
```

- [ ] **Step 2: Live checklist (user)**

1. **Title** — open a meeting → **Edit details** → type "Q3 Planning" → Save. Header and the list row both retitle immediately; quit and relaunch the dev app — still there.
2. **Clear** — reopen, empty the title, Save → falls back to the app name (not a blank header).
3. **Attendees** — type "Alice, Bob Kumar, Priya" → Save → the "With …" line appears in the header; click a **Speaker** label in the transcript → those three appear as one-tap rename chips.
4. **Search** — type a distinctive word into the typed title, then search for it in the meetings list → the meeting is found (title is FTS-indexed).
5. **Survives re-transcribe** — with a title and attendees set, press **Re-transcribe**; when it finishes, both are still there (speaker names reset, as designed).
