# Design: S5.1 — Chronicles + Search/Today/Timeline UI

> Written 2026-07-09. Brainstormed via `superpowers:brainstorming`. First of two
> sub-projects implementing "S5 — Memory surfacing + MCP" from
> `docs/SMRITI_INTEGRATION_PLAN.md`, next in the project's priority order after
> S1 (memory core) shipped. S5 was split in two during brainstorming: this
> sub-project (chronicles + in-app browse/search UI) ships first; S5.2 (MCP
> server for Claude Desktop) follows on top of the chronicle store this adds.
> In-app "Memory Chat" (smriti's agentic `claude` CLI + MCP loop) was
> descoped entirely — the MCP server alone already satisfies S5's exit
> criterion ("what was I working on before lunch?" answerable from Claude
> Desktop), and this app has no `PolishBackend` capable of true multi-turn
> tool-calling today.

## Goal

Two things, both built on S1's `memory.db`/`MemoryStore`:

1. **Chronicles** — once a day, roll yesterday's captured snapshots into a
   written markdown summary, stored per-day, survives snapshot pruning.
2. **Browse/search UI** — a new "Memory" window: search across captured
   snapshots (empty search = recent activity), and a Chronicles tab to read
   past daily summaries.

No new Settings toggle — both are implicit under the existing `memoryEnabled`
flag (S1), matching how `memoryPaused`/`memoryRetentionDays` already inherit
it rather than getting their own master switch.

## Reference: smriti's implementation

Investigated directly from `/Users/rakeshkusuma/Documents/PersonalProjects/smriti`
(same author, MIT, read-only reference) — `Chronicler.swift`, `Store.swift`
(chronicles section), `ChronicleTimelineSection.swift`:

- **`Chronicler.swift`** (91 lines) — builds one plain-text digest of a whole
  day's snapshots (per-snapshot content clipped to 700 chars, digest capped
  at 120,000 chars total), pipes it through `claude -p` (the Claude Code CLI,
  on the user's own subscription) with a fixed prompt (Summary / Work &
  projects / Timeline / Notable sections), stores the result. **Not portable
  as-is**: this app has exactly one `PolishBackend` (`SystemLLM`, Apple
  Foundation Models on-device), whose `polish()` call already has a
  hardcoded 5s timeout that M3/S4 found trips well under 120,000 chars —
  S4 capped its own LLM inputs at 2,000 chars for the same reason
  (`AppState.swift:801-802`). A 120,000-char single-call digest is not a
  realistic port target; see Architecture below for the map-reduce design
  that replaces it.
- **`Store.swift`'s chronicles section** (lines 441-501) — schema worth
  keeping: `chronicles(day PRIMARY KEY, summary, snapshot_count,
  created_at)`, `upsertChronicle` (INSERT ... ON CONFLICT(day) DO UPDATE —
  regeneration overwrites), `getChronicle(day:)`, `listChronicles(limit:)`
  ordered newest-first. `snapshotsForDay(_:)` selects by
  `date(last_seen_at) = ? OR date(captured_at) = ?`, oldest-first
  (chronological order suits summarization).
- **`ChronicleTimelineSection.swift`** — raw AppKit (day list + detail split
  view). Per this project's established convention (S1's port map: "UI
  sections ... Rebuild — OmWhisper look & feel; Smriti files are wireframe
  reference only"), this is layout reference only — rebuilt in SwiftUI
  against this app's own `HistoryView.swift` patterns instead (searchable
  `List`, tap-to-expand rows, toolbar actions), which are already proven and
  more consistent with the rest of the app than smriti's raw AppKit.

## Architecture

New files in the existing `Memory/` group (mirrors `Meetings/`'s and
`ReplyAssist/`'s structure) plus two new UI files:

```
Memory/
├── MemoryStore.swift          # MODIFY — add chronicles table + CRUD, fetchPage/delete/deleteAll/storageInfo
├── Chronicler.swift           # CREATE — pure digest-building + chunking + async generate()
└── ChronicleScheduler.swift   # CREATE — Timer-driven daily trigger, owned by AppState
UI/
├── MemoryView.swift           # CREATE — window container: Snapshots/Chronicles picker + Snapshots tab
└── MemoryChroniclesView.swift # CREATE — Chronicles tab: day list + detail + Regenerate button
OmWhisperApp.swift              # MODIFY — new Window("Memory", id: "memory") scene + menu item
AppState.swift                  # MODIFY — own a ChronicleScheduler, wire it in the memoryEnabled setter
```

### `MemoryStore` additions

New `chronicles` table via a second `DatabaseMigrator` migration (the
existing `createSnapshots` migration is untouched — GRDB migrations are
additive/ordered, never edited after ship):

```swift
migrator.registerMigration("createChronicles") { db in
    try db.create(table: "chronicles") { t in
        t.column("day", .text).notNull().primaryKey()
        t.column("summary", .text).notNull()
        t.column("snapshotCount", .integer).notNull()
        t.column("createdAt", .text).notNull()
    }
}
```

`MemoryChronicle` record type (own file? no — small enough to live at the
top of `Chronicler.swift`, matching how `TranscriptionEntry` lives in
`HistoryStore.swift` rather than its own file):

```swift
nonisolated struct MemoryChronicle: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "chronicles"
    var id: String { day }
    var day: String
    var summary: String
    var snapshotCount: Int
    var createdAt: String
}
```

New `MemoryStore` methods (GRDB, matching `HistoryStore`'s exact method
shapes so `MemoryView` can mirror `HistoryView` line-for-line):

- `func fetchPage(offset: Int, limit: Int) throws -> [MemorySnapshot]` —
  `ORDER BY lastSeenAt DESC LIMIT ? OFFSET ?`. Powers "recent activity" (the
  Snapshots tab with an empty search box).
- `func delete(id: Int64) throws`, `func deleteAll() throws`,
  `func storageInfo() throws -> (count: Int, bytes: Int64)` — same shapes as
  `HistoryStore`'s (`SELECT COUNT(*)` and `page_count * page_size` via
  `PRAGMA`), so the Snapshots tab can offer the same delete/Clear All/footer
  stats `HistoryView` already has.
- `func upsertChronicle(day: String, summary: String, snapshotCount: Int) throws`
  — INSERT with `.save(db)` on a `MemoryChronicle` (GRDB's `save` already
  does insert-or-replace by primary key, so no manual `ON CONFLICT` SQL
  needed — simpler than smriti's raw-SQLite upsert).
- `func getChronicle(day: String) throws -> MemoryChronicle?`
- `func listChronicles(limit: Int = 60) throws -> [MemoryChronicle]` —
  `ORDER BY day DESC`.
- `func snapshotsForDay(_ day: String) throws -> [MemorySnapshot]` —
  `WHERE date(lastSeenAt) = ? OR date(capturedAt) = ? ORDER BY lastSeenAt ASC`
  (SQLite `date()` on an ISO8601 string works the same way smriti relies on).

### `Chronicler` — map-reduce generation

The real departure from smriti. `SystemLLM.polish()`'s 5s timeout is not
adjustable (fixed `Task.sleep(for: .seconds(5))` inside `SystemLLM.swift`),
and S4 already found ~2,000 chars is the safe input ceiling for that timeout
in practice. A whole day's snapshots will regularly exceed that. Rather than
inventing a new timeout parameter (speculative — no evidence the on-device
model handles long inputs at all, just more time) or truncating away most of
a busy day (lossy), split the day into ≤2,000-char chunks, summarize each
chunk individually (map), then write the final chronicle from the
concatenated chunk-summaries (reduce) — every individual `polish()` call
stays inside the already-proven-safe zone, no protocol changes.

```swift
nonisolated enum Chronicler {
    struct ChronicleResult { let day: String; let summary: String; let snapshotCount: Int }

    static let perSnapshotLimit = 500     // chars, per-snapshot content clip inside a digest block
    static let chunkCharLimit = 1_800     // leaves headroom under S4's proven-safe 2,000-char ceiling
    static let reduceCharLimit = 1_800    // same ceiling applied to the final (concatenated) call

    /// Fixed-UUID internal styles — never shown in the AI tab's picker, same
    /// pattern as S4's hidden reply-draft style.
    static let chunkSummaryStyle = PolishStyle(
        id: UUID(uuidString: "6C8A1C1E-0000-4A00-8000-000000000001")!,
        name: "Memory Chunk Summary", isBuiltIn: true,
        prompt: """
            Summarize this log of app/window activity into 2-4 terse bullet \
            points of what was worked on. No preamble, just bullets.
            """
    )
    static let chronicleWriteStyle = PolishStyle(
        id: UUID(uuidString: "6C8A1C1E-0000-4A00-8000-000000000002")!,
        name: "Memory Chronicle", isBuiltIn: true,
        prompt: """
            You are writing a private daily chronicle from bullet-point \
            activity summaries captured from the user's Mac screen \
            throughout the day. Write a concise markdown chronicle with \
            these sections:
            ## Summary — 2-3 sentences on what the day was about.
            ## Work & projects — what was worked on, per project/task, \
            merging repeated mentions of the same thing.
            ## Notable — anything worth remembering later: decisions, \
            errors, things ordered/booked, articles read.
            Rules: be specific, no filler, no speculation beyond what the \
            bullets show. The reader is the user themselves — write in \
            second person ("you worked on...").
            """
    )

    /// Pure: one digest line for a snapshot, content clipped to perSnapshotLimit.
    static func formatBlock(_ snapshot: MemorySnapshot) -> String {
        let content = snapshot.content
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(perSnapshotLimit)
        let location = snapshot.url.isEmpty ? "" : " <\(snapshot.url)>"
        return "[\(snapshot.lastSeenAt)] \(snapshot.appName) — \(snapshot.windowTitle)\(location)\n\(content)"
    }

    /// Pure: greedily packs blocks into groups whose combined length (with a
    /// blank-line separator between blocks) stays under `limit`. A single
    /// block longer than `limit` becomes its own oversized group rather than
    /// being split mid-block or dropped.
    static func chunk(_ blocks: [String], limit: Int = chunkCharLimit) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var currentLength = 0
        for block in blocks {
            let addedLength = block.count + (current.isEmpty ? 0 : 2)
            if !current.isEmpty && currentLength + addedLength > limit {
                groups.append(current)
                current = [block]
                currentLength = block.count
            } else {
                current.append(block)
                currentLength += addedLength
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Effectful: full generation for one day. Throws if there are no
    /// snapshots for that day; propagates the first polish() failure.
    static func generate(day: String, store: MemoryStore, polish: PolishBackend) async throws -> ChronicleResult {
        let snapshots = try store.snapshotsForDay(day)
        guard !snapshots.isEmpty else {
            throw ChroniclerError.noSnapshots
        }
        let blocks = snapshots.map(formatBlock)
        let chunks = chunk(blocks)

        var chunkSummaries: [String] = []
        for group in chunks {
            let text = String(group.joined(separator: "\n\n").prefix(chunkCharLimit))
            let summary = try await polish.polish(text, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(reduceCharLimit))
        let chronicle = try await polish.polish(reduceInput, style: chronicleWriteStyle, targetLanguage: nil)
        let trimmed = chronicle.trimmingCharacters(in: .whitespacesAndNewlines)

        try store.upsertChronicle(day: day, summary: trimmed, snapshotCount: snapshots.count)
        return ChronicleResult(day: day, summary: trimmed, snapshotCount: snapshots.count)
    }

    enum ChroniclerError: Error, LocalizedError {
        case noSnapshots
        var errorDescription: String? { "No captured activity for that day." }
    }

    /// Local calendar date string, matching smriti's `dayString(daysAgo:)`.
    static func dayString(daysAgo: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return formatter.string(from: date)
    }
}
```

For a genuinely heavy day (many chunk summaries whose concatenation still
exceeds `reduceCharLimit`), the reduce step truncates via `.prefix` rather
than recursing into a second reduce layer — accepted loss, matching how S4
already accepts truncation at its own caps. *(ponytail: single-level
reduce, add recursive reduction if chronicles measurably drop entire
projects on heavy-capture days.)*

### `ChronicleScheduler` — daily trigger

A small Timer wrapper, deliberately separate from `Chronicler` (pure logic)
and `MemoryCapture` (raw capture/prune — different dependency: this needs a
`PolishBackend`, not just a `MemoryStore`). Mirrors `MemoryCapture`'s own
`pollTimer`/`pruneTimer` + fire-once-at-`start()` shape exactly:

```swift
@MainActor
final class ChronicleScheduler {
    private static let interval: TimeInterval = 86_400

    var store: MemoryStore?
    var polish: PolishBackend?
    var isSuppressed: () -> Bool = { false }

    private var timer: Timer?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.generateIfNeeded() }
        }
        Task { @MainActor in await generateIfNeeded() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func generateIfNeeded() async {
        guard !isSuppressed(), let store, let polish else { return }
        let yesterday = Chronicler.dayString(daysAgo: 1)
        guard (try? store.getChronicle(day: yesterday)) == nil else { return }
        _ = try? await Chronicler.generate(day: yesterday, store: store, polish: polish)
    }
}
```

`isSuppressed` is gated on `polishBackend != .system` (AI polish disabled)
or `!SystemLLM.isAvailable()` (Apple Intelligence off), checked fresh each
tick — same closure-read-live-state contract as `MemoryCapture.isSuppressed`
and `MeetingWatcher.isSuppressed`. Chronicle generation for a day is
idempotent — skipped once that day already has a chronicle, so restarting
the app repeatedly doesn't regenerate yesterday over and over. Manual
regeneration (below) bypasses this check and always overwrites.

### `AppState` wiring

Same pattern as `memoryCapture`:

```swift
@ObservationIgnored private let chronicleScheduler = ChronicleScheduler()
```

Inside the existing `memoryEnabled` setter, alongside the current
`memoryCapture.store = ...` / `.start()` / `.stop()` lines:

```swift
chronicleScheduler.store = memoryStore
chronicleScheduler.polish = systemLLM
chronicleScheduler.isSuppressed = { [weak self] in
    self?.polishBackend != .system || !SystemLLM.isAvailable()
}
if newValue { chronicleScheduler.start() } else { chronicleScheduler.stop() }
```

### UI

`Window("Memory", id: "memory")` scene in `OmWhisperApp.swift`, added right
after the existing `Window("History", ...)` block, `.defaultLaunchBehavior(.suppressed)`
for the same window-state-restoration reason already documented on the
History window. `AppDelegate` gains `openMemoryAction: OpenWindowAction?`
and an `openMemory()` action/menu item ("Memory…", right after "History…"),
mirroring `openHistory()` exactly.

`MemoryView.swift` — top-level container:

```swift
struct MemoryView: View {
    private enum Tab { case snapshots, chronicles }
    @State private var tab: Tab = .snapshots

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Snapshots").tag(Tab.snapshots)
                Text("Chronicles").tag(Tab.chronicles)
            }
            .pickerStyle(.segmented)
            .padding(8)
            switch tab {
            case .snapshots: MemorySnapshotsView()
            case .chronicles: MemoryChroniclesView()
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}
```

`MemorySnapshotsView` (private view in the same file, or a small separate
one if it grows) — a near-verbatim structural copy of `HistoryView`'s body:
searchable `List`, `.task(id: searchText)` debounced reload, empty search →
`fetchPage(offset:limit:)`, non-empty → `search(_:limit:)`, tap-to-expand
row showing `appName` / `windowTitle` / `url` / full `content`, per-row
delete, toolbar "Clear All" with the same confirmation dialog, footer with
`storageInfo()` count/bytes. Difference from `HistoryView`: no Export menu
(captured screen text isn't meant to leave the device casually — YAGNI
until asked for) and no multi-select bulk delete (single delete + Clear All
covers it; `HistoryView`'s bulk-select exists because dictation history
rows are small/numerous — memory snapshots are chunkier and this is net-new
UI, add multi-select if it turns out to matter).

`MemoryChroniclesView.swift` — day list (left) + detail (right), `NavigationSplitView`
(SwiftUI-native replacement for smriti's raw `NSSplitView`): list of
`listChronicles()` results (day + snapshotCount), selecting one shows its
`summary` rendered as markdown (`Text(markdown:)`, SwiftUI's built-in
Markdown rendering — no new dependency) plus a "Regenerate" toolbar button
that calls `Chronicler.generate(day:store:polish:)` directly (bypassing
`ChronicleScheduler`'s idempotency check) and shows a spinner while it runs.
Empty state when no chronicles exist yet ("Chronicles appear here once a
day, generated automatically.").

## Global Constraints

- No new Settings toggle — chronicle generation and the browse UI are both
  gated entirely by the existing `memoryEnabled` flag (S1), off by default
  like every Smriti-derived feature.
- Chronicle generation additionally requires `polishBackend == .system` and
  `SystemLLM.isAvailable()` — if AI polish is off or Apple Intelligence is
  unavailable, chronicles simply don't generate (no error surfaced to the
  user on a background daily tick; `errorMessage` is reserved for
  user-initiated actions, matching the project's existing convention).
- Every individual `PolishBackend.polish()` call in `Chronicler` stays
  ≤2,000 chars input (`chunkCharLimit`/`reduceCharLimit` both under that),
  matching S4's already-proven-safe ceiling for `SystemLLM`'s 5s timeout —
  no protocol changes to `PolishBackend`/`SystemLLM`.
- Chronicles live in `memory.db` (same `MemoryStore`, not a new database) —
  they're derived from snapshots and should be wiped together with the rest
  of memory on a full "delete everything" action, same reasoning that put
  memory in its own database separate from `HistoryStore` in S1.
- Manual "Regenerate" always overwrites (`upsertChronicle` is insert-or-
  replace by day); the daily scheduler never regenerates a day that already
  has a chronicle.

## Error Handling & Permissions

- `Chronicler.generate` throws `ChroniclerError.noSnapshots` for a day with
  no captured activity — `ChronicleScheduler` silently skips (background
  tick, nothing to show the user); the UI's manual Regenerate button surfaces
  it as an inline error state.
- Any `PolishBackend.polish()` failure (timeout, Apple Intelligence
  unavailable mid-run, etc.) propagates up through `generate()` uncaught —
  `ChronicleScheduler` swallows it (`try?`, retries next day); manual
  Regenerate surfaces it the same way as `noSnapshots`.
- `MemoryStore` open failure (already handled in S1 — `memoryStore` stays
  `nil`) means `ChronicleScheduler.store` is never set, so `generateIfNeeded()`
  no-ops via its `guard let store` — no crash, matches `MemoryCapture`'s
  existing "DB failed to open → feature becomes a no-op" principle.

## Testing

Pure-logic unit tests (Swift Testing): `Chronicler.chunk(_:limit:)` (empty
input, single block under limit, single block over limit becomes its own
oversized group, many small blocks pack into minimal groups, exact
boundary at `limit`), `Chronicler.formatBlock(_:)` (content clipped at
`perSnapshotLimit`, url line omitted when empty), `Chronicler.dayString(daysAgo:)`.
`MemoryStore`'s new chronicle CRUD methods get direct GRDB round-trip tests
(upsert-then-get, upsert-twice-overwrites, listChronicles ordering,
snapshotsForDay date filtering) — same style as existing `MemoryStoreTests`.
`ChronicleScheduler.generateIfNeeded()`'s idempotency (skip when a chronicle
already exists) and `Chronicler.generate`'s end-to-end flow are covered by
live verification via the UI's manual Regenerate button (a fake/mock
`PolishBackend` for `generate()`'s async LLM-calling path is more test
scaffolding than the logic warrants — the map/reduce chunking and prompt
construction are exactly what's unit-tested; the actual `polish()` call is
already covered end-to-end by `SystemLLM`'s live usage elsewhere in the
app). UI (`MemorySnapshotsView`/`MemoryChroniclesView`) is live-verified,
matching every other SwiftUI view in this project — no XCUITest (removed
project-wide, see memory).

**Exit criteria**: a chronicle for yesterday appears automatically after
the app has been running with Memory enabled across a day boundary; the
Memory window's Snapshots tab shows recent captures with working search;
Chronicles tab shows generated summaries with working manual Regenerate.
