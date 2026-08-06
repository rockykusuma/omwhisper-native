# Meeting pre-roll recording + honest titles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop losing the opening of a meeting (record from detection, keep only on consent) and stop filing ad-hoc 1:1 calls as "Chat".

**Architecture:** The recorder starts at the `.idle → .detecting` transition instead of at consent; every non-accept outcome stops it and deletes the directory. A launch-time sweep deletes meeting directories with no database row, covering a crash mid-window. Separately, window-title selection stops preferring the longest title (which picks Teams' nav window), and the summarizer names the meeting when no specific title is known.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Swift Testing, GRDB, CoreAudio process taps.

## Global Constraints

- **Meetings never reach a cloud provider.** `meetingSummaryBackends()` returns Ollama and SystemLLM only; no `.cloud` case may be added anywhere in this work, including the new title call.
- **`Copy Debug Info` never contains content.** Bundle IDs, pids, durations and verdicts only — never window titles, URLs, transcripts or summaries.
- **Anything off the GUI path is `nonisolated`.** Under this project's MainActor-by-default isolation, a new `enum`/`struct`/`class` used from a `nonisolated` context or compared in a plain test function needs an explicit `nonisolated` marker. `MCPServer`, `ParakeetEngine`, `CloudEngine` and `HomeStats` each hit this as a real build error.
- **Constructing `AppState` in a test opens the real stores** and runs auto-delete cleanup. No test in this plan may construct `AppState`. Test pure functions and the injected-closure seams instead.
- **Hidden `PolishStyle`s must stay out of `builtInTemplates`** — an existing test pins that, and a style leaking into the picker is a user-visible bug.
- Full suite before this work: **513 tests in 74 suites**. Run `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test` after every task; it must stay green and grow.

---

### Task 1: Pick the call window, not the longest one

The reported bug. `callWindowTitle` returns `titles.max { $0.count < $1.count }` when no title contains a call word, so for a 1:1 Teams call the nav window `Chat | Microsoft Teams` beats the real call window. Fixing the *cleaning* would not have helped; the wrong window was chosen.

**Files:**
- Modify: `omwhisper-native/Meetings/CallDetection.swift`
- Test: `omwhisper-nativeTests/CallDetectionTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `CallDetection.isGenericTitle(_ title: String, appName: String) -> Bool`
  - `CallDetection.bestWindowTitle(_ titles: [String], appName: String) -> String?`
  - `CallDetection.cleanedMeetingTitle(windowTitle:appName:) -> String?` (behaviour changes; signature unchanged)

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/CallDetectionTests.swift`, inside the existing `CallDetectionTests` suite:

```swift
    @Test("app chrome is rejected, real names are kept")
    func genericTitlesAreRejected() {
        #expect(CallDetection.isGenericTitle("Chat", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("chat", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("Activity", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("Microsoft Teams", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("Teams", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("   ", appName: "Teams"))
        // Matched exactly, never by substring: these are real meeting names.
        #expect(!CallDetection.isGenericTitle("Chat app redesign", appName: "Teams"))
        #expect(!CallDetection.isGenericTitle("Calendar migration", appName: "Teams"))
        #expect(!CallDetection.isGenericTitle("D-WHAS", appName: "Teams"))
    }

    @Test("the call window wins over the longer nav window")
    func callWindowBeatsLongerNavWindow() {
        // The actual shape of the 2026-08-06 miss: the nav window's title is
        // LONGER than the call window's, so the old `titles.max(by: count)`
        // rule picked it. This test fails if that rule is restored.
        let titles = ["Chat | Microsoft Teams", "Radha Krishnan"]
        #expect(CallDetection.bestWindowTitle(titles, appName: "Teams") == "Radha Krishnan")
    }

    @Test("a call-like title still wins outright")
    func callLikeTitleWinsFirst() {
        let titles = ["Some very long window title that is not a call at all",
                      "Meeting with the hardware team"]
        #expect(CallDetection.bestWindowTitle(titles, appName: "Teams")
                == "Meeting with the hardware team")
    }

    @Test("longest still wins among specific titles")
    func longestWinsAmongSpecificTitles() {
        let titles = ["Q3", "Q3 Planning and budget review"]
        #expect(CallDetection.bestWindowTitle(titles, appName: "Teams")
                == "Q3 Planning and budget review")
    }

    @Test("all-chrome yields nothing rather than a bad title")
    func allChromeYieldsNil() {
        #expect(CallDetection.bestWindowTitle(["Chat | Microsoft Teams", "Activity"],
                                              appName: "Teams") == nil)
        #expect(CallDetection.bestWindowTitle([], appName: "Teams") == nil)
    }

    @Test("a generic title never becomes the meeting name")
    func cleanedTitleRejectsGenericSegments() {
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Chat | Microsoft Teams", appName: "Teams") == nil)
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Calls | Microsoft Teams", appName: "Teams") == nil)
    }
```

Then **change one existing expectation** in `cleanedTitleHandlesTeamsPipe`. It currently asserts `cleanedMeetingTitle(windowTitle: "Microsoft Teams", appName: "Teams") == "Microsoft Teams"`. That is the app's own name and is exactly the kind of title this task exists to reject. Replace that one line with:

```swift
        // Changed 2026-08-06: "Microsoft Teams" is app chrome, not a meeting
        // name. It used to be kept, which is how a call got filed under the
        // product name. Falls back to appName for display.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Microsoft Teams", appName: "Teams") == nil)
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -30`
Expected: compile failure — `isGenericTitle` and `bestWindowTitle` do not exist.

- [ ] **Step 3: Implement**

In `omwhisper-native/Meetings/CallDetection.swift`, add after the `callLikeWords` declaration:

```swift
    /// Window titles that are app chrome, never a meeting name. Teams' left
    /// nav is the reason this exists: an ad-hoc 1:1 call on 2026-08-06 was
    /// filed as "Chat", because the nav window's title is LONGER than the call
    /// window's and the old rule picked the longest.
    ///
    /// This is a vendor-shaped string list — the same class of heuristic that
    /// missed a 30-minute call on 2026-08-03 — and it will rot when Teams
    /// renames a tab. It is here because without it a generic title wins and
    /// the model is never asked to name the meeting. Its failure mode is
    /// benign: a missed entry falls through to the generated title.
    private static let genericTitles: Set<String> = [
        "chat", "chats", "calls", "activity", "calendar", "home", "files",
        "communities", "teams", "microsoft teams", "meet", "google meet",
        "slack", "zoom", "zoom workplace", "discord", "whatsapp", "messages",
        "facetime", "webex", "inbox", "untitled",
    ]

    /// Is this title app chrome rather than a meeting name?
    ///
    /// Matched EXACTLY (case-insensitive), never by substring: "Chat app
    /// redesign" is a real meeting name. A `contains` test here would be the
    /// same length-unbounded mistake that made `answer()` throw away extracts
    /// beginning "Nothing relevant to the budget, but…".
    static func isGenericTitle(_ title: String, appName: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == appName.lowercased() { return true }
        return genericTitles.contains(normalized)
    }

    /// The leading segment of a window title, before the app's own suffix.
    /// Extracted so `bestWindowTitle` judges the same string the meeting would
    /// actually be named — judging the raw title would let "Chat | Microsoft
    /// Teams" pass, since that whole string is not itself in the chrome list.
    private static func firstSegment(_ windowTitle: String) -> String {
        windowTitle
            .components(separatedBy: " – ").first!
            .components(separatedBy: " - ").first!
            .components(separatedBy: " | ").first!
            .trimmingCharacters(in: .whitespaces)
    }

    /// Pure: which of an app's window titles is most likely the CALL window.
    ///
    /// Prefer a call-like title, then the longest title whose leading segment
    /// is not app chrome. The old rule was "longest, full stop", which for a
    /// 1:1 Teams call picks the nav window over the call window.
    static func bestWindowTitle(_ titles: [String], appName: String) -> String? {
        if let callLike = titles.first(where: hasCallLikeTitle) { return callLike }
        return titles
            .filter { !isGenericTitle(firstSegment($0), appName: appName) }
            .max { $0.count < $1.count }
    }
```

Replace the body of `callWindowTitle`'s final line:

```swift
        return titles.first(where: hasCallLikeTitle) ?? titles.max { $0.count < $1.count }
```

with:

```swift
        return bestWindowTitle(titles, appName: appName)
```

`callWindowTitle` has no `appName` parameter today. Change its signature to
`static func callWindowTitle(pid: pid_t, appName: String) -> String?` and update
its two call sites:

- `omwhisper-native/AppState.swift:669` → `CallDetection.callWindowTitle(pid: $0, appName: appName)` (the `appName` argument `beginRecording` already receives).
- `omwhisper-native/Meetings/MeetingDetectionDiagnostics.swift:37` → `CallDetection.callWindowTitle(pid: call.pid, appName: call.name)`.

Finally, in `cleanedMeetingTitle`, replace its `guard` with one that uses the new predicate and the extracted helper:

```swift
    static func cleanedMeetingTitle(windowTitle: String, appName: String) -> String? {
        let first = firstSegment(windowTitle)
        guard !isGenericTitle(first, appName: appName) else { return nil }
        return first
    }
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, count above 513.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/CallDetection.swift omwhisper-native/AppState.swift omwhisper-native/Meetings/MeetingDetectionDiagnostics.swift omwhisper-nativeTests/CallDetectionTests.swift
git commit -m "$(cat <<'EOF'
🐛 fix(meetings): pick the call window, not the longest one

An ad-hoc 1:1 Teams call was filed as "Chat". The title was never
wrong — the WINDOW was: callWindowTitle took titles.max(by: count),
and Teams' nav window ("Chat | Microsoft Teams") is longer than the
call window's. Scheduled meetings hid this because the calendar match
overwrites the title afterwards.

isGenericTitle matches exactly, never by substring — "Chat app
redesign" is a real meeting name.

One existing expectation changed deliberately: "Microsoft Teams" was
asserted to be a valid meeting title. It is the product name.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 2: Let the model name the meeting

Task 1 stops a bad title being stored, which leaves those meetings named by app. This names them from the summary — and retitles the rows already on disk when the user hits Regenerate summary.

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingSummarizer.swift`
- Modify: `omwhisper-native/Meetings/MeetingStore.swift`
- Modify: `omwhisper-native/AppState.swift`
- Test: `omwhisper-nativeTests/MeetingSummarizerTests.swift`

**Interfaces:**
- Consumes: `CallDetection.isGenericTitle(_:appName:)` (Task 1).
- Produces:
  - `MeetingSummarizer.titleStyle: PolishStyle`
  - `MeetingSummarizer.cleanTitleOutput(_ raw: String) -> String?`
  - `MeetingSummarizer.title(fromSummary:polish:) async throws -> String?`
  - `MeetingStore.setTitle(id: Int64, _ title: String?) throws`

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MeetingSummarizerTests.swift`:

```swift
@Suite("Meeting title generation")
struct MeetingTitleTests {
    @Test("the title style is hidden from the template picker")
    func titleStyleIsHidden() {
        // Same rule as questionExtract/questionAnswer/followUp: an internal
        // style appearing in the user's picker is a visible bug.
        #expect(!MeetingSummarizer.builtInTemplates.contains { $0.id == MeetingSummarizer.titleStyle.id })
    }

    @Test("model decoration is stripped")
    func decorationIsStripped() {
        #expect(MeetingSummarizer.cleanTitleOutput("\"Office onboarding logistics\"")
                == "Office onboarding logistics")
        #expect(MeetingSummarizer.cleanTitleOutput("Title: Q3 budget review")
                == "Q3 budget review")
        #expect(MeetingSummarizer.cleanTitleOutput("## Weekly sync\n\nHere is why…")
                == "Weekly sync")
        #expect(MeetingSummarizer.cleanTitleOutput("Seating arrangements.")
                == "Seating arrangements")
    }

    @Test("a paragraph is not a title")
    func paragraphIsRejected() {
        // A small model asked for a title sometimes writes the summary again.
        // Storing that would put a wall of text in the meeting header.
        let paragraph = String(repeating: "the meeting covered many things ", count: 10)
        #expect(MeetingSummarizer.cleanTitleOutput(paragraph) == nil)
        #expect(MeetingSummarizer.cleanTitleOutput("   ") == nil)
        #expect(MeetingSummarizer.cleanTitleOutput("\"\"") == nil)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -30`
Expected: compile failure — `titleStyle` and `cleanTitleOutput` do not exist.

- [ ] **Step 3: Implement the summarizer half**

In `omwhisper-native/Meetings/MeetingSummarizer.swift`, add beside the other hidden styles (after `followUpStyle`):

```swift
    /// Names a meeting from its own summary. Hidden — deliberately absent from
    /// builtInTemplates (a test pins that).
    ///
    /// From the SUMMARY, not the transcript: the summary is already distilled,
    /// fits any chunk limit, and needs exactly one call with no map-reduce.
    /// Regenerating the whole pipeline for six words would be absurd.
    static let titleStyle = PolishStyle(
        id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000013")!,
        name: "Meeting title",
        prompt: """
        Below is a summary of a meeting. Write a title for it: three to seven \
        words naming the main subject. No quotation marks, no trailing \
        punctuation, no "Title:" prefix, no explanation. Output only the title.
        """,
        isBuiltIn: false
    )

    /// Pure: model output → a storable title, or nil.
    ///
    /// Small models decorate regardless of instruction — quotes, a "Title:"
    /// prefix, a markdown heading, a trailing full stop — and sometimes ignore
    /// the request entirely and restate the summary. The 80-character ceiling
    /// is what catches that last case; without it a paragraph lands in the
    /// meeting header.
    static func cleanTitleOutput(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.components(separatedBy: .newlines).first ?? text
        if let prefix = text.range(of: "title:", options: [.caseInsensitive, .anchored]) {
            text = String(text[prefix.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”*#.·—–-"))
        guard !text.isEmpty, text.count <= 80 else { return nil }
        return text
    }

    /// One model call over the summary. nil when the summary is empty or the
    /// output isn't usable as a title.
    static func title(fromSummary summary: String, polish: PolishBackend) async throws -> String? {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let raw = try await polish.polish(summary, style: titleStyle, targetLanguage: nil)
        return cleanTitleOutput(raw)
    }
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Add the store setter**

In `omwhisper-native/Meetings/MeetingStore.swift`, after `setDetails`:

```swift
    /// Title only. Separate from setDetails because that is the user-edit path
    /// and writes attendees too — passing nil there to set a title would wipe
    /// an attendee list the calendar match had filled in.
    func setTitle(id: Int64, _ title: String?) throws {
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.title = (clean?.isEmpty ?? true) ? nil : clean
            try m.update(db)
        }
    }
```

- [ ] **Step 6: Wire it into AppState**

In `omwhisper-native/AppState.swift`, add after `generateMeetingSummary`:

```swift
    /// Name the meeting from its summary when nothing better is known.
    ///
    /// Never overwrites a title the user typed — only a nil or app-chrome one.
    /// Best-effort throughout: a failure leaves the title alone, and the header
    /// falls back to the app name exactly as before.
    private func nameMeetingIfNeeded(id: Int64, summary: String) async {
        guard let store = meetingStore, let meeting = try? store.get(id: id) else { return }
        if let existing = meeting.title,
           !CallDetection.isGenericTitle(existing, appName: meeting.appName) { return }
        for candidate in meetingSummaryBackends() {
            guard let title = try? await MeetingSummarizer.title(
                fromSummary: summary, polish: candidate.polish), let title else { continue }
            try? store.setTitle(id: id, title)
            return
        }
    }
```

Then call it from both summary paths, after the summary has been stored.

In `transcribeMeeting`, replace:

```swift
        try store.setTranscriptAndSummary(id: id, transcript: transcript,
                                          summary: written?.summary,
                                          summaryBackend: written?.backend)
        return try store.get(id: id) ?? meeting
```

with:

```swift
        try store.setTranscriptAndSummary(id: id, transcript: transcript,
                                          summary: written?.summary,
                                          summaryBackend: written?.backend)
        if let summary = written?.summary { await nameMeetingIfNeeded(id: id, summary: summary) }
        return try store.get(id: id) ?? meeting
```

In `regenerateSummary`, replace:

```swift
        try store.setTranscriptAndSummary(id: id, transcript: transcript,
                                          summary: written.summary,
                                          summaryBackend: written.backend)
        return try store.get(id: id) ?? meeting
```

with:

```swift
        try store.setTranscriptAndSummary(id: id, transcript: transcript,
                                          summary: written.summary,
                                          summaryBackend: written.backend)
        // Also the retitle path for meetings recorded before this existed:
        // Regenerate summary on the "Chat" row names it properly.
        await nameMeetingIfNeeded(id: id, summary: written.summary)
        return try store.get(id: id) ?? meeting
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/Meetings/MeetingSummarizer.swift omwhisper-native/Meetings/MeetingStore.swift omwhisper-native/AppState.swift omwhisper-nativeTests/MeetingSummarizerTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(meetings): the model names the meeting when nothing else can

Generated from the SUMMARY, not the transcript — one small call
instead of repeating the whole map-reduce for six words.

Runs in regenerateSummary too, so Regenerate summary retitles rows
already on disk. Never overwrites a title the user typed: only a nil
or app-chrome one, judged by Task 1's isGenericTitle.

setTitle rather than setDetails: setDetails writes attendees too, so
using it here would wipe a calendar-supplied attendee list.

The 80-char ceiling in cleanTitleOutput is not tidiness — a small
model asked for a title sometimes restates the summary, and that
would land a paragraph in the meeting header.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 3: Delete meeting directories with no row

Needed before pre-roll, which makes orphans more frequent. The hazard already exists: the `meetings` row is inserted only at stop, so a crash mid-recording leaves audio on disk with nothing pointing at it.

**Files:**
- Create: `omwhisper-native/Meetings/MeetingOrphanSweep.swift`
- Modify: `omwhisper-native/Meetings/MeetingStore.swift`
- Modify: `omwhisper-native/AppState.swift`
- Test: `omwhisper-nativeTests/MeetingOrphanSweepTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `MeetingStore.directories() throws -> [String]`
  - `MeetingOrphanSweep.orphans(onDisk: [String], known: [String]) -> [String]`
  - `MeetingOrphanSweep.run(store: MeetingStore, root: URL)`

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/MeetingOrphanSweepTests.swift`:

```swift
import Foundation
import Testing
@testable import OmWhisper

@Suite("Meeting orphan sweep")
struct MeetingOrphanSweepTests {
    @Test("a directory with no row is an orphan")
    func unknownDirectoryIsAnOrphan() {
        let orphans = MeetingOrphanSweep.orphans(
            onDisk: ["/m/2026-08-06_1000_Teams", "/m/2026-08-06_1100_Zoom"],
            known: ["/m/2026-08-06_1100_Zoom"])
        #expect(orphans == ["/m/2026-08-06_1000_Teams"])
    }

    @Test("a directory WITH a row is left alone")
    func knownDirectoryIsKept() {
        // The half that matters. A sweep that deletes everything passes the
        // test above; only this one fails it.
        let orphans = MeetingOrphanSweep.orphans(
            onDisk: ["/m/a", "/m/b"], known: ["/m/a", "/m/b"])
        #expect(orphans.isEmpty)
    }

    @Test("nothing on disk, nothing deleted")
    func emptyDiskIsSafe() {
        #expect(MeetingOrphanSweep.orphans(onDisk: [], known: ["/m/a"]).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -30`
Expected: compile failure — no such type `MeetingOrphanSweep`.

- [ ] **Step 3: Implement**

Create `omwhisper-native/Meetings/MeetingOrphanSweep.swift`:

```swift
//
//  MeetingOrphanSweep.swift
//  OmWhisper
//
//  Deletes meeting directories that no database row points at.
//
//  A meetings row is inserted only when recording STOPS, so a crash or a
//  force-quit mid-recording has always left audio on disk with nothing
//  referencing it — invisible, un-deletable through the UI, and growing.
//  Pre-roll recording makes that more frequent, since a directory now exists
//  before consent is even asked for.
//
//  Runs once at launch, before any recorder can have started, so it cannot
//  race a live recording.
//

import Foundation
import os

nonisolated private let sweepLog = Logger(subsystem: "com.omwhisper.mac", category: "MeetingOrphanSweep")

nonisolated enum MeetingOrphanSweep {
    /// Pure: directories on disk that no row claims.
    static func orphans(onDisk: [String], known: [String]) -> [String] {
        let claimed = Set(known)
        return onDisk.filter { !claimed.contains($0) }
    }

    /// `root` is the Application Support "meetings" directory. Silent when
    /// there is nothing to do; logs a count when it deletes, because audio
    /// disappearing should be attributable.
    static func run(store: MeetingStore, root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        let onDisk = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.path)
        guard let known = try? store.directories() else { return }

        let stale = orphans(onDisk: onDisk, known: known)
        guard !stale.isEmpty else { return }
        for path in stale { try? fm.removeItem(atPath: path) }
        // Count only, never a path -- a meeting directory is named after the
        // app. `.public` because a redacted count says nothing.
        sweepLog.notice("removed \(stale.count, privacy: .public) orphaned meeting directories")
    }
}
```

In `omwhisper-native/Meetings/MeetingStore.swift`, after `count()`:

```swift
    /// Every directory a row points at, for the orphan sweep.
    func directories() throws -> [String] {
        try dbQueue.read { db in try Meeting.fetchAll(db).map(\.directory) }
    }
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Call it at launch**

In `omwhisper-native/AppState.swift`, immediately after the `meetingStore` open block (the `do`/`catch` ending around line 1636), add:

```swift
        // Delete meeting directories no row points at — a crash mid-recording,
        // or an unconsented pre-roll the app never got to clean up. Guarded by
        // isRunningUnderTests for the same reason every other store daemon is,
        // and off the main thread because it is file I/O.
        if !isRunningUnderTests, let store = meetingStore, let appSupportDir {
            let root = appSupportDir.appendingPathComponent("meetings", isDirectory: true)
            Task.detached(priority: .utility) { MeetingOrphanSweep.run(store: store, root: root) }
        }
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, still green.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/MeetingOrphanSweep.swift omwhisper-native/Meetings/MeetingStore.swift omwhisper-native/AppState.swift omwhisper-nativeTests/MeetingOrphanSweepTests.swift
git commit -m "$(cat <<'EOF'
🐛 fix(meetings): delete recordings no database row points at

The meetings row is inserted only at stop, so a crash mid-recording
has always orphaned its audio — on disk, unreferenced, invisible to
the UI. Pre-roll makes it more frequent, so fix it first.

The load-bearing test is the second one: a sweep that deletes
everything passes "an unknown directory is an orphan".

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 4: Pre-roll lifecycle in the watcher

The state machine half. `nextState` is untouched — its existing tests staying green is the regression proof that detection itself did not change.

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingWatcher.swift`
- Test: `omwhisper-nativeTests/MeetingWatcherLogicTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `MeetingWatcher.onBeginPreRoll: (String, pid_t) -> Void`
  - `MeetingWatcher.onDiscardPreRoll: () -> Void`
  - `MeetingWatcher.acceptPreRoll(appName: String) -> Bool`
  - `MeetingWatcher.isPreRolling: Bool` (read-only)

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MeetingWatcherLogicTests.swift`.

**Two constraints, both learned from this suite's own history.** `tick()` hands
detection to a detached task, so every effect is asynchronous — poll for it,
never sleep a guessed duration (`MeetingWatcherConcurrencyTests` carries the
comment explaining why a fixed sleep is wrong under parallel-suite load). And
`startDebounce` is **real wall time**: a test that wants a consent prompt must
keep ticking for a real 3 seconds. Only the two tests that need the prompt pay
that; the rest assert on transitions that happen on the first tick.

```swift
@Suite("Meeting pre-roll lifecycle")
@MainActor
struct MeetingPreRollTests {
    /// A settable call, so one test can turn a call on and then off without
    /// audio hardware.
    final class Box: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: MeetingWatcher.DetectedCall?.none)
        var call: MeetingWatcher.DetectedCall? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
        init(_ call: MeetingWatcher.DetectedCall?) { self.call = call }
    }

    private func makeWatcher(_ box: Box) -> MeetingWatcher {
        let watcher = MeetingWatcher()
        watcher.performDetection = { box.call }
        watcher.performRecordingCheck = { _ in box.call != nil }
        watcher.onShowConsentPanel = { _, _ in }   // unanswered unless overridden
        return watcher
    }

    /// Polls until `condition` holds. Same idiom and same reason as
    /// MeetingWatcherConcurrencyTests.waitUntil.
    private func waitUntil(timeout: Duration = .seconds(5),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Drives real ticks until `condition` holds, because the start debounce is
    /// measured in wall time and no amount of calling tick() shortens it.
    private func tickUntil(_ watcher: MeetingWatcher, timeout: Duration = .seconds(8),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            watcher.startForTesting()
            try? await Task.sleep(for: .milliseconds(150))
        }
        return condition()
    }

    @Test("the recorder starts on first detection, before any prompt")
    func preRollStartsAtDetection() async {
        let watcher = makeWatcher(Box(.init(name: "Teams", pid: 2221)))
        let began = OSAllocatedUnfairLock(initialState: [(String, pid_t)]())
        watcher.onBeginPreRoll = { name, pid in began.withLock { $0.append((name, pid)) } }

        watcher.startForTesting()

        #expect(await waitUntil { began.withLock { $0.count } == 1 },
                "pre-roll never started")
        let first = began.withLock { $0.first }
        #expect(first?.0 == "Teams")
        // The OWNING app's pid, not the helper that holds the mic -- otherwise
        // callWindowTitle finds no windows and the meeting gets no title.
        #expect(first?.1 == 2221)
        #expect(watcher.isPreRolling)
        // The whole point: capture is running while the state is still
        // .detecting, i.e. before the debounce has even been cleared.
        #expect(watcher.state == .detecting)
    }

    @Test("a call that ends before anyone answers discards")
    func callEndingDuringPreRollDiscards() async {
        let box = Box(.init(name: "Teams", pid: 2221))
        let watcher = makeWatcher(box)
        let discards = OSAllocatedUnfairLock(initialState: 0)
        watcher.onDiscardPreRoll = { discards.withLock { $0 += 1 } }

        watcher.startForTesting()
        #expect(await waitUntil { watcher.isPreRolling }, "pre-roll never started")

        box.call = nil
        watcher.startForTesting()

        #expect(await waitUntil { discards.withLock { $0 } == 1 }, "never discarded")
        #expect(!watcher.isPreRolling)
    }

    @Test("saying yes elsewhere promotes the pre-roll instead of starting a second one")
    func acceptPreRollPromotes() async {
        let watcher = makeWatcher(Box(.init(name: "Teams", pid: 2221)))
        let starts = OSAllocatedUnfairLock(initialState: 0)
        watcher.onBeginPreRoll = { _, _ in starts.withLock { $0 += 1 } }

        watcher.startForTesting()
        #expect(await waitUntil { watcher.isPreRolling }, "pre-roll never started")

        #expect(watcher.acceptPreRoll(appName: "Teams"))
        #expect(watcher.state == .recording(appName: "Teams"))
        #expect(!watcher.isPreRolling)
        #expect(starts.withLock { $0 } == 1, "a second recorder was started over a live one")
        #expect(!watcher.acceptPreRoll(appName: "Teams"), "promoting twice should be a no-op")
    }

    @Test("declining discards exactly once", .timeLimit(.minutes(1)))
    func declineDiscards() async {
        let watcher = makeWatcher(Box(.init(name: "Teams", pid: 2221)))
        let discards = OSAllocatedUnfairLock(initialState: 0)
        watcher.onDiscardPreRoll = { discards.withLock { $0 += 1 } }
        watcher.onShowConsentPanel = { _, respond in respond(.declined) }

        #expect(await tickUntil(watcher) { discards.withLock { $0 } > 0 },
                "the prompt never fired or never discarded")

        #expect(discards.withLock { $0 } == 1, "discarded more than once")
        #expect(!watcher.isPreRolling)
        #expect(watcher.state == .declined)
    }

    @Test("an unanswered prompt keeps the recording", .timeLimit(.minutes(1)))
    func firstTimeoutKeepsThePreRoll() async {
        // R's decision, 2026-08-06: an unseen prompt is not a refusal. Deleting
        // here would make the retry 60s later start from nothing, which is past
        // the opening this whole change exists to save.
        let watcher = makeWatcher(Box(.init(name: "Teams", pid: 2221)))
        let discards = OSAllocatedUnfairLock(initialState: 0)
        watcher.onDiscardPreRoll = { discards.withLock { $0 += 1 } }
        watcher.onShowConsentPanel = { _, respond in respond(.timedOut) }

        #expect(await tickUntil(watcher) {
            if case .awaitingRetry = watcher.state { return true }
            return false
        }, "never reached awaitingRetry")

        #expect(discards.withLock { $0 } == 0, "an unanswered prompt threw the recording away")
        #expect(watcher.isPreRolling, "the pre-roll must survive the first timeout")
    }
}
```

The file needs `import Foundation` and `import os` at the top if they are not
already there (`OSAllocatedUnfairLock`).

**Not unit-testable, and deliberately not faked:** the *second* timeout's
discard needs `retryCooldown = 60s` of real wall time to re-prompt. Making that
injectable to test one branch is more surface than the branch is worth. It is
listed under live verification instead.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -30`
Expected: compile failure — `onBeginPreRoll`, `onDiscardPreRoll`, `acceptPreRoll`, `isPreRolling` do not exist.

- [ ] **Step 3: Implement**

In `omwhisper-native/Meetings/MeetingWatcher.swift`, add to the stored properties:

```swift
    /// True while a recording exists that nobody has consented to yet.
    private(set) var isPreRolling = false
    /// When the mic was first seen, for the latency stamp.
    private var preRollStartedAt: ContinuousClock.Instant?
```

Add beside the other injected closures:

```swift
    /// Fired the instant a call is first detected — BEFORE the debounce and
    /// before the prompt. The recording starts here so the opening of the
    /// meeting survives however long detection and the user's click take.
    /// Everything it produces is deleted unless consent arrives.
    var onBeginPreRoll: (String, pid_t) -> Void = { _, _ in }

    /// Stop an unconsented recording and delete what it wrote.
    var onDiscardPreRoll: () -> Void = {}
```

Add the promote path, after `markDeclined()`:

```swift
    /// The user said yes somewhere other than the consent panel — the hub's
    /// Record button while a pre-roll is running. Without this,
    /// toggleMeetingRecording would start a SECOND recorder over a live one.
    ///
    /// Returns false when there is no pre-roll to promote, so the caller can
    /// fall through to its normal start path.
    @discardableResult
    func acceptPreRoll(appName: String) -> Bool {
        guard isPreRolling else { return false }
        recordingPID = pendingCallPID ?? recordingPID
        sawCall = false
        goneSince = nil
        isPreRolling = false
        state = .recording(appName: appName)
        return true
    }
```

In `apply()`, after the `guard state != previous else { return }` line, extend the switch. The `.prompting` case gains the latency stamp and the consent branches gain discards; a new pre-roll start goes before the switch, because `.idle → .detecting` must fire it.

Replace:

```swift
        guard state != previous else { return }
        switch state {
        case .prompting(let appName):
            pendingCallPID = detected?.pid
            retrySince = nil
```

with:

```swift
        guard state != previous else { return }

        // Start capturing the moment a call is seen -- before the debounce,
        // before the prompt. The debounce exists to stop us PROMPTING on a
        // transient mic open; it has no reason to gate capture.
        if case .detecting = state, !isPreRolling, let detected {
            isPreRolling = true
            preRollStartedAt = now
            pendingCallPID = detected.pid
            onBeginPreRoll(detected.name, detected.pid)
        }

        switch state {
        case .prompting(let appName):
            pendingCallPID = detected?.pid ?? pendingCallPID
            retrySince = nil
            // The measurement the timing complaint needs. Nothing recorded
            // detection-to-prompt before this, so "about 10 seconds" could
            // only ever be answered with a hypothesis.
            if let started = preRollStartedAt {
                // Whole seconds would round a 3.4s prompt to 3 and make every
                // measurement look like the debounce exactly. The point is to
                // see the part we did NOT predict.
                let elapsed = now - started
                let ms = elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000
                watcherLog.notice("consent prompt shown \(ms, privacy: .public)ms after first detection")
            }
```

Inside the existing `onShowConsentPanel` response closure, change the three consent branches to:

```swift
                switch consent {
                case .accepted:
                    self.recordingPID = self.pendingCallPID
                    self.sawCall = false
                    self.goneSince = nil
                    self.isPreRolling = false     // consented; no longer a pre-roll
                    self.state = .recording(appName: appName)
                    self.onStartRecording(appName)
                case .declined:
                    self.discardPreRoll()
                    self.state = .declined
                case .timedOut:
                    // One retry per call. A second unanswered prompt goes quiet
                    // rather than interrupting repeatedly.
                    if self.hasRetried {
                        self.discardPreRoll()
                        self.state = .declined
                    } else {
                        // The pre-roll SURVIVES the first timeout: an unseen
                        // prompt is not a refusal, and deleting here would make
                        // the retry start 60s into the meeting.
                        self.hasRetried = true
                        self.retrySince = ContinuousClock.now
                        self.state = .awaitingRetry(appName: appName)
                    }
                }
```

Change the `.idle` case to discard a pre-roll that never got answered:

```swift
        case .idle:
            retrySince = nil
            hasRetried = false
            if previous.isRecording {
                recordingPID = nil
                sawCall = false
                onStopRecording()
            } else {
                // The call ended while we were still detecting, prompting or
                // waiting to re-ask. Nothing consented to it, so nothing keeps.
                discardPreRoll()
            }
```

Add the private helper at the end of the class:

```swift
    /// Idempotent: only fires when a pre-roll is actually running, so the
    /// several paths that reach it cannot double-delete.
    private func discardPreRoll() {
        guard isPreRolling else { return }
        isPreRolling = false
        preRollStartedAt = nil
        pendingCallPID = nil
        onDiscardPreRoll()
    }
```

Add the logger at the top of the file, below the imports:

```swift
private nonisolated let watcherLog = Logger(subsystem: "com.omwhisper.mac", category: "MeetingWatcher")
```

and add `import os` to the imports.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. **The pre-existing `MeetingWatcherLogicTests` must still pass unchanged** — that is the proof detection itself did not change.

- [ ] **Step 5: Prove the discard guard can fail**

Temporarily delete the `guard isPreRolling else { return }` line in `discardPreRoll()`, run the suite, and confirm `callEndingDuringPreRollDiscards` or `declineDiscards` reports a count above 1. Restore the line. A guard nothing exercises is decoration.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Meetings/MeetingWatcher.swift omwhisper-nativeTests/MeetingWatcherLogicTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(meetings): start recording at detection, keep only on consent

Making detection faster was the wrong goal: even instant detection
loses the opening, because the user still has to notice a corner
panel and click. Recording from first sight makes the latency
irrelevant instead of merely smaller.

Capture starts BEFORE the 3s debounce. That debounce exists to stop
us prompting on a transient mic open; it never had a reason to gate
capture.

The pre-roll survives the FIRST consent timeout — an unseen prompt
is not a refusal, and deleting there would make the retry start 60s
into the meeting. It does not survive the second.

nextState is untouched: its existing tests staying green is the
proof that detection itself did not change.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 5: Wire pre-roll into the app, and tell the truth on the panel

**Files:**
- Modify: `omwhisper-native/AppState.swift`
- Modify: `omwhisper-native/Meetings/MeetingConsentPanel.swift`

**Interfaces:**
- Consumes: `MeetingWatcher.onBeginPreRoll` / `onDiscardPreRoll` / `acceptPreRoll(appName:)` / `isPreRolling` (Task 4); `CallDetection.callWindowTitle(pid:appName:)` (Task 1).
- Produces: no new public API.

- [ ] **Step 1: Make `beginRecording` take the pid it should use**

`beginRecording` currently reads `meetingWatcher.recordingPID`, which is nil during pre-roll (it is only set on consent). Change the signature and the body:

```swift
    /// Start the recorder and capture the window title. Shared by pre-roll,
    /// the post-consent fallback, and the manual toggle.
    ///
    /// `pid` is passed rather than read from the watcher: during a pre-roll the
    /// watcher's recordingPID is deliberately still nil (nothing is consented),
    /// and reading it there would fall back to the frontmost app — which is
    /// OmWhisper itself, since Record lives in the hub window.
    ///
    /// `visible` is false for a pre-roll: if isRecordingMeeting were true the
    /// hub button would read "Stop recording" while the consent panel asks
    /// "Record this Teams call?" — two contradictory statements about one
    /// recording.
    @discardableResult
    private func beginRecording(appName: String, pid: pid_t?, visible: Bool) -> Bool {
        do {
            try meetingRecorder.start(appName: appName, preferredMicUID: audioInputDeviceUID)
            meetingStartedAt = Date()
            meetingAppName = appName
            let resolved = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            meetingWindowTitle = resolved.flatMap {
                CallDetection.callWindowTitle(pid: $0, appName: appName)
            }
            isRecordingMeeting = visible
            return true
        } catch {
            log.error("meeting recording failed to start: \(error)")
            meetingWatcher.failedToStartRecording()
            isRecordingMeeting = false
            return false
        }
    }
```

- [ ] **Step 2: Add the discard path**

Add after `endRecording()`:

```swift
    /// Stop an unconsented recording and delete everything it wrote. No row is
    /// inserted, so nothing surfaces in the UI and nothing is left behind.
    private func discardPreRollRecording() async {
        let directory = meetingRecorder.meetingDirectory
        await meetingRecorder.stop()
        isRecordingMeeting = false
        if let directory { try? FileManager.default.removeItem(at: directory) }
        meetingStartedAt = nil
        meetingAppName = nil
        meetingWindowTitle = nil
    }
```

- [ ] **Step 3: Rewire the watcher closures**

In the `meetingsEnabled` setter, replace the `onStartRecording` wiring and add the two new closures:

```swift
                meetingWatcher.onBeginPreRoll = { [weak self] appName, pid in
                    self?.beginRecording(appName: appName, pid: pid, visible: false)
                }
                meetingWatcher.onDiscardPreRoll = { [weak self] in
                    Task { await self?.discardPreRollRecording() }
                }
                meetingWatcher.onStartRecording = { [weak self] appName in
                    guard let self else { return }
                    // Normally the recording is already running from the
                    // pre-roll and consent just makes it visible. The start
                    // call is the fallback for a pre-roll that failed.
                    if meetingRecorder.meetingDirectory != nil {
                        isRecordingMeeting = true
                    } else {
                        beginRecording(appName: appName,
                                       pid: meetingWatcher.recordingPID, visible: true)
                    }
                }
```

- [ ] **Step 4: Make the hub's Record button promote a pre-roll**

Replace `toggleMeetingRecording`:

```swift
    func toggleMeetingRecording() {
        if isRecordingMeeting {
            meetingWatcher.markDeclined()
            Task { await endRecording() }
            return
        }
        // A pre-roll is running and the panel is asking: clicking Record here
        // is the same yes. Without this we would start a second recorder over
        // a live one.
        if meetingWatcher.isPreRolling, let appName = meetingAppName,
           meetingWatcher.acceptPreRoll(appName: appName) {
            meetingConsentPanel.dismiss()
            isRecordingMeeting = true
            return
        }
        let fallback = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Recording"
        let appName = meetingWatcher.enterRecording(fallbackAppName: fallback)
        beginRecording(appName: appName, pid: meetingWatcher.recordingPID, visible: true)
    }
```

- [ ] **Step 5: Change the consent panel copy**

The behaviour must not ship with copy that implies nothing has been captured. In `MeetingConsentPanel.swift`, replace the subtitle:

```swift
            Text("No answer? We'll ask once more, then leave it. Stays on this Mac.")
```

with:

```swift
            Text("Already capturing so you don't lose the start — deleted unless you say yes. Stays on this Mac.")
```

- [ ] **Step 6: Build and run the full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. Fix any `beginRecording` call site the signature change broke — the compiler names them.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/Meetings/MeetingConsentPanel.swift
git commit -m "$(cat <<'EOF'
✨ feat(meetings): wire pre-roll through AppState, and say so on the panel

isRecordingMeeting stays FALSE during a pre-roll: if it were true the
hub button would read "Stop recording" while the panel asks "Record
this Teams call?". The consent panel is the only UI until consent.

That makes the hub's Record button unambiguous during a pre-roll — it
means yes, and promotes what is already running rather than starting a
second recorder over a live one.

beginRecording now takes its pid instead of reading the watcher's:
recordingPID is deliberately nil until consent, and reading it during
a pre-roll would fall back to the frontmost app, which is OmWhisper
itself since Record lives in the hub window.

The copy change is not cosmetic. "Stays on this Mac" was true and
still is; the old line also implied nothing had been captured yet,
and that is no longer true.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

## Live verification owed

None of this is provable by unit test. After the branch lands, on the dev build:

1. **The latency number.** Start a real Teams call and read `consent prompt shown Nms after first detection` out of Copy Debug Info's RECENT LOG. This is the first actual measurement; the "about 10 seconds" report has never been reproduced against a stamp.
2. **The opening survives.** Start a call, speak immediately, wait for the prompt, accept. The transcript must contain the first sentence.
3. **A decline leaves nothing.** Note the meeting directory count under `Application Support/…/meetings`, decline a prompt, confirm the count is unchanged and no row appears.
4. **The panel copy** reads correctly at 320pt without wrapping badly.
5. **Ad-hoc 1:1 title.** A new ad-hoc Teams call is not filed as "Chat".
6. **Retitling an existing row.** Open the 6 Aug "Chat" meeting, hit Regenerate summary, confirm the title changes.
7. **The orphan sweep** — hardest to stage honestly: force-quit during a recording, relaunch, confirm the directory is gone AND that an existing meeting's directory is still present. The second half is the one that can fail.
8. **The second consent timeout discards.** Not unit-tested — it needs 60s of real wall time to re-prompt. Ignore a prompt twice on one call and confirm no directory survives.
