# S3 Sub-project 2 — Meeting Transcription, Summary & UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn S3-1's dual-track meeting recordings (`me.caf` + `them.caf`) into on-device
transcribed, summarized, browsable meetings — a `MeetingStore`, a file transcriber, a map-reduce
summarizer, and a Meetings hub section with a per-meeting "Transcribe & Summarize" button.

**Architecture:** A row is inserted into a new `meetings.db` when recording stops. The user opens
a meeting and taps a button; `AppState.transcribeMeeting(id:)` transcribes both tracks via a
fresh `AppleEngine` (local), summarizes via `SystemLLM` (local), and stores the result. All
strictly on-device regardless of the user's dictation/polish backend.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), GRDB, `AVAudioFile`, the existing
`TranscriptionEngine`/`AppleEngine`, `PolishBackend`/`SystemLLM`, `AppSupportDirectory`,
Porcelain UI components.

**Spec:** `docs/superpowers/specs/2026-07-11-s3-2-meeting-transcription-summary-ui-design.md`.

## Global Constraints

- **On-device only**: meeting transcription uses `AppleEngine()`; summary uses `systemLLM`.
  Never Cloud/Ollama/Parakeet. (Recorded calls never egress — the S3-2 privacy decision.)
- **`nonisolated`** on every new type/free function (`Meeting`, `MeetingStore`,
  `MeetingTranscriber`, `MeetingSummarizer`) — the MainActor-by-default project setting otherwise
  pins them and breaks the off-MainActor GRDB/engine paths and the pure-function tests.
- **`@preconcurrency import AVFoundation`** in `MeetingTranscriber` — `AVAudioPCMBuffer` crosses
  the `AsyncStream`/`Task` boundary, same as `AudioCapture`/`AppleEngine`.
- **Separate `meetings.db`** (own `DatabaseQueue`), opened independently in `AppState.init()` —
  one store failing to open must not affect the others.
- **Fail-safe**: transcription failure surfaces an error but never crashes; summary failure
  (`try?`) still stores the transcript; no key/model → transcript-only.
- **UI uses `Color.Porcelain.*`, `PorcelainSection`/`omRowCard`, real `Button` rows** (D4a a11y).
- Run `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test` after
  every task; must end `** TEST SUCCEEDED **`. Baseline **251**; count grows as tasks add tests.

---

### Task 1: `MeetingStore` (GRDB, `meetings.db`)

**Files:**
- Create: `omwhisper-native/Meetings/MeetingStore.swift`
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `Meeting` record; `MeetingStore` with `open(atPath:)`, `insert(_:) -> Int64`,
  `get(id:) -> Meeting?`, `setTranscriptAndSummary(id:transcript:summary:)`,
  `fetchPage(offset:limit:) -> [Meeting]`, `search(_:limit:) -> [Meeting]`, `delete(id:)`,
  `deleteAll()`, `count() -> Int`, `MeetingStoreError.notFound`.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/MeetingStoreTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import OmWhisper

@Suite("MeetingStore", .serialized)
struct MeetingStoreTests {
    private func makeStore() throws -> MeetingStore { try MeetingStore(DatabaseQueue()) }

    private func seed(_ store: MeetingStore, app: String, dir: String = "/tmp/omw-test-\(UUID().uuidString)") throws -> Int64 {
        try store.insert(Meeting(
            id: nil, startedAt: ISO8601DateFormatter().string(from: Date()),
            appName: app, directory: dir, durationSeconds: 90,
            transcript: nil, summary: nil, createdAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    @Test func insertGetAndCount() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Zoom")
        let got = try store.get(id: id)
        #expect(got?.appName == "Zoom")
        #expect(got?.transcript == nil)
        #expect(try store.count() == 1)
    }

    @Test func setTranscriptAndSummary() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Meet")
        try store.setTranscriptAndSummary(id: id, transcript: "**You:**\nhi", summary: "## Summary\nshort")
        let got = try store.get(id: id)
        #expect(got?.transcript == "**You:**\nhi")
        #expect(got?.summary == "## Summary\nshort")
    }

    @Test func fetchPageNewestFirst() throws {
        let store = try makeStore()
        _ = try seed(store, app: "First")
        _ = try seed(store, app: "Second")
        _ = try seed(store, app: "Third")
        let page = try store.fetchPage(offset: 0, limit: 10)
        #expect(page.count == 3)
        #expect(page.first?.appName == "Third")   // newest (highest id) first
    }

    @Test func searchMatchesTranscriptAndApp() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Webex")
        try store.setTranscriptAndSummary(id: id, transcript: "we discussed the quarterly roadmap", summary: nil)
        #expect(try store.search("roadmap", limit: 10).count == 1)
        #expect(try store.search("Webex", limit: 10).count == 1)
        #expect(try store.search("unrelated", limit: 10).isEmpty)
    }

    @Test func deleteRemovesRowAndDirectory() throws {
        let store = try makeStore()
        let dir = NSTemporaryDirectory() + "omw-meeting-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = try store.insert(Meeting(
            id: nil, startedAt: "s", appName: "App", directory: dir, durationSeconds: 1,
            transcript: nil, summary: nil, createdAt: "c"
        ))
        try store.delete(id: id)
        #expect(try store.get(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func deleteAllClearsRows() throws {
        let store = try makeStore()
        _ = try seed(store, app: "A")
        _ = try seed(store, app: "B")
        try store.deleteAll()
        #expect(try store.count() == 0)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'MeetingStore'`)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|cannot find 'MeetingStore'"`
Expected: `cannot find 'MeetingStore' in scope`.

- [ ] **Step 3: Implement `MeetingStore.swift`**

Create `omwhisper-native/Meetings/MeetingStore.swift`:

```swift
//
//  MeetingStore.swift
//  OmWhisper
//
//  Separate GRDB database (meetings.db) for recorded-meeting metadata + on-device
//  transcript/summary. Distinct from history.db/memory.db -- recorded calls are
//  their own sensitivity class, wiped independently. Mirrors MemoryStore's shape
//  (DatabaseQueue, DatabaseMigrator, FTS5 via synchronize(withTable:)).
//
//  nonisolated: GRDB I/O has no MainActor affinity, matching MemoryStore.
//

import Foundation
import GRDB

nonisolated struct Meeting: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "meetings"
    var id: Int64?
    var startedAt: String
    var appName: String
    var directory: String
    var durationSeconds: Double
    var transcript: String?
    var summary: String?
    var createdAt: String

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

nonisolated enum MeetingStoreError: Error, LocalizedError {
    case notFound
    var errorDescription: String? { "That meeting could not be found." }
}

nonisolated final class MeetingStore: Sendable {
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createMeetings") { db in
            try db.create(table: Meeting.databaseTableName) { t in
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
                t.synchronize(withTable: Meeting.databaseTableName)
                t.column("transcript")
                t.column("summary")
                t.column("appName")
            }
        }
        try migrator.migrate(dbQueue)
    }

    static func open(atPath path: String) throws -> MeetingStore {
        try MeetingStore(DatabaseQueue(path: path))
    }

    func insert(_ meeting: Meeting) throws -> Int64 {
        try dbQueue.write { db in
            var m = meeting
            try m.insert(db)
            return m.id ?? 0
        }
    }

    func get(id: Int64) throws -> Meeting? {
        try dbQueue.read { db in try Meeting.fetchOne(db, key: id) }
    }

    func setTranscriptAndSummary(id: Int64, transcript: String?, summary: String?) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.transcript = transcript
            m.summary = summary
            try m.update(db)
        }
    }

    /// Newest first; `id` tiebreaker for same-second inserts (ISO8601 whole-second
    /// precision), matching MemoryStore's fetchPage ordering fix.
    func fetchPage(offset: Int, limit: Int) throws -> [Meeting] {
        try dbQueue.read { db in
            try Meeting
                .order(Column("startedAt").desc, Column("id").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func search(_ query: String, limit: Int = 50) throws -> [Meeting] {
        let terms = query.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " OR ")
        guard !terms.isEmpty else { return [] }
        return try dbQueue.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT meetings.* FROM meetings
                JOIN meetings_fts ON meetings_fts.rowid = meetings.id
                WHERE meetings_fts MATCH ?
                ORDER BY meetings.startedAt DESC, meetings.id DESC
                LIMIT ?
                """, arguments: [terms, limit])
        }
    }

    func delete(id: Int64) throws {
        let directory = try dbQueue.read { db in try Meeting.fetchOne(db, key: id)?.directory }
        _ = try dbQueue.write { db in try Meeting.deleteOne(db, key: id) }
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
    }

    func deleteAll() throws {
        let directories = try dbQueue.read { db in try Meeting.fetchAll(db).map(\.directory) }
        _ = try dbQueue.write { db in try Meeting.deleteAll(db) }
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
    }

    func count() throws -> Int {
        try dbQueue.read { db in try Meeting.fetchCount(db) }
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 257 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "feat(meetings): MeetingStore (meetings.db, GRDB + FTS)"
```

---

### Task 2: `MeetingTranscriber` (file → dual-track transcript)

**Files:**
- Create: `omwhisper-native/Meetings/MeetingTranscriber.swift`
- Test: `omwhisper-nativeTests/MeetingTranscriberTests.swift`

**Interfaces:**
- Consumes: `TranscriptionEngine`/`AppleEngine`, `TranscriptEvent`.
- Produces: `MeetingTranscriber.labeledTranscript(you:others:)`,
  `.transcribeMeeting(directory:engine:)`, `.audioDuration(_:)`.

- [ ] **Step 1: Write the failing test (pure `labeledTranscript` only)**

Create `omwhisper-nativeTests/MeetingTranscriberTests.swift`:

```swift
import Testing
@testable import OmWhisper

struct MeetingTranscriberTests {
    @Test func labelsBothTracks() {
        let out = MeetingTranscriber.labeledTranscript(you: "hello", others: "hi there")
        #expect(out == "**You:**\nhello\n\n**Others:**\nhi there")
    }

    @Test func omitsEmptyTrack() {
        #expect(MeetingTranscriber.labeledTranscript(you: "hello", others: "  ") == "**You:**\nhello")
        #expect(MeetingTranscriber.labeledTranscript(you: "", others: "hi") == "**Others:**\nhi")
    }

    @Test func bothEmptyGivesEmpty() {
        #expect(MeetingTranscriber.labeledTranscript(you: " ", others: "") == "")
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'MeetingTranscriber'`)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|cannot find 'MeetingTranscriber'"`
Expected: `cannot find 'MeetingTranscriber' in scope`.

- [ ] **Step 3: Implement `MeetingTranscriber.swift`**

Create `omwhisper-native/Meetings/MeetingTranscriber.swift`:

```swift
//
//  MeetingTranscriber.swift
//  OmWhisper
//
//  Transcribes a recorded meeting's two tracks (me.caf = mic = "You",
//  them.caf = system audio = "Others") by reading each file into buffers and
//  feeding them through a TranscriptionEngine -- the same AsyncStream<AVAudioPCMBuffer>
//  contract AudioCapture uses for live dictation. On-device only (AppState passes
//  a fresh AppleEngine). Labeling is pure/tested; the file->engine drive is
//  verified live.
//
//  @preconcurrency: AVAudioPCMBuffer/AVAudioFile aren't Sendable and cross the
//  AsyncStream/Task boundary, matching AudioCapture/AppleEngine.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated enum MeetingTranscriber {
    /// Pure: markdown transcript with speaker labels; a track that's empty/whitespace
    /// is omitted; both empty → "".
    static func labeledTranscript(you: String, others: String) -> String {
        let y = you.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = others.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !y.isEmpty { parts.append("**You:**\n\(y)") }
        if !o.isEmpty { parts.append("**Others:**\n\(o)") }
        return parts.joined(separator: "\n\n")
    }

    /// Transcribe me.caf (you) + them.caf (others) sequentially → labeled transcript.
    static func transcribeMeeting(directory: URL, engine: TranscriptionEngine) async throws -> String {
        let you = try await transcribeFile(directory.appendingPathComponent("me.caf"), engine: engine)
        let others = try await transcribeFile(directory.appendingPathComponent("them.caf"), engine: engine)
        return labeledTranscript(you: you, others: others)
    }

    /// Read the whole file in buffer chunks, feed the engine, join every .final.
    /// Missing/empty file → "".
    static func transcribeFile(_ url: URL, engine: TranscriptionEngine) async throws -> String {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return "" }
        let format = file.processingFormat
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let producer = Task {
            var remaining = file.length
            let chunkFrames: AVAudioFrameCount = 8192
            while remaining > 0 {
                let n = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n),
                      (try? file.read(into: buffer, frameCount: n)) != nil,
                      buffer.frameLength > 0 else { break }
                continuation.yield(buffer)
                remaining -= Int64(buffer.frameLength)
            }
            continuation.finish()
        }

        var finals: [String] = []
        do {
            for try await event in engine.transcribe(stream, vocabulary: []) {
                if case .final(let text) = event {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { finals.append(trimmed) }
                }
            }
        } catch {
            producer.cancel()
            throw error
        }
        producer.cancel()
        return finals.joined(separator: " ")
    }

    /// Meeting length in seconds, read from the mic track. 0 if unreadable.
    static func audioDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 260 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingTranscriber.swift omwhisper-nativeTests/MeetingTranscriberTests.swift
git commit -m "feat(meetings): MeetingTranscriber (dual-track file → labeled transcript)"
```

---

### Task 3: `MeetingSummarizer` (map-reduce via PolishBackend)

**Files:**
- Create: `omwhisper-native/Meetings/MeetingSummarizer.swift`
- Test: `omwhisper-nativeTests/MeetingSummarizerTests.swift`

**Interfaces:**
- Consumes: `PolishBackend`, `PolishStyle`.
- Produces: `MeetingSummarizer.chunk(_:limit:)`, `.generate(transcript:polish:)`.

- [ ] **Step 1: Write the failing test (pure `chunk` only)**

Create `omwhisper-nativeTests/MeetingSummarizerTests.swift`:

```swift
import Testing
@testable import OmWhisper

struct MeetingSummarizerTests {
    @Test func shortTextIsOneChunk() {
        #expect(MeetingSummarizer.chunk("hello world", limit: 100) == ["hello world"])
    }

    @Test func packsWordsUnderLimitWithoutLosingContent() {
        let text = Array(repeating: "word", count: 50).joined(separator: " ")  // 50 words
        let chunks = MeetingSummarizer.chunk(text, limit: 40)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 40 })
        let rejoinedWordCount = chunks.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).count
        #expect(rejoinedWordCount == 50)
    }

    @Test func emptyGivesNoChunks() {
        #expect(MeetingSummarizer.chunk("   ", limit: 100).isEmpty)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'MeetingSummarizer'`)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|cannot find 'MeetingSummarizer'"`
Expected: `cannot find 'MeetingSummarizer' in scope`.

- [ ] **Step 3: Implement `MeetingSummarizer.swift`**

Create `omwhisper-native/Meetings/MeetingSummarizer.swift`:

```swift
//
//  MeetingSummarizer.swift
//  OmWhisper
//
//  Map-reduce meeting summary through a PolishBackend, mirroring Chronicler's
//  approach for the same reason: SystemLLM's polish() has a ~2,000-char/5s
//  envelope, and a meeting transcript regularly exceeds that. Words are greedily
//  packed into <=chunkCharLimit groups (no content lost even for one long line),
//  each summarized (map), then one reduce call writes the final markdown summary
//  + action items. AppState always passes systemLLM (on-device). The two styles
//  are fixed-UUID and internal -- never added to PolishStyles.builtIns, same
//  hidden-style pattern as Chronicler.
//

import Foundation

nonisolated enum MeetingSummarizer {
    static let chunkCharLimit = 1_800
    static let reduceCharLimit = 1_800

    static let chunkSummaryStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000001")!,
        name: "Meeting Chunk Summary",
        prompt: """
            Summarize this portion of a meeting transcript into 2-5 terse bullet \
            points of what was said/decided. The transcript labels speakers as \
            **You:** and **Others:** — preserve who said what. No preamble, just bullets.
            """,
        isBuiltIn: true
    )

    static let meetingWriteStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000002")!,
        name: "Meeting Summary",
        prompt: """
            You are writing a private summary of a meeting from bullet-point notes \
            (speakers labeled You/Others). Write concise markdown with:
            ## Summary — 2-4 sentences on what the meeting was about and any decisions.
            ## Action items — a bullet list of concrete follow-ups (who owns each, if \
            clear). Omit this section entirely if there were none.
            Rules: be specific, no filler, no speculation beyond the notes.
            """,
        isBuiltIn: true
    )

    /// Pure: greedily pack words into <=limit-char groups so no content is lost
    /// even for a single long line. A single word longer than limit forms its
    /// own (oversized) group rather than being split.
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

    /// Effectful: map each chunk → chunk-summary, reduce → markdown summary.
    /// Returns "" for an empty transcript. Propagates the first polish() failure.
    static func generate(transcript: String, polish: PolishBackend) async throws -> String {
        let chunks = chunk(transcript)
        guard !chunks.isEmpty else { return "" }

        var chunkSummaries: [String] = []
        for group in chunks {
            let summary = try await polish.polish(group, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(reduceCharLimit))
        let out = try await polish.polish(reduceInput, style: meetingWriteStyle, targetLanguage: nil)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 263 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingSummarizer.swift omwhisper-nativeTests/MeetingSummarizerTests.swift
git commit -m "feat(meetings): MeetingSummarizer (map-reduce summary + action items)"
```

---

### Task 4: Wire `MeetingStore` + `transcribeMeeting` into `AppState`

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `MeetingStore` (Task 1), `MeetingTranscriber` (Task 2), `MeetingSummarizer` (Task 3),
  `AppleEngine`, `SystemLLM`.
- Produces: `AppState.meetingStore`, `AppState.transcribeMeeting(id:)`.

- [ ] **Step 1: Add the store property + start-time capture**

Near `private(set) var memoryStore: MemoryStore?`, add:
```swift
    private(set) var meetingStore: MeetingStore?
```
Near the `@ObservationIgnored private let meeting*` declarations, add:
```swift
    @ObservationIgnored private var meetingStartedAt: Date?
    @ObservationIgnored private var meetingAppName: String?
```

- [ ] **Step 2: Open the store in `init()`**

In the test-guard block, add `meetingStore = nil` alongside `memoryStore = nil`. After the
MemoryStore open block, add:
```swift
        // Separate database from history/memory -- recorded meetings are their own
        // sensitivity class, wiped independently. Opened independently.
        do {
            guard let appSupportDir else { throw CocoaError(.fileNoSuchFile) }
            meetingStore = try .open(atPath: appSupportDir.appendingPathComponent("meetings.db").path)
        } catch {
            log.error("init — MeetingStore failed to open: \(error)")
            meetingStore = nil
        }
```

- [ ] **Step 3: Capture start metadata + insert a row on stop**

In the `meetingsEnabled` setter, extend `onStartRecording` (record the start metadata after a
successful start) and `onStopRecording` (insert the row after stop):
```swift
                meetingWatcher.onStartRecording = { [weak self] appName in
                    Task {
                        do {
                            try self?.meetingRecorder.start(appName: appName)
                            self?.meetingStartedAt = Date()
                            self?.meetingAppName = appName
                        } catch {
                            log.error("meeting recording failed to start: \(error)")
                            self?.meetingWatcher.failedToStartRecording()
                        }
                    }
                }
                meetingWatcher.onStopRecording = { [weak self] in
                    Task {
                        await self?.meetingRecorder.stop()
                        self?.recordFinishedMeeting()
                    }
                }
```

- [ ] **Step 4: Add `recordFinishedMeeting()` + `transcribeMeeting(id:)`**

Add these methods to `AppState` (near the other meeting/polish code):
```swift
    /// Called after meetingRecorder.stop() flushes me.caf/them.caf: insert a
    /// "Recorded" row so the meeting shows immediately (transcript/summary filled
    /// on demand by transcribeMeeting).
    private func recordFinishedMeeting() {
        guard let store = meetingStore, let dir = meetingRecorder.meetingDirectory else { return }
        let iso = ISO8601DateFormatter()
        let duration = MeetingTranscriber.audioDuration(dir.appendingPathComponent("me.caf"))
        do {
            _ = try store.insert(Meeting(
                id: nil,
                startedAt: iso.string(from: meetingStartedAt ?? Date()),
                appName: meetingAppName ?? "Meeting",
                directory: dir.path,
                durationSeconds: duration,
                transcript: nil, summary: nil,
                createdAt: iso.string(from: Date())
            ))
        } catch {
            log.error("recordFinishedMeeting — insert failed: \(error)")
        }
        meetingStartedAt = nil
        meetingAppName = nil
    }

    /// The view's path: transcribe both tracks on-device (AppleEngine) and, if
    /// Apple Intelligence is on, summarize (SystemLLM) -- never Cloud/Ollama,
    /// regardless of the dictation/polish backend. Transcript is always saved;
    /// summary is best-effort. Returns the updated meeting.
    func transcribeMeeting(id: Int64) async throws -> Meeting {
        guard let store = meetingStore, let meeting = try store.get(id: id) else {
            throw MeetingStoreError.notFound
        }
        let transcript = try await MeetingTranscriber.transcribeMeeting(
            directory: URL(fileURLWithPath: meeting.directory), engine: AppleEngine()
        )
        var summary: String?
        if SystemLLM.isAvailable() {
            summary = try? await MeetingSummarizer.generate(transcript: transcript, polish: systemLLM)
        } else if !didNudgeFoundationModelsUnavailable {
            didNudgeFoundationModelsUnavailable = true
            errorMessage = "Apple Intelligence is off — enable it in Settings > AI to summarize meetings. Transcript saved without a summary."
        }
        try store.setTranscriptAndSummary(id: id, transcript: transcript, summary: summary)
        return try store.get(id: id) ?? meeting
    }
```

- [ ] **Step 5: Build + full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 263 tests.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "feat(meetings): wire MeetingStore + on-device transcribeMeeting into AppState"
```

---

### Task 5: Meetings hub section UI

**Files:**
- Create: `omwhisper-native/UI/HubMeetingsSectionView.swift`
- Modify: `omwhisper-native/UI/HubShellView.swift`
- Delete: `omwhisper-native/UI/MeetingsSettingsView.swift`

**Interfaces:**
- Consumes: `AppState.meetingStore`/`meetingsEnabled`/`transcribeMeeting(id:)`, `Meeting`,
  Porcelain components.

- [ ] **Step 1: Create `HubMeetingsSectionView.swift`**

```swift
//
//  HubMeetingsSectionView.swift
//  OmWhisper
//
//  The hub's Meetings section: the detect-and-record toggle over a browse UI
//  (searchable list + transcript/summary detail with a per-meeting
//  "Transcribe & Summarize" button). Replaces the toggle-only MeetingsSettingsView.
//  On-device transcription/summary via AppState.transcribeMeeting.
//

import SwiftUI

struct HubMeetingsSectionView: View {
    @Environment(AppState.self) private var appState

    @State private var meetings: [Meeting] = []
    @State private var selectedID: Int64?
    @State private var searchText = ""
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            settingsBar(state: state)
            Divider()
            if state.meetingsEnabled || !meetings.isEmpty {
                browser
            } else {
                disabledEmptyState
            }
        }
        .background(Color.Porcelain.bg)
        .task(id: searchText) { await reload() }
    }

    private func settingsBar(state: AppState) -> some View {
        HStack {
            Toggle("Detect and record meetings", isOn: Binding(
                get: { state.meetingsEnabled }, set: { state.meetingsEnabled = $0 }
            ))
            .tint(Color.Porcelain.emerald)
            .foregroundStyle(Color.Porcelain.ink)
            Spacer()
        }
        .padding(12)
    }

    private var browser: some View {
        NavigationSplitView {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(meetings) { meeting in
                        Button { selectedID = meeting.id } label: {
                            meetingRow(meeting)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(meeting.appName), \(shortDate(meeting.startedAt))")
                        .accessibilityAddTraits(selectedID == meeting.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(12)
            }
            .background(Color.Porcelain.bg)
            .searchable(text: $searchText, prompt: "Search meetings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.appName).fontWeight(.medium).foregroundStyle(Color.Porcelain.ink)
            Text("\(shortDate(meeting.startedAt)) · \(durationText(meeting.durationSeconds)) · \(status(meeting))")
                .font(.caption).foregroundStyle(Color.Porcelain.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .omRowCard()
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedID, let meeting = meetings.first(where: { $0.id == selectedID }) {
            MeetingDetailView(meeting: meeting, onChanged: { await reload() })
        } else {
            Text("Select a meeting")
                .foregroundStyle(Color.Porcelain.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.Porcelain.bg)
        }
    }

    private var disabledEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("👥").font(.system(size: 40))
            Text("Turn on meeting recording above. When a call app is active you'll be asked for consent, and recordings stay on this Mac.")
                .foregroundStyle(Color.Porcelain.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() async {
        guard let store = appState.meetingStore else { return }
        do {
            let trimmed = searchText.trimmingCharacters(in: .whitespaces)
            meetings = trimmed.isEmpty ? try store.fetchPage(offset: 0, limit: 100) : try store.search(trimmed, limit: 100)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func status(_ meeting: Meeting) -> String {
        if meeting.summary != nil { return "Summarized" }
        if meeting.transcript != nil { return "Transcribed" }
        return "Recorded"
    }

    private func shortDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    private func durationText(_ seconds: Double) -> String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}

private struct MeetingDetailView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    let onChanged: () async -> Void

    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(meeting.appName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)

                HStack(spacing: 10) {
                    Button(working ? "Working…" : (meeting.transcript == nil ? "Transcribe & Summarize" : "Re-transcribe")) {
                        run()
                    }
                    .disabled(working)
                    Button("Delete", role: .destructive) { delete() }.disabled(working)
                    if working { ProgressView().controlSize(.small) }
                }

                if let summary = meeting.summary, !summary.isEmpty {
                    section("Summary", markdown: summary)
                }
                if let transcript = meeting.transcript, !transcript.isEmpty {
                    section("Transcript", markdown: transcript)
                } else if !working {
                    Text("Not transcribed yet — tap Transcribe & Summarize.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.Porcelain.bg)
    }

    private func section(_ title: String, markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Color.Porcelain.dim)
            Text(.init(markdown)).textSelection(.enabled).foregroundStyle(Color.Porcelain.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .omCard()
    }

    private func run() {
        guard let id = meeting.id else { return }
        working = true
        errorMessage = nil
        Task {
            do { _ = try await appState.transcribeMeeting(id: id) }
            catch { errorMessage = error.localizedDescription }
            await onChanged()
            working = false
        }
    }

    private func delete() {
        guard let id = meeting.id, let store = appState.meetingStore else { return }
        try? store.delete(id: id)
        Task { await onChanged() }
    }
}
```

- [ ] **Step 2: Point the hub `.meetings` case at the new view**

In `HubShellView.swift`, change:
```swift
        case .meetings: MeetingsSettingsView()
```
to:
```swift
        case .meetings: HubMeetingsSectionView()
```

- [ ] **Step 3: Delete the now-unused `MeetingsSettingsView.swift`**

```bash
rm omwhisper-native/UI/MeetingsSettingsView.swift
```
(Its only reference was the hub case just repointed; its toggle is inlined in the new view's
settings bar.)

- [ ] **Step 4: Build + suite (UI verified live — no unit test, per convention)**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 263 tests.

- [ ] **Step 5: Commit**

```bash
git add -A omwhisper-native/UI/
git commit -m "feat(meetings): Meetings hub section (list + transcript/summary detail)"
```

---

### Task 6: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Flip the S1–S6 status cell and append an S3-2 note**

Status cell → note S3 sub-project 2 shipped (S3 now complete: `S1 + S2 + S3 + S4 + S5.1 + S5.2
shipped, S6 not started`). Append a note summarizing: `Meetings/MeetingStore.swift` (separate
`meetings.db`, GRDB + FTS, mirrors MemoryStore); `Meetings/MeetingTranscriber.swift` (me.caf/
them.caf → buffers → `AppleEngine` → **You:**/**Others:** labeled transcript, pure
`labeledTranscript` tested); `Meetings/MeetingSummarizer.swift` (word-packed map-reduce via
`SystemLLM`, summary + action items, mirrors Chronicler with its own hidden fixed-UUID styles);
`AppState` inserts a "Recorded" row on `onStopRecording` and exposes `transcribeMeeting(id:)`
(the manual-button path, **strictly on-device — AppleEngine + SystemLLM regardless of the
dictation/polish backend**, transcript always saved, summary best-effort); `UI/HubMeetingsSectionView.swift`
(toggle bar + searchable list + transcript/summary detail with the Transcribe & Summarize
button) replacing the toggle-only `MeetingsSettingsView` (deleted). Decisions: manual trigger
(no background queue), one pass, dual-track labeled (no turn interleaving — engine exposes no
per-segment timestamps). Tests added (MeetingStore round-trips, `labeledTranscript`, `chunk`),
count 263. **Live verification owed** (the real risk): feeding a recorded `.caf` through the
streaming `AppleEngine` is the one unproven path — record a real call, tap Transcribe, confirm a
plausible labeled transcript + sensible summary; and that a meeting with Foundation Models off
still stores a transcript. Note S3-1's still-deferred real-call consent-flow test also folds in
here (a real recorded call now exercises the whole S3 chain).

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: S3-2 meeting transcription/summary/UI shipped — S3 complete"
```
