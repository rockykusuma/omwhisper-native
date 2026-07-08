# S1 — Memory Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A background daemon periodically captures the frontmost window's visible text (with app/window/URL metadata), stores it in a separate, searchable local GRDB database with dedup and retention, respecting exclusions (sensitive apps, private browsing, excluded domains). No search/surfacing UI — that's S5. Off by default.

**Architecture:** `BrowserURL` (ported from smriti) → `WindowSnapshotReader` (extends `ScreenContextReader`'s proven AX walk with richer metadata) → `MemorySnapshot`/`MemoryStore` (new GRDB `DatabaseQueue`, its own file, FTS5-searchable via GRDB's `synchronize(withTable:)`) → `MemoryCapture` (Timer-driven daemon, mirrors `MeetingWatcher`'s poll pattern) → `AppState` wiring + `MemorySettingsView` + a debug self-test.

**Tech Stack:** Swift 6, AppKit/ApplicationServices (`AXUIElement`), GRDB 7.11.1 (already a project dependency — FTS5 is compiled in by default, no new SPM trait needed), CryptoKit (`SHA256`, system framework), Swift Testing.

## Global Constraints

- Off by default: `AppState.memoryEnabled` defaults to `false`. `MemoryCapture` is not instantiated or started unless this is on — no `Timer` runs at all for a user who hasn't opted in.
- Separate database from `HistoryStore` — `memory.db`, not `history.db`, same Application Support directory. A user must be able to wipe all captured memory without touching dictation history, and vice versa.
- No redaction on write — snapshots are stored raw, matching smriti's own design choice and this app's "local by default, fully trusted" story. `Redactor` is not ported in this plan.
- Exclusions are checked *before* any write is attempted — `WindowSnapshotReader.captureFrontmost()` returns `nil` for excluded bundle IDs/titles (reusing `ScreenContextReader.isExcluded`), and `MemoryCapture.tick()` checks domain exclusion before calling `MemoryStore.upsert(...)` — an excluded capture is never staged then filtered.
- Pause is a settings-backed flag (`AppState.memoryPaused`) the capture loop checks each tick — not smriti's `SIGUSR1` signal handler, which is a workaround for a separate daemon process this app doesn't have. Pause does NOT need to suppress for dictation — memory capture reads the frontmost window's text, which doesn't conflict with an active dictation session the way `MeetingWatcher`/`ReplyAssistMonitor` triggering would.
- Reuse `ScreenContextReader`'s existing bundle-ID/title exclusion lists and AX tree-walk (`collectText`/`copyAttribute`) rather than duplicating them — Task 2 changes their visibility from `private` to internal so `WindowSnapshotReader` can call them, without changing `ScreenContextReader`'s existing public behavior (`captureFrontmostWindowText()`'s contract is unchanged; S2 must not regress).
- `captureIntervalSeconds: 5`, `maxContentLength: 20_000`, `retentionDays: 90` — smriti's proven defaults, kept as this app's defaults too.
- GRDB FTS5 API, confirmed real against the pinned GRDB 7.11.1 source (not guessed): `db.create(virtualTable:using: FTS5()) { t in t.synchronize(withTable: "snapshots"); t.column(...) }` auto-generates the AFTER INSERT/DELETE/UPDATE sync triggers — no hand-written trigger SQL. `db.dropFTS5SynchronizationTriggers(forTable:)` is required if the FTS table is ever dropped (not needed in this plan, noted for completeness).

---

### Task 1: `BrowserURL`

**Files:**
- Create: `omwhisper-native/Memory/BrowserURL.swift`
- Test: `omwhisper-nativeTests/BrowserURLTests.swift`

**Interfaces:**
- Produces: `nonisolated enum BrowserURL { static let browserBundleIds: Set<String>; static func isBrowser(_ bundleId: String) -> Bool; static func url(bundleId:window:) -> String?; static func domain(of urlString: String) -> String?; static func domain(_:matches:) -> Bool }`. Consumed by Task 2 (`WindowSnapshotReader`) and Task 4 (`MemoryCapture`'s domain exclusion).

Only `domain(of:)` and `domain(_:matches:)` are pure/unit-testable — the AX tree walks (`findWebAreaURL`/`findAddressBarValue`) need a live browser window, covered by live verification in Task 7.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OmWhisper

@Suite("BrowserURL")
struct BrowserURLTests {
    @Test("domain(of:) strips a www. prefix")
    func stripsWWW() {
        #expect(BrowserURL.domain(of: "https://www.example.com/page") == "example.com")
    }

    @Test("domain(of:) lowercases the host")
    func lowercases() {
        #expect(BrowserURL.domain(of: "https://Example.COM") == "example.com")
    }

    @Test("domain(of:) returns nil for a string with no host")
    func noHost() {
        #expect(BrowserURL.domain(of: "not a url") == nil)
    }

    @Test("domain matches itself exactly")
    func exactMatch() {
        #expect(BrowserURL.domain("example.com", matches: "example.com") == true)
    }

    @Test("a subdomain matches its parent domain")
    func subdomainMatches() {
        #expect(BrowserURL.domain("docs.example.com", matches: "example.com") == true)
    }

    @Test("an unrelated domain does not match")
    func unrelatedDoesNotMatch() {
        #expect(BrowserURL.domain("example.com", matches: "example.org") == false)
        #expect(BrowserURL.domain("notexample.com", matches: "example.com") == false)
    }

    @Test("isBrowser recognizes known browser bundle ids")
    func recognizesBrowsers() {
        #expect(BrowserURL.isBrowser("com.apple.Safari") == true)
        #expect(BrowserURL.isBrowser("com.google.Chrome") == true)
        #expect(BrowserURL.isBrowser("com.omwhisper.mac") == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/BrowserURLTests 2>&1 | tail -30`
Expected: FAIL — `BrowserURL` doesn't exist yet.

- [ ] **Step 3: Implement `BrowserURL.swift`**

```swift
//
//  BrowserURL.swift
//  OmWhisper
//
//  Resolves the URL of the page shown in a browser window, using only the
//  Accessibility API (no AppleScript, so no extra Automation permission).
//  Ported near-verbatim from smriti's BrowserURL.swift (same author, MIT,
//  read-only reference) -- deferred as scope creep for S2 (nothing there
//  called it), genuinely needed now for S1's domain-based exclusion.
//
//  Strategy:
//    1. Find the AXWebArea in the window and read its AXURL -- works for
//       Safari, and for Chromium/Firefox when their AX trees are hydrated.
//    2. Chromium fallback: read the address bar text field and re-add the
//       scheme Chrome strips from display. Real, documented gotcha:
//       "Chromium hides AXURL until a screen reader is active."
//

import ApplicationServices
import Foundation

nonisolated enum BrowserURL {
    static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser", // Arc
        "org.mozilla.firefox",
    ]

    static func isBrowser(_ bundleId: String) -> Bool {
        browserBundleIds.contains(bundleId)
    }

    /// Best-effort URL for a browser window. Returns nil for non-browsers or
    /// when the AX tree doesn't expose one.
    static func url(bundleId: String, window: AXUIElement) -> String? {
        guard isBrowser(bundleId) else { return nil }

        if let url = findWebAreaURL(window, depth: 0) {
            return url
        }
        if let typed = findAddressBarValue(window, depth: 0) {
            let trimmed = typed.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
            if trimmed.contains("://") { return trimmed }
            return "https://" + trimmed
        }
        return nil
    }

    /// Host with any leading "www." removed; nil when the URL has no host.
    static func domain(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// True when `domain` equals `excluded` or is a subdomain of it
    /// (docs.example.com matches example.com).
    static func domain(_ domain: String, matches excluded: String) -> Bool {
        let d = domain.lowercased()
        let e = excluded.lowercased()
        return d == e || d.hasSuffix("." + e)
    }

    // MARK: - AX tree walks (shallow, breadth-limited)

    private static func findWebAreaURL(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 30 else { return nil }
        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""
        if role == "AXWebArea",
           let url = copyAttribute(element, "AXURL") {
            if let cfURL = url as? URL { return cfURL.absoluteString }
            if let s = url as? String, !s.isEmpty { return s }
        }
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        for child in children {
            if let found = findWebAreaURL(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func findAddressBarValue(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 12 else { return nil } // toolbar lives near the top of the tree
        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""
        if role == kAXTextFieldRole {
            let label = [
                copyAttribute(element, kAXTitleAttribute) as? String,
                copyAttribute(element, kAXDescriptionAttribute) as? String,
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            if label.contains("address"),
               let value = copyAttribute(element, kAXValueAttribute) as? String {
                return value
            }
        }
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        for child in children {
            if let found = findAddressBarValue(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/BrowserURLTests 2>&1 | tail -30`
Expected: PASS, 7/7.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/BrowserURL.swift omwhisper-nativeTests/BrowserURLTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(memory): add BrowserURL" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 2: `WindowSnapshotReader` (extends `ScreenContextReader`)

**Files:**
- Modify: `omwhisper-native/Context/ScreenContextReader.swift` — change 3 members from `private static` to internal (no access modifier), matching this project's default internal visibility
- Create: `omwhisper-native/Memory/WindowSnapshotReader.swift`

**Interfaces:**
- Consumes: `ScreenContextReader.isExcluded(bundleID:windowTitle:)`, `ScreenContextReader.collectText(_:depth:into:budget:deadline:)`, `ScreenContextReader.copyAttribute(_:_:)` (all made internal by this task), `BrowserURL.url(bundleId:window:)` (Task 1).
- Produces: `nonisolated enum WindowSnapshotReader { struct Snapshot { let bundleID: String; let appName: String; let windowTitle: String; let content: String; let url: String? }; static func captureFrontmost(timeBudget: TimeInterval = 2.0) -> Snapshot? }`. Consumed by Task 4 (`MemoryCapture`).

No unit test for this task — it's AX-dependent, exactly like `ScreenContextReader.captureFrontmostWindowText()` itself has no unit test. Covered by live verification in Task 7. `ScreenContextReader`'s own existing tests (if any) must still pass unchanged after this visibility change — see Step 3.

- [ ] **Step 1: Change 3 members in `ScreenContextReader.swift` from `private static` to `static`**

In `omwhisper-native/Context/ScreenContextReader.swift`, remove the `private` keyword from exactly these three declarations (leave every other line, including `append`, untouched — `append` stays private since only `collectText` calls it):

```swift
    private static let textBearingRoles: Set<String> = [
```
→
```swift
    static let textBearingRoles: Set<String> = [
```

```swift
    private static func collectText(
```
→
```swift
    static func collectText(
```

```swift
    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
```
→
```swift
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
```

- [ ] **Step 2: Run the full test suite to confirm S2's existing behavior is unchanged**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: all passing (124 — 117 baseline + Task 1's 7, unchanged by this task — a visibility-only change adds no new tests and shouldn't drop any).

- [ ] **Step 3: Implement `WindowSnapshotReader.swift`**

```swift
//
//  WindowSnapshotReader.swift
//  OmWhisper
//
//  Frontmost-window capture for S1's background memory daemon -- returns
//  richer metadata (bundleID, appName, windowTitle, url) than S2's
//  ScreenContextReader.captureFrontmostWindowText(), which only needs the
//  text itself. Reuses ScreenContextReader's proven AX walk (collectText)
//  and exclusion check (isExcluded) rather than forking them; only the
//  thin wrapper around the walk is new here.
//
//  nonisolated: same rationale as ScreenContextReader -- AXUIElement calls
//  are cross-process IPC with no MainActor affinity.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum WindowSnapshotReader {
    struct Snapshot {
        let bundleID: String
        let appName: String
        let windowTitle: String
        let content: String
        let url: String?
    }

    /// nil when there's nothing meaningful, the app/window is excluded, or
    /// the walk hits its deadline before finding anything. Never throws.
    static func captureFrontmost(timeBudget: TimeInterval = 2.0) -> Snapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = ScreenContextReader.copyAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        let windowElement = window as! AXUIElement

        let title = (ScreenContextReader.copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        guard !ScreenContextReader.isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }

        var lines: [String] = []
        var budget = 50_000
        let deadline = Date().addingTimeInterval(timeBudget)
        ScreenContextReader.collectText(windowElement, depth: 0, into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        let url = BrowserURL.url(bundleId: bundleID, window: windowElement)
        return Snapshot(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            windowTitle: title,
            content: content,
            url: url
        )
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Context/ScreenContextReader.swift omwhisper-native/Memory/WindowSnapshotReader.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(memory): add WindowSnapshotReader, expose ScreenContextReader internals" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 3: `MemorySnapshot` + `MemoryStore`

**Files:**
- Create: `omwhisper-native/Memory/MemorySnapshot.swift`
- Create: `omwhisper-native/Memory/MemoryStore.swift`
- Test: `omwhisper-nativeTests/MemoryStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct MemorySnapshot: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
      static let databaseTableName = "snapshots"
      var id: Int64?
      var appName: String
      var bundleID: String
      var windowTitle: String
      var content: String
      var url: String
      var contentHash: String
      var capturedAt: String
      var lastSeenAt: String
  }
  nonisolated final class MemoryStore: Sendable {
      init(_ dbQueue: DatabaseQueue) throws
      static func open(atPath path: String) throws -> MemoryStore
      static func contentHash(_ content: String) -> String
      static func upsertDecision(existing: MemorySnapshot?, appName: String, bundleID: String, windowTitle: String, content: String, url: String, contentHash: String, now: String) -> MemorySnapshot
      func upsert(appName: String, bundleID: String, windowTitle: String, content: String, url: String) throws
      func search(_ query: String, limit: Int) throws -> [MemorySnapshot]
      func prune(olderThanDays days: Int) throws
  }
  ```
  Consumed by Task 4 (`MemoryCapture`), Task 5 (`AppState`), Task 6 (`MemorySelfTest`).

Only `contentHash(_:)` and `upsertDecision(...)` are pure/unit-testable without a real database — everything else (migration, real upsert/search/prune against SQLite) is exercised directly in this task's tests too, matching `HistoryStoreTests`' existing pattern of testing a real, temporary `DatabaseQueue`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import GRDB
@testable import OmWhisper

@Suite("MemoryStore")
struct MemoryStoreTests {
    private func makeStore() throws -> MemoryStore {
        try MemoryStore(DatabaseQueue())  // in-memory, fresh per test
    }

    @Test("contentHash is stable and content-sensitive")
    func hashIsStableAndSensitive() {
        let a = MemoryStore.contentHash("hello world")
        let b = MemoryStore.contentHash("hello world")
        let c = MemoryStore.contentHash("hello there")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("upsertDecision creates a new row when nothing matches")
    func decisionCreatesNew() {
        let row = MemoryStore.upsertDecision(
            existing: nil, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled",
            content: "hello", url: "", contentHash: "h1", now: "2026-07-08T00:00:00Z"
        )
        #expect(row.id == nil)
        #expect(row.capturedAt == "2026-07-08T00:00:00Z")
        #expect(row.lastSeenAt == "2026-07-08T00:00:00Z")
    }

    @Test("upsertDecision reuses the existing row, bumping only lastSeenAt")
    func decisionReusesExisting() {
        let existing = MemorySnapshot(
            id: 42, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled",
            content: "hello", url: "", contentHash: "h1", capturedAt: "2026-07-08T00:00:00Z", lastSeenAt: "2026-07-08T00:00:00Z"
        )
        let row = MemoryStore.upsertDecision(
            existing: existing, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled",
            content: "hello", url: "", contentHash: "h1", now: "2026-07-08T00:05:00Z"
        )
        #expect(row.id == 42)
        #expect(row.capturedAt == "2026-07-08T00:00:00Z")  // unchanged
        #expect(row.lastSeenAt == "2026-07-08T00:05:00Z")  // bumped
    }

    @Test("upsert inserts on first capture and dedupes an unchanged repeat")
    func upsertDedupesRepeat() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "hello", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "hello", url: "")
        let results = try store.search("hello", limit: 10)
        #expect(results.count == 1)
    }

    @Test("upsert with changed content creates a second row")
    func upsertChangedContentInsertsNew() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "hello", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Untitled", content: "goodbye", url: "")
        let results = try store.search("hello", limit: 10)
        #expect(results.count == 1)
        let all = try store.search("hello OR goodbye", limit: 10)
        #expect(all.count == 2)
    }

    @Test("search finds content via FTS5")
    func searchFindsContent() throws {
        let store = try makeStore()
        try store.upsert(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Inbox", content: "quarterly budget review", url: "")
        let results = try store.search("budget", limit: 10)
        #expect(results.count == 1)
        #expect(results.first?.appName == "Mail")
    }

    @Test("prune(olderThanDays: 0) is a no-op")
    func pruneZeroIsNoOp() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Old", content: "stale content", url: "")
        try store.prune(olderThanDays: 0)
        #expect(try store.search("stale", limit: 10).count == 1)
    }

    @Test("prune removes rows whose lastSeenAt is older than the retention window")
    func pruneRemovesOldRows() throws {
        let store = try makeStore()
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Old", content: "stale content", url: "")
        try store.upsert(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Fresh", content: "fresh content", url: "")
        // upsert always stamps lastSeenAt = now, so directly backdate the
        // "Old" row via dbQueue (internal, not private -- exposed
        // specifically so tests can exercise real time-based deletion
        // without injecting a clock into MemoryStore's production API).
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-100 * 86_400))
        try store.dbQueue.write { db in
            try MemorySnapshot.filter(Column("windowTitle") == "Old").updateAll(db, Column("lastSeenAt").set(to: old))
        }
        try store.prune(olderThanDays: 90)
        #expect(try store.search("stale", limit: 10).isEmpty)
        #expect(try store.search("fresh", limit: 10).count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/MemoryStoreTests 2>&1 | tail -30`
Expected: FAIL — `MemoryStore`/`MemorySnapshot` don't exist yet.

- [ ] **Step 3: Implement `MemorySnapshot.swift`**

```swift
//
//  MemorySnapshot.swift
//  OmWhisper
//

import GRDB

nonisolated struct MemorySnapshot: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "snapshots"

    var id: Int64?
    var appName: String
    var bundleID: String
    var windowTitle: String
    var content: String
    var url: String
    var contentHash: String
    var capturedAt: String
    var lastSeenAt: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 4: Implement `MemoryStore.swift`**

```swift
//
//  MemoryStore.swift
//  OmWhisper
//
//  Separate GRDB database from HistoryStore (own file, own DatabaseQueue) --
//  memory (background screen capture) and dictation history are
//  differently-sensitive data with different default-on/off states; a user
//  must be able to wipe one without touching the other.
//
//  Schema ported from smriti's Store.swift (raw SQLite3 there; this is a
//  from-scratch GRDB schema, not a port of that C API code):
//  snapshots(id, appName, bundleID, windowTitle, content, url, contentHash,
//  capturedAt, lastSeenAt), UNIQUE(bundleID, windowTitle, contentHash) dedup
//  index, an FTS5 virtual table kept in sync via GRDB's synchronize(withTable:)
//  (confirmed real against the pinned GRDB 7.11.1 source -- auto-generates
//  the AFTER INSERT/DELETE/UPDATE triggers, no hand-written trigger SQL).
//
//  nonisolated: GRDB I/O has no MainActor affinity, matching HistoryStore's
//  own concurrency note.
//

import CryptoKit
import Foundation
import GRDB

nonisolated final class MemoryStore: Sendable {
    /// internal, not private -- MemoryStoreTests reaches in to backdate a
    /// row directly, the only way to exercise prune()'s real deletion path
    /// without injecting a clock into the production upsert/prune API.
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createSnapshots") { db in
            try db.create(table: MemorySnapshot.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("appName", .text).notNull()
                t.column("bundleID", .text).notNull()
                t.column("windowTitle", .text).notNull()
                t.column("content", .text).notNull()
                t.column("url", .text).notNull().defaults(to: "")
                t.column("contentHash", .text).notNull()
                t.column("capturedAt", .text).notNull()
                t.column("lastSeenAt", .text).notNull()
            }
            try db.create(
                index: "idx_snapshots_dedup",
                on: MemorySnapshot.databaseTableName,
                columns: ["bundleID", "windowTitle", "contentHash"],
                unique: true
            )
            try db.create(virtualTable: "snapshots_fts", using: FTS5()) { t in
                t.synchronize(withTable: MemorySnapshot.databaseTableName)
                t.column("content")
                t.column("windowTitle")
                t.column("appName")
            }
        }
        try migrator.migrate(dbQueue)
    }

    static func open(atPath path: String) throws -> MemoryStore {
        try MemoryStore(DatabaseQueue(path: path))
    }

    static func contentHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Pure decision: given the existing row matching this capture's dedup
    /// key (if any), what row should be written -- the same row with only
    /// lastSeenAt bumped (and url refreshed, since a page's URL can change
    /// while its title/content stay identical), or a brand new row.
    nonisolated static func upsertDecision(
        existing: MemorySnapshot?, appName: String, bundleID: String, windowTitle: String,
        content: String, url: String, contentHash: String, now: String
    ) -> MemorySnapshot {
        if var existing, existing.contentHash == contentHash {
            existing.lastSeenAt = now
            existing.url = url
            return existing
        }
        return MemorySnapshot(
            id: nil, appName: appName, bundleID: bundleID, windowTitle: windowTitle,
            content: content, url: url, contentHash: contentHash, capturedAt: now, lastSeenAt: now
        )
    }

    func upsert(appName: String, bundleID: String, windowTitle: String, content: String, url: String) throws {
        let hash = Self.contentHash(content)
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            let existing = try MemorySnapshot
                .filter(Column("bundleID") == bundleID
                    && Column("windowTitle") == windowTitle
                    && Column("contentHash") == hash)
                .fetchOne(db)
            var row = Self.upsertDecision(
                existing: existing, appName: appName, bundleID: bundleID, windowTitle: windowTitle,
                content: content, url: url, contentHash: hash, now: now
            )
            try row.save(db)
        }
    }

    func search(_ query: String, limit: Int = 20) throws -> [MemorySnapshot] {
        let terms = query.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " OR ")
        return try dbQueue.read { db in
            try MemorySnapshot.fetchAll(db, sql: """
                SELECT snapshots.* FROM snapshots
                JOIN snapshots_fts ON snapshots_fts.rowid = snapshots.id
                WHERE snapshots_fts MATCH ?
                ORDER BY rank LIMIT ?
                """, arguments: [terms, limit])
        }
    }

    func prune(olderThanDays days: Int) throws {
        guard days > 0 else { return }
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400))
        try dbQueue.write { db in
            try MemorySnapshot.filter(Column("lastSeenAt") < cutoff).deleteAll(db)
        }
    }
}
```

Note on `search`'s term-joining: individual multi-word queries are OR'd (`"budget" OR "goodbye"`) rather than AND'd, matching smriti's `searchRelated()` (broader recall for a memory search over precision) — Task 3's own tests rely on this (`"hello OR goodbye"` finding both rows is exercised via passing pre-OR'd input directly, since `search()` already OR's each space-separated term internally; the test passes a query whose split terms are the literal words `hello`, `OR`, `goodbye`, which still works because `OR` itself matches no content and is harmless in an OR chain — this is intentional, not a bug, but worth understanding when reading the test).

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/MemoryStoreTests 2>&1 | tail -40`
Expected: PASS, 8/8.

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: all passing (132 — 124 running total after Tasks 1-2 + this task's 8).

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/Memory/MemorySnapshot.swift omwhisper-native/Memory/MemoryStore.swift omwhisper-nativeTests/MemoryStoreTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(memory): add MemorySnapshot + MemoryStore (GRDB, FTS5)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 4: `MemoryCapture`

**Files:**
- Create: `omwhisper-native/Memory/MemoryCapture.swift`
- Test: `omwhisper-nativeTests/MemoryCaptureExclusionTests.swift`

**Interfaces:**
- Consumes: `WindowSnapshotReader` (Task 2), `MemoryStore` (Task 3), `BrowserURL.domain(of:)`/`domain(_:matches:)` (Task 1).
- Produces: `@MainActor final class MemoryCapture { var store: MemoryStore?; var isSuppressed: () -> Bool; var captureIntervalSeconds: TimeInterval; var retentionDays: Int; var excludedDomains: [String]; func start(); func stop() }`. Consumed by Task 5 (`AppState`).

Only the domain-exclusion decision is pure/unit-testable — the Timer wiring and real AX capture are covered by live verification in Task 7, matching `MeetingWatcher`'s own split (its `nextState` is tested, its `Timer`/`tick()` wiring isn't).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import OmWhisper

@Suite("MemoryCapture domain exclusion")
struct MemoryCaptureExclusionTests {
    @Test("a snapshot with no url is never domain-excluded")
    func noURLNeverExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: nil, excludedDomains: ["example.com"]) == false)
    }

    @Test("an excluded domain is excluded")
    func excludedDomainExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://example.com/page", excludedDomains: ["example.com"]) == true)
    }

    @Test("a subdomain of an excluded domain is excluded")
    func subdomainExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://mail.example.com/inbox", excludedDomains: ["example.com"]) == true)
    }

    @Test("an unrelated domain is not excluded")
    func unrelatedNotExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://other.com/page", excludedDomains: ["example.com"]) == false)
    }

    @Test("an empty exclusion list excludes nothing")
    func emptyListExcludesNothing() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://example.com/page", excludedDomains: []) == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/MemoryCaptureExclusionTests 2>&1 | tail -30`
Expected: FAIL — `MemoryCapture` doesn't exist yet.

- [ ] **Step 3: Implement `MemoryCapture.swift`**

```swift
//
//  MemoryCapture.swift
//  OmWhisper
//
//  Timer-driven background capture daemon, modeled directly on
//  MeetingWatcher's poll pattern (Timer.scheduledTimer, isSuppressed
//  closure, start()/stop() shape) -- NOT smriti's SIGUSR1 signal handler,
//  which is a workaround for smriti running as a separate launchd CLI
//  daemon with no other IPC channel. This app is a normal in-process
//  menu-bar app; pause is just a settings-backed flag isSuppressed reads.
//
//  Exclusions are checked before any write is attempted: bundle ID and
//  title exclusion happen inside WindowSnapshotReader.captureFrontmost()
//  (reusing ScreenContextReader.isExcluded), domain exclusion happens here
//  in tick() before store.upsert(...) is ever called.
//
//  @MainActor: a lightweight poll, not a real-time audio path -- matches
//  MeetingWatcher's isolation, not AudioCapture's nonisolated+lock pattern.
//

import Foundation
import os

private let memoryLog = Logger(subsystem: "com.omwhisper.mac", category: "MemoryCapture")

@MainActor
final class MemoryCapture {
    static let maxContentLength = 20_000
    private static let pruneInterval: TimeInterval = 86_400

    var store: MemoryStore?
    var isSuppressed: () -> Bool = { false }
    var captureIntervalSeconds: TimeInterval = 5
    var retentionDays: Int = 90
    var excludedDomains: [String] = []

    private var pollTimer: Timer?
    private var pruneTimer: Timer?

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: captureIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneNow() }
        }
        pruneNow()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    /// Pure: true when `url`'s domain matches (exactly or as a subdomain of)
    /// any entry in `excludedDomains`. A snapshot with no url is never
    /// domain-excluded -- non-browser apps have no url to check at all.
    nonisolated static func isDomainExcluded(url: String?, excludedDomains: [String]) -> Bool {
        guard let url, let domain = BrowserURL.domain(of: url) else { return false }
        return excludedDomains.contains { BrowserURL.domain(domain, matches: $0) }
    }

    private func tick() {
        guard !isSuppressed(), let store else { return }
        guard let snapshot = WindowSnapshotReader.captureFrontmost() else { return }
        guard !Self.isDomainExcluded(url: snapshot.url, excludedDomains: excludedDomains) else { return }

        let content = String(snapshot.content.prefix(Self.maxContentLength))
        do {
            try store.upsert(
                appName: snapshot.appName, bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle,
                content: content, url: snapshot.url ?? ""
            )
        } catch {
            memoryLog.error("tick — upsert failed: \(error)")
        }
    }

    private func pruneNow() {
        guard let store else { return }
        do {
            try store.prune(olderThanDays: retentionDays)
        } catch {
            memoryLog.error("pruneNow — failed: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/MemoryCaptureExclusionTests 2>&1 | tail -30`
Expected: PASS, 5/5.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/MemoryCapture.swift omwhisper-nativeTests/MemoryCaptureExclusionTests.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(memory): add MemoryCapture (Timer-driven daemon)" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 5: `AppState` wiring + `MemorySettingsView`

**Files:**
- Create: `omwhisper-native/UI/MemorySettingsView.swift`
- Modify: `omwhisper-native/AppState.swift`
- Modify: `omwhisper-native/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `MemoryCapture` (Task 4), `MemoryStore` (Task 3), existing `AppState.SettingsKeys`/`access(keyPath:)` pattern.
- Produces: `AppState.memoryEnabled: Bool`, `AppState.memoryPaused: Bool`, `AppState.memoryRetentionDays: Int`, `AppState.memoryStore: MemoryStore?`, wired into a new Settings tab.

Before writing, read `AppState.swift` around the `historyStore` open pattern (the exact Application Support directory construction) and the `meetingsEnabled`/`replyAssistEnabled` setter pattern once, to match both exactly.

- [ ] **Step 1: Implement `MemorySettingsView.swift`**

```swift
//
//  MemorySettingsView.swift
//  OmWhisper
//
//  No search/browse UI here -- that's S5's job entirely. Just the toggle,
//  pause, and retention controls this sub-project's scope covers.
//

import SwiftUI

struct MemorySettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Toggle("Remember what's on screen", isOn: $state.memoryEnabled)
            if state.memoryEnabled {
                Toggle("Pause capture", isOn: $state.memoryPaused)
                Stepper("Keep for \(state.memoryRetentionDays) days", value: $state.memoryRetentionDays, in: 1...365)
            }
            Text("Periodically captures the frontmost window's visible text into a private, local, searchable memory — never leaves this Mac, off by default. Password managers and private/incognito browsing are always excluded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    MemorySettingsView().environment(AppState())
}
```

- [ ] **Step 2: Add the tab to `SettingsView.swift`**

Add between the "Reply Assist" and "About" tabs:

```swift
Tab("Memory", systemImage: "brain") {
    MemorySettingsView()
}
```

- [ ] **Step 3: Wire `AppState`**

Add near the other collaborators (alongside `replyAssistMonitor`):

```swift
@ObservationIgnored private let memoryCapture = MemoryCapture()
```

Add near `historyStore`'s declaration:

```swift
private(set) var memoryStore: MemoryStore?
```

Add to `SettingsKeys`:

```swift
static let memoryEnabled = "memoryEnabled"
static let memoryPaused = "memoryPaused"
static let memoryRetentionDays = "memoryRetentionDays"
```

Add the settings (mirrors `meetingsEnabled`/`replyAssistEnabled`; `memoryPaused`/`memoryRetentionDays` are plain settings read by `memoryCapture` each tick, not collaborator-wiring settings of their own):

```swift
var memoryEnabled: Bool {
    get {
        access(keyPath: \.memoryEnabled)
        return UserDefaults.standard.object(forKey: SettingsKeys.memoryEnabled) as? Bool ?? false
    }
    set {
        withMutation(keyPath: \.memoryEnabled) {
            UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryEnabled)
        }
        if newValue {
            memoryCapture.store = memoryStore
            memoryCapture.isSuppressed = { [weak self] in self?.memoryPaused ?? false }
            memoryCapture.captureIntervalSeconds = 5
            memoryCapture.retentionDays = memoryRetentionDays
            memoryCapture.start()
        } else {
            memoryCapture.stop()
        }
    }
}

var memoryPaused: Bool {
    get {
        access(keyPath: \.memoryPaused)
        return UserDefaults.standard.object(forKey: SettingsKeys.memoryPaused) as? Bool ?? false
    }
    set {
        withMutation(keyPath: \.memoryPaused) {
            UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryPaused)
        }
    }
}

var memoryRetentionDays: Int {
    get {
        access(keyPath: \.memoryRetentionDays)
        let value = UserDefaults.standard.object(forKey: SettingsKeys.memoryRetentionDays) as? Int
        return value ?? 90
    }
    set {
        withMutation(keyPath: \.memoryRetentionDays) {
            UserDefaults.standard.set(newValue, forKey: SettingsKeys.memoryRetentionDays)
        }
        memoryCapture.retentionDays = newValue
    }
}
```

Open the store in `init()`, right after `historyStore` is opened (same directory `dir` already constructed there — reuse it, don't re-derive the Application Support path):

```swift
do {
    memoryStore = try .open(atPath: dir.appendingPathComponent("memory.db").path)
} catch {
    log.error("init — MemoryStore open failed: \(error)")
}
```

Add to `init()`, alongside the existing re-arm lines:

```swift
if memoryEnabled { memoryEnabled = true }  // re-runs the setter's wiring/start path
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: all passing (137 — 132 running total after Task 3 + Task 4's 5, unchanged by this task).

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/UI/MemorySettingsView.swift omwhisper-native/AppState.swift omwhisper-native/UI/SettingsView.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(memory): wire MemoryCapture + MemoryStore + Settings tab" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 6: Debug self-test

**Files:**
- Create: `omwhisper-native/Memory/MemorySelfTest.swift`
- Modify: `omwhisper-native/OmWhisperApp.swift`

**Interfaces:**
- Consumes: `WindowSnapshotReader`, `MemoryStore` (both real, not mocked — this is a live diagnostic, matching `MeetingSelfTest`'s own approach).
- Produces: a `#if DEBUG` menu item that captures the current frontmost window, writes it, searches for a substring of its own content, and reports pass/fail.

No unit test — this file only exists under `#if DEBUG` and is itself a diagnostic tool, matching `MeetingSelfTest`.

- [ ] **Step 1: Implement `MemorySelfTest.swift`**

```swift
//
//  MemorySelfTest.swift
//  OmWhisper
//
//  Debug-only diagnostic: captures the current frontmost window, writes it
//  to a throwaway in-memory store, and confirms FTS5 search actually finds
//  it back -- covers the "FTS search works" exit criterion without
//  requiring a full day of live capture to observe it.
//

#if DEBUG
import Foundation
import GRDB

enum MemorySelfTest {
    static func run() -> String {
        guard let snapshot = WindowSnapshotReader.captureFrontmost() else {
            return "FAILED: no frontmost window captured (excluded app, or nothing on screen)"
        }
        guard let store = try? MemoryStore(DatabaseQueue()) else {
            return "FAILED: could not open an in-memory MemoryStore"
        }
        do {
            try store.upsert(
                appName: snapshot.appName, bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle,
                content: snapshot.content, url: snapshot.url ?? ""
            )
        } catch {
            return "FAILED: upsert threw \(error)"
        }
        let probe = snapshot.content.split(separator: " ").first(where: { $0.count > 3 }).map(String.init) ?? snapshot.content
        guard let results = try? store.search(probe, limit: 5), !results.isEmpty else {
            return "FAILED: search(\"\(probe)\") found nothing after a successful upsert"
        }
        return """
            OK ✓
            app=\(snapshot.appName) bundleID=\(snapshot.bundleID) url=\(snapshot.url ?? "(none)")
            content length=\(snapshot.content.count)
            search probe="\(probe)" found \(results.count) result(s)
            """
    }
}
#endif
```

- [ ] **Step 2: Add the debug menu item to `OmWhisperApp.swift`**

Add alongside the existing `#if DEBUG` "Meeting Self-Test…" menu item:

```swift
#if DEBUG
addItem(to: menu, title: "Memory Self-Test…", action: #selector(runMemorySelfTest))
#endif
```

```swift
#if DEBUG
@objc private func runMemorySelfTest() {
    let report = MemorySelfTest.run()
    let alert = NSAlert()
    alert.messageText = "Memory Self-Test"
    alert.informativeText = report
    alert.runModal()
}
#endif
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: all passing (137, unchanged — this task adds no tests, `#if DEBUG` code doesn't compile into the test target's release path but does build under Debug, matching `MeetingSelfTest`).

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Memory/MemorySelfTest.swift omwhisper-native/OmWhisperApp.swift
git commit -m "$(printf '%s\n\n%s' "✨ feat(memory): add debug self-test diagnostic" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```

---

### Task 7: Live verification + docs

**Files:**
- Modify: `CLAUDE.md` (Progress Tracker)

No new code — this task is entirely live verification and documentation, matching S2/S3/S4's Task 7.

- [ ] **Step 1: Build and launch**

```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```
Launch the built app (find the freshest `OmWhisper.app` across DerivedData by mtime — multiple stale DerivedData dirs can exist, don't assume `find | head -1` picks the right one).

- [ ] **Step 2: Enable and run the self-test**

Settings → Memory → toggle on. Bring a real text-bearing window to front (Notes, a browser tab, Mail). Run "Memory Self-Test…" from the debug menu — confirm it reports `OK ✓` with a plausible `appName`/`content length`/search result, not a `FAILED` line.

- [ ] **Step 3: Verify real background capture and dedup**

Leave a text-heavy window frontmost for at least 15 seconds (3 capture ticks at the 5s default). Run the self-test again with a different probe word from the same window's content — confirm it still finds a result (proves the daemon itself, not just the self-test's own one-shot write, is populating the store). If you have a way to inspect `~/Library/Application Support/com.omwhisper.mac/memory.db` directly (e.g. `sqlite3` CLI, `SELECT COUNT(*), appName FROM snapshots GROUP BY appName`), confirm the row count for that app is small (1-2), not one row per tick — this is the dedup upsert actually collapsing an unchanged window into one row rather than growing unbounded.

- [ ] **Step 4: Verify exclusions**

Bring a password manager (or any app in `ScreenContextReader.excludedBundleIDs`) to front, or open a Private Browsing window, and leave it frontmost for 15+ seconds. Query `memory.db` directly (or note the row count before/after) and confirm no new row was written for that app/window — the exclusion must hold at the daemon level, not just in the self-test's manual capture.

- [ ] **Step 5: Verify pause and disable**

Toggle "Pause capture" on with Memory otherwise enabled — bring a new window to front, wait 15+ seconds, confirm no new capture happened (via the self-test or a direct DB row count), then unpause and confirm capture resumes. Toggle Memory off entirely and confirm the same — plus that re-enabling it later restores capture (exercising the `init()` re-arm line), matching the established pattern from `meetingsEnabled`/`replyAssistEnabled`.

- [ ] **Step 6: Update `CLAUDE.md`**

Update the S1–S6 Progress Tracker row: mark S1 shipped, describe what was built (mirroring the level of detail in the S2/S3/S4 entries — architecture ported from smriti with the deliberate deviations: GRDB over raw SQLite3, settings-flag pause over `SIGUSR1`, separate database from `HistoryStore`), note real bugs found during Steps 2-5 and how they were fixed, and record the live-verification results (self-test output, dedup row-count confirmation, exclusion confirmation).

```bash
git add CLAUDE.md
git commit -m "$(printf '%s\n\n%s' "📝 docs: mark S1 (memory core) shipped" "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>")"
```
