# SP1 — Meeting Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recorded meetings get real titles (calendar match + window-title fallback), attendee names, renameable speakers, and a regenerate-summary loop — per `docs/superpowers/specs/2026-08-01-meetings-competitive-parity-design.md` §1–2.

**Architecture:** A v2 GRDB migration adds `title`/`attendees`/`speakerNames` to `meetings.db` (FTS recreated to index title). The stored transcript stays immutable with generic labels; one pure function `MeetingDiarization.applySpeakerNames` resolves names at read time (view, copy, summarizer input). Title sources: opt-in EventKit calendar match at insert time, else the call window's AX title captured at record start. Regenerate-summary re-runs `MeetingSummarizer` over the resolved transcript without re-running ASR.

**Tech Stack:** Swift 6 (MainActor-by-default project), GRDB 7 (FTS5 `synchronize`), EventKit (macOS 14+ full-access API), ApplicationServices (AX), Swift Testing.

## Global Constraints

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: every new type meant to run off MainActor (e.g. `MeetingCalendar`) MUST be marked `nonisolated`, matching `MeetingStore`/`CallDetection`/`MeetingDiarization`.
- Xcode groups are file-system-synchronized — create/delete files on disk only; NEVER hand-edit `project.pbxproj` file references. Editing *build settings* in `project.pbxproj` (Task 4's Info.plist key) is allowed and has precedent.
- Meetings never egress: SP1 introduces no network calls. EventKit is read-only local data.
- Tests are Swift Testing (`@Test`/`#expect`), unit-only — NO XCUITest (standing rule). Pure logic gets tests; AX/EventKit/UI are live-verified.
- Full-suite command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`. Single suite: append `-only-testing:omwhisper-nativeTests/<SuiteClassOrStructName>` to `xcodebuild test ...`.
- Commit style: emoji conventional commits (`✨ feat(meetings): …`, `🐛 fix: …`), matching `git log`.
- All new settings use the `access(keyPath:)`/`withMutation(keyPath:)` pattern (see `AppState.meetingsEnabled`).

---

### Task 1: Schema v2 — title/attendees/speakerNames columns + FTS with title

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingStore.swift`
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `Meeting.title: String?`, `Meeting.attendees: [String]?`, `Meeting.speakerNames: [String: String]?` (all defaulted `nil`, declared AFTER `createdAt` so every existing memberwise-init call site compiles unchanged); `MeetingStore.setSpeakerNames(id: Int64, _ names: [String: String]?) throws`. FTS matches `title`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MeetingStoreTests.swift` (inside the existing suite struct):

```swift
    /// Replicates the v1 schema exactly (same migration identifier), seeds a row,
    /// then lets MeetingStore run only the NEW migration on the same queue —
    /// proving existing databases survive with data + FTS intact.
    private func makeV1Queue() throws -> DatabaseQueue {
        let dbQueue = DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createMeetings") { db in
            try db.create(table: "meetings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("directory", .text).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("transcript", .text)
                t.column("summary", .text)
                t.column("createdAt", .text).notNull()
            }
            try db.create(virtualTable: "meetings_fts", using: FTS5()) { t in
                t.synchronize(withTable: "meetings")
                t.column("transcript")
                t.column("summary")
                t.column("appName")
            }
        }
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (startedAt, appName, directory, durationSeconds, transcript, summary, createdAt)
                VALUES ('2026-07-01T10:00:00Z', 'Zoom', '/tmp/omw-v1-test', 60,
                        'quarterly roadmap discussion', NULL, '2026-07-01T11:00:00Z')
                """)
        }
        return dbQueue
    }

    @Test func v1DatabaseMigratesInPlace() throws {
        let queue = try makeV1Queue()
        let store = try MeetingStore(queue)
        let all = try store.fetchPage(offset: 0, limit: 10)
        #expect(all.count == 1)
        #expect(all.first?.title == nil)
        #expect(all.first?.attendees == nil)
        #expect(all.first?.speakerNames == nil)
        // FTS survived the drop-and-recreate and still matches old content.
        #expect(try store.search("roadmap", limit: 10).count == 1)
    }

    @Test func titleAttendeesSpeakerNamesRoundTrip() throws {
        let store = try makeStore()
        let id = try store.insert(Meeting(
            id: nil, startedAt: "2026-08-01T10:00:00Z", appName: "Zoom",
            directory: "/tmp/omw-json-test", durationSeconds: 60,
            transcript: nil, summary: nil, createdAt: "2026-08-01T10:00:00Z",
            title: "Q3 Planning", attendees: ["Alice", "Bob"]
        ))
        try store.setSpeakerNames(id: id, ["Speaker 1": "Alice"])
        let got = try store.get(id: id)
        #expect(got?.title == "Q3 Planning")
        #expect(got?.attendees == ["Alice", "Bob"])
        #expect(got?.speakerNames == ["Speaker 1": "Alice"])
        // Title is FTS-indexed.
        #expect(try store.search("Planning", limit: 10).count == 1)
    }

    @Test func setSpeakerNamesNilClears() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Meet")
        try store.setSpeakerNames(id: id, ["Speaker 1": "Alice"])
        try store.setSpeakerNames(id: id, nil)
        #expect(try store.get(id: id)?.speakerNames == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `Meeting` has no `title` parameter, `setSpeakerNames` undefined.

- [ ] **Step 3: Implement**

In `MeetingStore.swift`, add three properties to `Meeting` immediately after `var createdAt: String` (order matters — defaulted params at the end keep every existing `Meeting(...)` call site compiling):

```swift
    var createdAt: String
    // v2 (SP1 meeting identity). All optional with nil defaults so v1 rows and
    // existing call sites are untouched. attendees/speakerNames are stored as
    // JSON TEXT (GRDB encodes Codable collection properties as JSON).
    var title: String? = nil
    var attendees: [String]? = nil
    var speakerNames: [String: String]? = nil
```

In `MeetingStore.init`, after the existing `registerMigration("createMeetings")` block and before `try migrator.migrate(dbQueue)`:

```swift
        migrator.registerMigration("meetingIdentity") { db in
            try db.alter(table: Meeting.databaseTableName) { t in
                t.add(column: "title", .text)
                t.add(column: "attendees", .text)
                t.add(column: "speakerNames", .text)
            }
            // Recreate the FTS mirror to index title. synchronize() installed
            // triggers on `meetings` whose bodies reference meetings_fts; their
            // exact names are GRDB-internal, so find them via sqlite_master.
            let triggers = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'trigger' AND sql LIKE '%meetings_fts%'
                """)
            for name in triggers { try db.execute(sql: "DROP TRIGGER \"\(name)\"") }
            try db.drop(table: "meetings_fts")
            try db.create(virtualTable: "meetings_fts", using: FTS5()) { t in
                t.synchronize(withTable: Meeting.databaseTableName)
                t.column("transcript")
                t.column("summary")
                t.column("appName")
                t.column("title")
            }
        }
```

Add the store method after `setTranscriptAndSummary`:

```swift
    /// Replace the whole raw-label → display-name mapping (nil clears it).
    /// Re-transcribing produces fresh, unstable diarization labels, so callers
    /// reset this rather than trying to migrate names across runs.
    func setSpeakerNames(id: Int64, _ names: [String: String]?) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.speakerNames = names
            try m.update(db)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | tail -20`
Expected: PASS (all MeetingStoreTests, old and new).

Known contingency: if `v1DatabaseMigratesInPlace`'s `search("roadmap")` returns 0, GRDB's `synchronize` did not import pre-existing rows on creation — add this line at the end of the `meetingIdentity` migration and re-run:

```swift
            try db.execute(sql: """
                INSERT INTO meetings_fts(rowid, transcript, summary, appName, title)
                SELECT id, transcript, summary, appName, title FROM meetings
                """)
```

- [ ] **Step 5: Run the FULL suite** (the `Meeting` memberwise-init change touches other files' compilation)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "✨ feat(meetings): schema v2 — title, attendees, speaker names; FTS indexes title"
```

---

### Task 2: `applySpeakerNames` — pure name resolution over transcript markdown

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingDiarization.swift`
- Test: `omwhisper-nativeTests/MeetingDiarizationTests.swift`

**Interfaces:**
- Produces: `MeetingDiarization.applySpeakerNames(_ transcript: String, names: [String: String]) -> String` (static, nonisolated like the whole enum).
- Consumes: transcript markdown in `renderInterleaved`'s format (`**Speaker 1:** [0:03]\ntext`); `Meeting.speakerNames` from Task 1.

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MeetingDiarizationTests.swift`:

```swift
    @Test func applySpeakerNamesSubstitutesLabelsOnly() {
        let transcript = "**Speaker 1:** [0:03]\nhello **You:** [0:05]\nSpeaker 1 said hi to Speaker 10"
        let out = MeetingDiarization.applySpeakerNames(transcript, names: ["Speaker 1": "Alice"])
        // Label replaced; body-text "Speaker 1" and the distinct "Speaker 10" untouched.
        #expect(out.contains("**Alice:** [0:03]"))
        #expect(out.contains("Speaker 1 said hi to Speaker 10"))
    }

    @Test func applySpeakerNamesNeverRemapsYou() {
        let transcript = "**You:** [0:01]\nhi"
        let out = MeetingDiarization.applySpeakerNames(transcript, names: ["You": "Bob"])
        #expect(out == transcript)
    }

    @Test func applySpeakerNamesSkipsEmptyAndUnknown() {
        let transcript = "**Speaker 1:** [0:03]\nhello\n\n**Speaker 2:** [0:09]\nyes"
        let out = MeetingDiarization.applySpeakerNames(
            transcript, names: ["Speaker 1": "   ", "Speaker 3": "Ghost"])
        #expect(out == transcript)  // blank name skipped; Speaker 3 not present
    }

    @Test func speakerTenNotClobberedBySpeakerOne() {
        let transcript = "**Speaker 10:** [0:03]\nhello"
        let out = MeetingDiarization.applySpeakerNames(transcript, names: ["Speaker 1": "Alice"])
        #expect(out == transcript)  // "**Speaker 1:**" ≠ "**Speaker 10:**" — colon guards it
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingDiarizationTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `applySpeakerNames` undefined.

- [ ] **Step 3: Implement**

Add to the `MeetingDiarization` enum (after `renderInterleaved`):

```swift
    /// Replace generic speaker labels with user-given names at the markdown
    /// label sites only ("**Speaker 1:**" → "**Alice:**"); body text is never
    /// touched (the ":**" suffix is what anchors the match, and also keeps
    /// "Speaker 1" from matching inside "Speaker 10"). "You" is never remapped —
    /// the recorder's own accent in the UI depends on that label. Blank names
    /// are skipped so a cleared rename falls back to the generic label.
    static func applySpeakerNames(_ transcript: String, names: [String: String]) -> String {
        var out = transcript
        for (raw, name) in names where raw != "You" {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            out = out.replacingOccurrences(of: "**\(raw):**", with: "**\(trimmed):**")
        }
        return out
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingDiarizationTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingDiarization.swift omwhisper-nativeTests/MeetingDiarizationTests.swift
git commit -m "✨ feat(meetings): pure speaker-name resolution over transcript labels"
```

---

### Task 3: Window-title capture at record start

**Files:**
- Modify: `omwhisper-native/Meetings/CallDetection.swift`
- Modify: `omwhisper-native/Meetings/MeetingWatcher.swift` (one-word change: expose `recordingPID`)
- Modify: `omwhisper-native/AppState.swift` (`beginRecording`, `recordFinishedMeeting`)
- Test: `omwhisper-nativeTests/CallDetectionTests.swift`

**Interfaces:**
- Produces: `CallDetection.callWindowTitle(pid: pid_t) -> String?` (effectful AX); `CallDetection.cleanedMeetingTitle(windowTitle: String, appName: String) -> String?` (pure); `MeetingWatcher.recordingPID` readable (`private(set)`); `Meeting.title` populated on insert.
- Consumes: `Meeting.title` from Task 1; `CallDetection.hasCallLikeTitle` (existing).

- [ ] **Step 1: Write the failing tests** (pure title cleaning only — AX is live-verified)

Append to `omwhisper-nativeTests/CallDetectionTests.swift`:

```swift
    @Test func cleanedTitleTakesFirstSegmentOfBrowserTitle() {
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Q3 Planning - Google Meet - Google Chrome", appName: "Chrome") == "Q3 Planning")
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Weekly Sync – Zoom", appName: "Zoom") == "Weekly Sync")
    }

    @Test func cleanedTitleRejectsUselessTitles() {
        #expect(CallDetection.cleanedMeetingTitle(windowTitle: "Zoom", appName: "Zoom") == nil)
        #expect(CallDetection.cleanedMeetingTitle(windowTitle: "  ", appName: "Teams") == nil)
        #expect(CallDetection.cleanedMeetingTitle(windowTitle: "zoom - Meeting", appName: "Zoom") == nil)
    }

    @Test func cleanedTitleKeepsPlainTitles() {
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Design review with hardware team", appName: "Teams")
            == "Design review with hardware team")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/CallDetectionTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `cleanedMeetingTitle` undefined.

- [ ] **Step 3: Implement CallDetection additions**

Add to `CallDetection` (after `hasActiveCallWindow`):

```swift
    /// The recorded call's window title, for use as the meeting's display title:
    /// prefer a call-like-titled window, else the longest non-empty title
    /// (browser tabs put the meeting name in long titles). Same AX enumeration
    /// as hasActiveCallWindow; nil when AX yields nothing.
    static func callWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        var titles: [String] = []
        for window in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String,
               !title.trimmingCharacters(in: .whitespaces).isEmpty {
                titles.append(title)
            }
        }
        return titles.first(where: hasCallLikeTitle) ?? titles.max { $0.count < $1.count }
    }

    /// Pure: raw window title → meeting display title. Takes the first
    /// " – "/" - " segment (browsers suffix the product and browser names),
    /// nil when nothing usable remains — empty, or just the app's own name.
    static func cleanedMeetingTitle(windowTitle: String, appName: String) -> String? {
        let first = windowTitle
            .components(separatedBy: " – ").first!
            .components(separatedBy: " - ").first!
            .trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty,
              first.localizedCaseInsensitiveCompare(appName) != .orderedSame else { return nil }
        return first
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/CallDetectionTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Wire capture into the recording lifecycle**

In `MeetingWatcher.swift`, change the declaration (line ~38):

```swift
    /// The pid of the app whose call we're recording — for the AX window auto-stop.
    /// private(set): AppState reads it at record start to capture the window title.
    private(set) var recordingPID: pid_t?
```

In `AppState.swift`, next to the existing `meetingStartedAt`/`meetingAppName` stored properties, add:

```swift
    /// Raw call-window title captured at record start (the window is often gone
    /// by stop time — auto-stop fires BECAUSE it disappeared). Cleaned at insert.
    private var meetingWindowTitle: String?
```

In `beginRecording(appName:)`, after `meetingAppName = appName`:

```swift
            // Watcher pid in both auto and manual flows (enterRecording sets it
            // before this runs); frontmost as a last resort for manual recordings
            // of unrecognized apps.
            let pid = meetingWatcher.recordingPID
                ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            meetingWindowTitle = pid.flatMap { CallDetection.callWindowTitle(pid: $0) }
```

In `recordFinishedMeeting()`, before the `store.insert` call, compute the title:

```swift
        let title = meetingWindowTitle.flatMap {
            CallDetection.cleanedMeetingTitle(windowTitle: $0, appName: meetingAppName ?? "Meeting")
        }
```

Pass it in the insert (add after `createdAt:`): `title: title`. At the function's tail where `meetingStartedAt`/`meetingAppName` are cleared, add `meetingWindowTitle = nil`.

- [ ] **Step 6: Full build + suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all pass.

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Meetings/CallDetection.swift omwhisper-native/Meetings/MeetingWatcher.swift omwhisper-native/AppState.swift omwhisper-nativeTests/CallDetectionTests.swift
git commit -m "✨ feat(meetings): capture call-window title at record start as meeting title"
```

---

### Task 4: Calendar match (EventKit) — title + attendees

**Files:**
- Create: `omwhisper-native/Meetings/MeetingCalendar.swift`
- Modify: `omwhisper-native/AppState.swift` (setting + `recordFinishedMeeting`), `SettingsKeys` (same file, line ~1846)
- Modify: `omwhisper-native.xcodeproj/project.pbxproj` (one build setting, both configs)
- Test: `omwhisper-nativeTests/MeetingCalendarTests.swift` (create)

**Interfaces:**
- Produces: `MeetingCalendar.Match { title: String; attendees: [String] }`; `bestMatchIndex(candidates: [(start: Date, end: Date)], windowStart: Date, windowEnd: Date) -> Int?` (pure); `match(start: Date, end: Date) -> Match?`, `requestAccess() async -> Bool`, `hasAccess() -> Bool` (effectful); `AppState.meetingsCalendarEnabled: Bool` (default false).
- Consumes: `MeetingDiarization.overlap` (existing pure helper); `Meeting.title`/`attendees` from Task 1.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/MeetingCalendarTests.swift`:

```swift
import Foundation
import Testing
@testable import OmWhisper

@Suite("MeetingCalendar")
struct MeetingCalendarTests {
    private func date(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: Double(minutes) * 60)
    }

    @Test func picksGreatestOverlap() {
        // Recording 10:00–10:50. Event A 09:00–10:10 (10 min overlap),
        // event B 10:00–11:00 (50 min overlap) → B.
        let idx = MeetingCalendar.bestMatchIndex(
            candidates: [(date(540), date(610)), (date(600), date(660))],
            windowStart: date(600), windowEnd: date(650))
        #expect(idx == 1)
    }

    @Test func noOverlapMeansNoMatch() {
        let idx = MeetingCalendar.bestMatchIndex(
            candidates: [(date(0), date(60))],
            windowStart: date(600), windowEnd: date(650))
        #expect(idx == nil)
    }

    @Test func emptyCandidatesMeansNoMatch() {
        #expect(MeetingCalendar.bestMatchIndex(
            candidates: [], windowStart: date(0), windowEnd: date(1)) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingCalendarTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `MeetingCalendar` undefined.

- [ ] **Step 3: Implement MeetingCalendar**

Create `omwhisper-native/Meetings/MeetingCalendar.swift`:

```swift
//
//  MeetingCalendar.swift
//  OmWhisper
//
//  Read-only EventKit lookup: which calendar event overlaps a finished
//  recording's time window? Gives meetings a real title ("Q3 Planning") and
//  attendee names. Opt-in via AppState.meetingsCalendarEnabled — enabling the
//  toggle is what triggers the macOS Calendar permission prompt. Local data
//  only; nothing is written and nothing egresses.
//
//  nonisolated: called from recordFinishedMeeting (MainActor) but has no UI
//  affinity — matches CallDetection/MeetingStore's convention.
//

import EventKit
import Foundation

nonisolated enum MeetingCalendar {
    struct Match: Equatable {
        var title: String
        var attendees: [String]
    }

    static func hasAccess() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Triggers the system prompt on first call (macOS 14+ full-access API).
    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// Pure: index of the candidate with the greatest positive time-overlap
    /// with the recording window; nil when nothing overlaps at all.
    static func bestMatchIndex(
        candidates: [(start: Date, end: Date)], windowStart: Date, windowEnd: Date
    ) -> Int? {
        let overlaps = candidates.map {
            MeetingDiarization.overlap(
                $0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970,
                windowStart.timeIntervalSince1970, windowEnd.timeIntervalSince1970)
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }),
              overlaps[best] > 0 else { return nil }
        return best
    }

    /// Effectful: the best-overlapping non-all-day event for a recording window.
    /// All-day events are excluded — one would swallow every recording that day.
    /// The current user is dropped from attendees (they're the recorder).
    static func match(start: Date, end: Date) -> Match? {
        guard hasAccess() else { return nil }
        let store = EKEventStore()
        let events = store
            .events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }
        guard let index = bestMatchIndex(
            candidates: events.map { ($0.startDate, $0.endDate) },
            windowStart: start, windowEnd: end
        ) else { return nil }
        let event = events[index]
        let attendees = (event.attendees ?? [])
            .filter { !$0.isCurrentUser }
            .compactMap(\.name)
        return Match(title: event.title ?? "", attendees: attendees)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingCalendarTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Add the setting + wire into insert**

In `AppState.swift`, next to `meetingsEnabled`, add:

```swift
    /// Match finished recordings to calendar events for a real title + attendee
    /// names. Off by default; the Meetings UI requests Calendar permission when
    /// this is switched on (denied → the UI flips it back off).
    var meetingsCalendarEnabled: Bool {
        get {
            access(keyPath: \.meetingsCalendarEnabled)
            return UserDefaults.standard.object(forKey: SettingsKeys.meetingsCalendarEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.meetingsCalendarEnabled) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.meetingsCalendarEnabled)
            }
        }
    }
```

In `SettingsKeys` (AppState.swift ~line 1846), add:

```swift
    static let meetingsCalendarEnabled = "meetingsCalendarEnabled"
```

In `recordFinishedMeeting()`, replace Task 3's `let title = ...` with a calendar-first version and pass `attendees:` in the insert:

```swift
        var title = meetingWindowTitle.flatMap {
            CallDetection.cleanedMeetingTitle(windowTitle: $0, appName: meetingAppName ?? "Meeting")
        }
        var attendees: [String]?
        if meetingsCalendarEnabled, let started = meetingStartedAt,
           let match = MeetingCalendar.match(start: started, end: Date()) {
            if !match.title.isEmpty { title = match.title }
            if !match.attendees.isEmpty { attendees = match.attendees }
        }
```

…and in the `store.insert(Meeting(...))` call add `attendees: attendees` after `title: title`.

- [ ] **Step 6: Info.plist usage description**

In `omwhisper-native.xcodeproj/project.pbxproj`, in BOTH app-target build configurations (Debug and Release — the sections already containing `INFOPLIST_KEY_NSAudioCaptureUsageDescription`, lines ~389 and ~431), add alongside it:

```
INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = "OmWhisper reads your calendar only to title recorded meetings and list their attendees. Nothing is written or sent anywhere.";
```

Then verify Xcode's synthesis actually recognizes the key (the known `GENERATE_INFOPLIST_FILE` gotcha — third-party keys are silently dropped, and this must NOT be assumed):

```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -3
plutil -p ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/Build/Products/Debug/OmWhisper.app/Contents/Info.plist | grep -i calendar
```

Expected: a `NSCalendarsFullAccessUsageDescription` line. **If absent**, remove the build setting and instead extend the existing "Patch Info.plist (custom third-party keys)" `PBXShellScriptBuildPhase` (project.pbxproj ~line 203) with, following the `SUFeedURL` pattern exactly:

```
/usr/libexec/PlistBuddy -c "Delete :NSCalendarsFullAccessUsageDescription" "$PLIST" 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string 'OmWhisper reads your calendar only to title recorded meetings and list their attendees. Nothing is written or sent anywhere.'" "$PLIST"
```

…then re-run the two verification commands above until the grep shows the key.

- [ ] **Step 7: Full build + suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all pass.

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/Meetings/MeetingCalendar.swift omwhisper-native/AppState.swift omwhisper-native.xcodeproj/project.pbxproj omwhisper-nativeTests/MeetingCalendarTests.swift
git commit -m "✨ feat(meetings): opt-in calendar match — event title + attendees on finished recordings"
```

---

### Task 5: Regenerate summary + reset names on re-transcribe

**Files:**
- Modify: `omwhisper-native/AppState.swift` (`transcribeMeeting`, new `regenerateSummary`)

**Interfaces:**
- Produces: `AppState.regenerateSummary(id: Int64) async throws -> Meeting`.
- Consumes: `MeetingStore.setSpeakerNames` (Task 1), `MeetingDiarization.applySpeakerNames` (Task 2), existing `MeetingSummarizer.generate`/`systemLLM`/`SystemLLM.isAvailable()`.

No new pure logic — both methods compose already-tested pieces; per project convention the effectful paths are live-verified (Task 6's checklist).

- [ ] **Step 1: Reset speaker names on re-transcribe**

In `transcribeMeeting(id:)`, immediately before `try store.setTranscriptAndSummary(...)`:

```swift
        // Fresh diarization labels are not stable across runs — a mapping made
        // for the old labels would rename the wrong people. Reset it.
        try store.setSpeakerNames(id: id, nil)
```

- [ ] **Step 2: Add regenerateSummary**

After `transcribeMeeting` in `AppState.swift`:

```swift
    /// Re-run the summary over the existing transcript with speaker names
    /// resolved — no ASR/diarization. The correct-then-regenerate loop: rename
    /// "Speaker 1" to "Alice", regenerate, and the summary says Alice.
    func regenerateSummary(id: Int64) async throws -> Meeting {
        guard let store = meetingStore, let meeting = try store.get(id: id),
              let transcript = meeting.transcript else {
            throw MeetingStoreError.notFound
        }
        guard SystemLLM.isAvailable() else {
            errorMessage = "Apple Intelligence is off — enable it in Settings > AI to summarize meetings."
            return meeting
        }
        let resolved = MeetingDiarization.applySpeakerNames(
            transcript, names: meeting.speakerNames ?? [:])
        let summary = try await MeetingSummarizer.generate(transcript: resolved, polish: systemLLM)
        try store.setTranscriptAndSummary(id: id, transcript: transcript, summary: summary)
        return try store.get(id: id) ?? meeting
    }
```

- [ ] **Step 3: Full build + suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all pass.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(meetings): regenerate summary with resolved names; reset names on re-transcribe"
```

---

### Task 6: UI — titles, attendees, rename popover, calendar toggle, regenerate button

**Files:**
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift`

**Interfaces:**
- Consumes: everything above — `meeting.title/attendees/speakerNames`, `MeetingCalendar.requestAccess`, `appState.meetingsCalendarEnabled`, `appState.regenerateSummary(id:)`, `MeetingDiarization.applySpeakerNames`, `MeetingStore.setSpeakerNames`.
- Produces: no new API. Pure SwiftUI — no unit tests per project convention; the existing suite staying green is the regression proof, live checklist below is the verification.

- [ ] **Step 1: List rows + detail header show the real title**

In `meetingRow(_:)`, change the first `Text(meeting.appName)` to `Text(meeting.title ?? meeting.appName)`. Update the row's `.accessibilityLabel` the same way.

In `MeetingDetailView.header`, change the title `Text(meeting.appName)` to `Text(meeting.title ?? meeting.appName)`. In `metaLine`, when `meeting.title != nil` prepend `meeting.appName` to `parts` (so the app is still visible once the title takes the headline), and append an attendee line under the meta text:

```swift
            // inside the header VStack, directly under the metaLine Text:
            if let attendees = meeting.attendees, !attendees.isEmpty {
                Text("With \(attendees.joined(separator: ", "))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Porcelain.dim)
                    .lineLimit(1)
            }
```

- [ ] **Step 2: Calendar toggle in the settings bar**

In `settingsBar(state:)`, after the existing "Detect and record meetings" Toggle:

```swift
            Toggle("Match calendar events", isOn: Binding(
                get: { state.meetingsCalendarEnabled },
                set: { on in
                    guard on else { state.meetingsCalendarEnabled = false; return }
                    Task {
                        if await MeetingCalendar.requestAccess() {
                            state.meetingsCalendarEnabled = true
                        } else {
                            state.meetingsCalendarEnabled = false
                            errorMessage = "Calendar access was denied — grant it in System Settings › Privacy & Security › Calendars."
                        }
                    }
                }
            ))
            .tint(Color.Porcelain.emerald)
            .foregroundStyle(Color.Porcelain.ink)
```

Note: `errorMessage` here is `HubMeetingsSectionView`'s own `@State` (the alert already exists on `browser`); the settings bar renders outside `browser` when the list is empty, so ALSO move the `.alert(...)` modifier from `browser` up onto the outer `VStack` in `body` so a denial always surfaces.

- [ ] **Step 3: Regenerate-summary button + name-resolved copy**

In `MeetingDetailView.header`'s button row, after the Transcribe/Re-transcribe button:

```swift
                if meeting.transcript != nil {
                    Button("Regenerate summary") { regenerate() }.disabled(busy)
                }
```

Add next to `run()`:

```swift
    private func regenerate() {
        guard let id = meeting.id else { return }
        working = true
        errorMessage = nil
        Task {
            do { _ = try await appState.regenerateSummary(id: id) }
            catch { errorMessage = error.localizedDescription }
            await onChanged()
            working = false
        }
    }
```

Change `copyTranscript()` to copy the name-resolved transcript:

```swift
    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            MeetingDiarization.applySpeakerNames(
                meeting.transcript ?? "", names: meeting.speakerNames ?? [:]),
            forType: .string)
    }
```

- [ ] **Step 4: Rename popover on speaker labels**

In `MeetingDetailView`, add:

```swift
    private var speakerNames: [String: String] { meeting.speakerNames ?? [:] }

    private func rename(_ raw: String, to name: String) {
        guard let id = meeting.id, let store = appState.meetingStore else { return }
        var names = speakerNames
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { names.removeValue(forKey: raw) } else { names[raw] = trimmed }
        try? store.setSpeakerNames(id: id, names.isEmpty ? nil : names)
        Task { await onChanged() }
    }
```

Change the transcript `ForEach` to pass display names + rename hooks:

```swift
                VStack(spacing: 0) {
                    ForEach(turns) { turn in
                        TranscriptTurnRow(
                            turn: turn,
                            displayName: speakerNames[turn.speaker] ?? turn.speaker,
                            suggestions: meeting.attendees ?? [],
                            onRename: turn.isYou ? nil : { rename(turn.speaker, to: $0) }
                        )
                    }
                }
```

Rework `TranscriptTurnRow`: add the three new properties and make the label a button when renameable. Replace the speaker `Text(turn.speaker)` block:

```swift
private struct TranscriptTurnRow: View {
    let turn: TranscriptTurn
    let displayName: String
    let suggestions: [String]
    /// nil = not renameable ("You").
    let onRename: ((String) -> Void)?

    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .trailing, spacing: 1) {
                speakerLabel
                if let timecode = turn.timecode {
                    Text(timecode)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.Porcelain.dim)
                }
            }
            .frame(width: 104, alignment: .trailing)

            Text(turn.text)
                .font(.system(size: 15))
                .lineSpacing(5)  // ~1.55 line height (design skill §3)
                .foregroundStyle(Color.Porcelain.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName)\(turn.timecode.map { " at \($0)" } ?? ""): \(turn.text)")
    }

    @ViewBuilder
    private var speakerLabel: some View {
        if let onRename {
            Button {
                draft = displayName == turn.speaker ? "" : displayName
                renaming = true
            } label: {
                Text(displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                    .multilineTextAlignment(.trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename \(displayName)")
            .popover(isPresented: $renaming, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rename \(turn.speaker)")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { commit() }
                    if !suggestions.isEmpty {
                        // Calendar attendees as one-tap suggestions.
                        HStack(spacing: 6) {
                            ForEach(suggestions.prefix(4), id: \.self) { name in
                                Button(name) { draft = name; commit() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                    HStack {
                        Button("Clear") { draft = ""; commit() }
                            .controlSize(.small)
                        Spacer()
                        Button("Save") { commit() }
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.small)
                    }
                }
                .padding(14)
            }
        } else {
            Text(displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.Porcelain.emerald)
                .multilineTextAlignment(.trailing)
        }
    }

    private func commit() {
        renaming = false
        onRename?(draft)
    }
}
```

(The `isYou` accent moves with the structure: the non-renameable branch is exactly the "You" case and keeps emerald; renameable speakers keep ink, as today.)

Also update `metaLine`'s speaker count to count display names — no change needed: it counts distinct raw labels via `turns`, which is still correct after rename (same partition).

- [ ] **Step 5: Full build + suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/UI/HubMeetingsSectionView.swift
git commit -m "✨ feat(meetings): titles + attendees in UI, speaker rename popover, regenerate button, calendar toggle"
```

---

### Live verification checklist (user, real hardware — after all tasks)

1. **Window title**: record a manual meeting with a real call window open → the list row and detail header show the window-derived title, not "zoom.us"/app name.
2. **Calendar**: toggle "Match calendar events" on → macOS Calendar prompt appears; with a calendar event covering the recording window, a new recording shows the event's title and "With …" attendees. Deny the prompt in a fresh grant state → toggle flips back off with the error alert.
3. **Rename loop**: on a diarized transcript, click "Speaker 1" → popover; pick an attendee chip or type a name → every Speaker 1 turn shows the name instantly; "Copy transcript" pastes named labels; **Regenerate summary** → the summary refers to the name. Clear the name → label reverts to "Speaker 1".
4. **Reset on re-transcribe**: after renaming, press Re-transcribe → names reset to generic labels (fresh diarization).
5. **Regression**: a recording with calendar toggle off and no useful window title behaves exactly as before (appName everywhere, no attendee line).
