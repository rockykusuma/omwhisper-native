# Design: History + Importer (M2)

> Written 2026-07-07. Brainstormed via `superpowers:brainstorming`. Implements
> the "History + importer" line item from `CLAUDE.md`'s M2 progress tracker.

## Goal

Store every dictation the native app produces, import the old Tauri app's
history on first run, and give the user a way to browse/search/export/delete
it — full parity with the old app's History feature (see
`NATIVE_MIGRATION_PLAN.md` Appendix B: "history (search/export
txt-md-json/delete/clear/auto-delete/storage info)").

## Reference: old app's schema and behavior

Investigated directly (not assumed) from
`/Users/rakeshkusuma/Documents/PersonalProjects/omwhisper/src-tauri/src/history.rs`
and `src/components/TranscriptionHistory.tsx`:

```sql
CREATE TABLE transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    text TEXT NOT NULL,
    duration_seconds REAL NOT NULL DEFAULT 0,
    model_used TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,       -- RFC3339 string
    word_count INTEGER NOT NULL DEFAULT 0,
    source TEXT NOT NULL DEFAULT 'raw',   -- 'raw' | 'smart_dictation'
    raw_text TEXT,                  -- pre-polish text, smart_dictation only
    polish_style TEXT               -- e.g. 'professional', smart_dictation only
);
```

DB lives at `data_local_dir()/com.omwhisper.app/history.db` — on macOS that's
`~/Library/Application Support/com.omwhisper.app/history.db`.

Old UI features (`TranscriptionHistory.tsx`): paginated list (30/page, newest
first), debounced LIKE-search, tap-to-expand row with Copy/Delete, multi-select
bulk delete, Export (txt/md/json, browser-download), Clear All
(confirmation), empty state. Storage info + auto-delete-after-days setting
live in the old app's main Settings window (`Settings.tsx`), not the history
view itself.

`cleanup_old_transcriptions(days)` (old app's Rust, `lib.rs:858`) runs once at
app startup if `auto_delete_after_days` is set — no background timer.

## Scope for this pass

Full parity: data layer (store + importer + auto-recording) **and** a
browsing UI. (Decided over "data layer only" — see brainstorming Q&A.)

Explicitly **not** in scope, carried over from earlier decisions this
project has already made:
- Importing the old app's **vocabulary**/settings data — user chose "Skip for
  now" on this during the M2 vocabulary milestone; only **history** rows are
  imported here.
- `source: "smart_dictation"` / `rawText` / `polishStyle` are schema-ready but
  unused — smart dictation doesn't exist until M3. Every entry recorded by
  this pass has `source: "raw"`, `rawText: nil`, `polishStyle: nil`.
- `modelUsed` is a hardcoded `"Apple SpeechTranscriber"` constant for now —
  only `AppleEngine` exists; this becomes real per-backend info at M4.

## Architecture

New `History/` group, following the existing collaborator pattern
(`AudioCapture`, `AppleEngine`, `OverlayPanel` are plain classes owned by
`AppState`).

### `History/HistoryStore.swift`

GRDB `DatabaseQueue` (GRDB added as a new SPM dependency — already the
project's chosen tech per `CLAUDE.md`'s Tech Stack table) opened at
`~/Library/Application Support/com.omwhisper.mac/history.db` — the *new*
bundle ID's own directory. The old app's db is only ever opened read-only,
once, for import; the new store never touches it again.

Single `transcriptions` table via a GRDB migration, same columns/semantics as
the Rust schema above (Swift-cased). `TranscriptionEntry` is a
`Codable, FetchableRecord, PersistableRecord, Identifiable` struct mapping it.

```swift
struct TranscriptionEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var text: String
    var durationSeconds: Double
    var modelUsed: String
    var createdAt: String   // ISO8601
    var wordCount: Int
    var source: String      // "raw" | "smart_dictation"
    var rawText: String?
    var polishStyle: String?
}
```

`HistoryStore` methods (1:1 with the old Rust functions):
`record(text:duration:modelUsed:) throws`,
`fetchPage(offset:limit:) throws -> [TranscriptionEntry]`,
`search(_:) throws -> [TranscriptionEntry]`,
`delete(id:) throws`, `deleteAll() throws`,
`deleteOlderThan(days:) throws -> Int`,
`storageInfo() throws -> (count: Int, bytes: Int64)`,
`exportAll(format: ExportFormat) throws -> String` (txt/markdown/json,
formatting logic ported from the Rust `export_history`).

### `History/LegacyHistoryImporter.swift`

Opens the old app's `history.db` (if present at
`~/Library/Application Support/com.omwhisper.app/history.db`) as a second,
read-only GRDB connection, copies every row into the new store, once — gated
by a `UserDefaults` flag (`hasImportedLegacyHistory`). Runs in a background
`Task` fired from `AppState.init()` — never blocks app launch. If the old DB
is missing or malformed, log and set the flag anyway (never retries every
launch — "one-time" per `CLAUDE.md`'s own description of this feature).

### Robustness

`AppState.historyStore: HistoryStore?` — if the DB fails to open, log and
continue with `nil` (history becomes a silent no-op) rather than crashing the
app. Matches the project's existing "engine error → toast, not app crash"
principle (Appendix B).

### `AppState` integration

- New `private var recordingStartedAt: ContinuousClock.Instant?`, set in
  `startDictation()` right after `audioCapture.start()` succeeds.
- In `stopDictation()`, when the already-computed `phase == .pasting` (real,
  non-empty, non-error text — see `exitPhase`), call
  `historyStore?.record(text:, duration:, modelUsed: "Apple SpeechTranscriber")`.
  Cancelled/"nothing heard"/error sessions are **not** recorded. Fire-and-forget:
  errors are logged, never block or fail the paste itself.
- Same background `Task` that runs the importer also runs cleanup: if a new
  `autoDeleteAfterDays: Int?` setting (UserDefaults-backed, same pattern as
  existing settings) is set, call `historyStore?.deleteOlderThan(days:)`.

## UI

New SwiftUI `Window` scene in `OmWhisperApp.swift`, alongside the existing
`Settings { }` scene:

```swift
Window("History", id: "history") { HistoryView().environment(delegate.appState) }
```

Menu bar gets a **"History…"** item (between Settings and Quit), wired
identically to how `Settings…` already works: `@Environment(\.openWindow)`
captured once in `makeScene()`, stored as `openWindowAction` on
`AppDelegate`; `@objc func openHistory()` calls `NSApp.activate` +
`openWindowAction?(id: "history")`.

**`UI/HistoryView.swift`** — `List` of `TranscriptionEntry`, newest first,
paginated (load-more on scroll-to-bottom, 30/page, matching the old app):

- Debounced search field at top (LIKE-based via `HistoryStore.search(_:)`).
- Each row: truncated preview, tap-to-expand for full text with Copy/Delete
  actions.
- Toolbar: **Select** (bulk multi-delete mode, matching old UX),
  **Export ▾** (txt/md/json via `NSSavePanel` — native replacement for the
  old app's browser-download hack), **Clear All** (confirmation dialog
  first).
- Footer: storage info (`"N transcriptions · X KB"`) + an **Auto-Delete
  After** stepper (Off / 7 / 30 / 90 days) — folds the old app's
  Settings-window storage section into this window instead, since it's
  history-specific. Deliberate placement change vs. the old app, not an
  oversight.
- Empty state: same "🕐 No transcriptions yet" treatment as the old app.

## Data flow summary

- **Record**: `stopDictation()` → `phase == .pasting` →
  `historyStore?.record(...)`.
- **Import**: app launch → background `Task` → check
  `hasImportedLegacyHistory` flag → if unset, check old DB file exists →
  copy rows → set flag.
- **Cleanup**: same background `Task`, after import, if `autoDeleteAfterDays`
  is set.
- **UI errors** (delete/export failures): surfaced via a lightweight
  toast/inline message in `HistoryView`, never a crash.

## Testing

- **`HistoryStoreTests.swift`** (Swift Testing, in-memory `DatabaseQueue`) —
  ports the old Rust suite: insert/incrementing ids, word-count computation,
  pagination, search (match/no-match/case-insensitive), delete/clear, export
  format contents (txt/md/json), storage info, `deleteOlderThan` cutoff
  behavior.
- **`LegacyHistoryImporterTests.swift`** — given a fixture old-schema
  in-memory DB with a few rows, verify they land correctly in the new store;
  verify a second run doesn't duplicate (flag respected); verify a
  missing/malformed old DB doesn't crash and still sets the flag.
