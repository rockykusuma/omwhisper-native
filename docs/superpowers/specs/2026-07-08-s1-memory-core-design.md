# Design: S1 — Memory Core

> Written 2026-07-08. Brainstormed via `superpowers:brainstorming`. Implements
> "S1 — Memory core (foundation, no UI beyond a toggle)" from
> `docs/SMRITI_INTEGRATION_PLAN.md`, next in the project's priority order
> (M2 → S2 → M3 → S3 → S4 → **S1** → S5 → M4 → S6/M5) after S4 shipped. This
> is the biggest trust ask in Phase S — continuous background capture, not
> the on-demand-only reads S2/S3/S4 all used — and unlocks S5 (memory
> surfacing + MCP) afterward.

## Goal

A background daemon periodically captures the frontmost window's visible
text (with app/window/URL metadata), stores it in a searchable local
database with dedup and retention, and respects exclusions (sensitive apps,
private browsing, excluded domains). No search or surfacing UI in this
sub-project — that's S5. Off by default, per this project's standing
privacy contract for every Smriti-derived feature.

## Reference: smriti's implementation

Investigated directly from `/Users/rakeshkusuma/Documents/PersonalProjects/smriti`
(same author, MIT, read-only reference per this project's conventions) —
`CaptureDaemon.swift`, `AXReader.swift`, `BrowserURL.swift`, `Store.swift`,
`Config.swift`:

- **`CaptureDaemon.swift`** (128 lines) — `Timer.scheduledTimer(withTimeInterval:
  repeats: true)` at a 5s default interval, `timer.tolerance = 1.0`. Each
  tick: `AXReader.captureFrontmost()` → exclusion checks (bundle ID exact
  match → title substring, case-insensitive → domain-with-subdomain match
  via `BrowserURL`) → truncate content to `maxContentLength` (20,000 chars
  default) → `store.upsert(...)`. Daily prune (`store.prune(olderThanDays:)`,
  skipped when `retentionDays <= 0`). Pause via a `SIGUSR1` signal handler —
  **not ported**: that's a workaround for smriti running as a separate
  launchd CLI daemon with no other IPC channel; this app is a normal
  in-process menu-bar app, so pause is just a settings-backed flag the
  capture loop checks each tick, matching how `MeetingWatcher.isSuppressed`
  already works.
- **`AXReader.swift`** (110 lines) — `captureFrontmost(timeBudget: TimeInterval
  = 2.0)` returns text PLUS metadata this project's existing
  `ScreenContextReader` (S2, already shipped) does not: `bundleId`,
  `appName`, `windowTitle`, `url`. Same tree-walk shape `ScreenContextReader`
  already ported (depth < 40, 50,000-char budget, wall-clock deadline
  checked every node) — the walk itself is proven and shipped; this sub-
  project extends what it *returns*, not how it walks.
- **`BrowserURL.swift`** (110 lines) — pure AX, no AppleScript (avoids an
  Automation permission prompt). 9 browser bundle IDs. Two-strategy lookup:
  recursively find an `AXWebArea` role and read its `"AXURL"` attribute
  (works for Safari + hydrated Chromium/Firefox trees); fallback recursively
  finds a text field near the top of the tree whose title/description
  contains "address" (Chromium "hides AXURL until a screen reader is
  active" — a real, documented gotcha). Deliberately not ported for S2
  (nothing there called it); genuinely needed now for domain-based exclusion.
- **`Redactor.swift`** — confirmed via grep: its only call site in smriti is
  scrubbing the reply-assist prompt before cloud egress
  (`AssistListener.swift:311`). **Not applied to captured snapshots at all**
  — smriti stores everything raw locally, treating the local DB itself as
  trusted. This project makes the same choice (see Global Constraints) —
  Redactor has no use in this sub-project.
- **`Store.swift`** (590 lines) — raw SQLite3 C API, **not ported as
  architecture**: this project already has a GRDB-based store
  (`HistoryStore.swift`) and a from-scratch GRDB schema is the better fit,
  not a second SQLite access pattern. The *schema* is what's worth porting:
  `snapshots(id, app, bundle_id, window_title, content, url, content_hash,
  captured_at, last_seen_at)`, `UNIQUE(bundle_id, window_title,
  content_hash)` dedup index (`content_hash` = SHA256 of content), `upsert`
  = insert-or-bump-`last_seen_at`, and an FTS5 virtual table
  (`content=snapshots, content_rowid=id`) kept in sync via
  insert/delete/update triggers, with search ranking via `ORDER BY rank`.
- **`Config.swift`** (159 lines) — relevant defaults reused/extended here:
  `excludedBundleIds` (Passwords, keychainaccess, 1Password —
  `ScreenContextReader` already has an equivalent list, reused rather than
  duplicated), `excludedTitleSubstrings` ("Private Browsing", "Incognito" —
  also already in `ScreenContextReader`), `captureIntervalSeconds: 5`,
  `maxContentLength: 20_000`, `retentionDays: 90` (0 disables pruning).
  `excludedDomains` is new for this project (S2 had no domain concept —
  no `BrowserURL` port yet).

## Architecture

New `Memory/` group, mirroring `Meetings/`'s and `ReplyAssist/`'s structure:

```
Memory/
├── MemorySnapshot.swift      # CREATE — GRDB record type
├── MemoryStore.swift         # CREATE — separate GRDB DatabaseQueue, snapshots + FTS5
├── BrowserURL.swift          # CREATE — ported from smriti, for domain exclusion + tagging
├── WindowSnapshotReader.swift # CREATE — extends ScreenContextReader's walk with metadata
├── MemoryCapture.swift       # CREATE — Timer-driven daemon, exclusion + retention
└── MemorySelfTest.swift      # CREATE — #if DEBUG FTS search verification
UI/
└── MemorySettingsView.swift  # CREATE — toggle, pause, retention stepper
```

- **`MemorySnapshot`** — GRDB `FetchableRecord`/`MutablePersistableRecord`,
  fields matching smriti's schema: `id: Int64?, appName: String, bundleID:
  String, windowTitle: String, content: String, url: String, contentHash:
  String, capturedAt: String, lastSeenAt: String` (ISO8601 strings, matching
  `HistoryStore.TranscriptionEntry`'s existing convention — not smriti's
  POSIX-locale local-time strings).
- **`MemoryStore`** — `nonisolated final class`, its own `DatabaseQueue`
  (separate file: `memory.db` in the app support directory, per the
  separate-database decision above), `DatabaseMigrator` creating
  `snapshots` + the FTS5 virtual table + sync triggers in one migration.
  `upsert(_:)` does the dedup insert-or-bump-`lastSeenAt`. `search(_:limit:)`
  wraps the FTS5 query. `prune(olderThanDays:)` deletes stale rows (trigger
  keeps FTS in sync automatically).
- **`BrowserURL`** — ported near-verbatim per the Reference section above.
- **`WindowSnapshotReader`** — the AX tree-walk logic factored out of
  `ScreenContextReader` into a shared internal helper both types call, so
  `ScreenContextReader.captureFrontmostWindowText()` (S2's existing text-only
  contract, still used by dictation) is unchanged in behavior, while this
  new reader additionally returns `bundleID`/`appName`/`windowTitle`/`url`
  (via `BrowserURL`) for `MemoryCapture` to store and dedup on.
- **`MemoryCapture`** — `@MainActor final class` (matching `MeetingWatcher`'s
  isolation — it's a lightweight poll, not a real-time audio path), owns a
  `Timer` at `captureIntervalSeconds` (5s default), a `paused: Bool`, and
  the exclusion list (reusing `ScreenContextReader`'s existing
  bundle/title exclusions, extended with domain exclusion via
  `BrowserURL`). Each tick: capture → exclude-check → truncate → write via
  `MemoryStore.upsert(_:)`, entirely skipping the write for excluded
  content (not writing-then-filtering). A separate daily `Timer` (or a
  once-at-`start()`-plus-24h-repeat, matching smriti) calls
  `store.prune(olderThanDays:)`.
- **Settings** — `AppState.memoryEnabled` (off by default, same
  `access(keyPath:)`/`withMutation(keyPath:)` + collaborator-wiring pattern
  as `meetingsEnabled`/`replyAssistEnabled`), `AppState.memoryPaused`
  (independent of the enabled toggle — pause without fully disabling),
  `AppState.memoryRetentionDays` (default 90). `UI/MemorySettingsView.swift`
  exposes all three plus a "capture is currently off/paused/running" status
  line — no search/browse UI, that's S5's job entirely.
- **`MemorySelfTest`** — `#if DEBUG`, matching `MeetingSelfTest`'s pattern:
  triggers a capture, writes it, runs an FTS query for a known substring,
  reports pass/fail via `NSAlert` from a new debug menu item.

## Global Constraints

- Off by default: `AppState.memoryEnabled` defaults to `false`.
  `MemoryCapture` is not instantiated or started unless this is on — no
  Timer runs at all for a user who hasn't opted in.
- Separate database from `HistoryStore` — a user must be able to wipe all
  captured memory without touching dictation history, and vice versa.
- No redaction on write — snapshots are stored raw, matching smriti's own
  design choice and this app's "local by default, fully trusted" story.
  Revisit only if S5's MCP/remote surfacing ever needs it — that's a
  separate, later decision, not default behavior here.
- Exclusions are checked *before* any write is attempted — an excluded
  capture is never staged then filtered, it's simply never handed to
  `MemoryStore.upsert(_:)`.
- Pause is a settings-backed flag, not smriti's `SIGUSR1` signal handler —
  this app has no separate daemon process to signal.
- Reuse `ScreenContextReader`'s existing bundle-ID/title exclusion lists and
  AX tree-walk rather than duplicating them; extend, don't fork.
- `captureIntervalSeconds: 5`, `maxContentLength: 20_000`,
  `retentionDays: 90` — smriti's proven defaults, kept as this app's
  defaults too rather than guessed at from scratch.

## Error Handling & Permissions

- No Accessibility permission → capture silently no-ops (reusing the same
  `AXIsProcessTrustedWithOptions` check already used elsewhere); logs once,
  never spams `errorMessage` on every 5s tick.
- Pruning failure (disk full, DB error) logs and skips — never crashes,
  never blocks the next capture tick.
- `MemoryStore` open/migration failure → `memoryEnabled` setting stays
  readable/settable but capture silently no-ops, matching
  `HistoryStore`'s existing "DB failed to open → nil, feature becomes a
  no-op, not a crash" principle.

## Testing

Pure-logic unit tests (Swift Testing): exclusion-check functions (bundle
ID exact match, title substring case-insensitivity, domain-with-subdomain
matching via `BrowserURL.domain(_:matches:)`'s logic), the dedup
insert-vs-bump decision as a pure function over `(existing:
MemorySnapshot?, new: MemorySnapshot) -> MemorySnapshot`, content-length
truncation at `maxContentLength`. AX-dependent capture, real GRDB/FTS5
read-write, and the daily prune timer are covered by live verification +
the `MemorySelfTest` debug menu item, matching S2/S3/S4's established split
between what's unit-testable and what genuinely isn't.

**Exit criteria** (from `docs/SMRITI_INTEGRATION_PLAN.md`): capture runs a
full day without measurable battery/CPU complaint; excluded apps provably
never hit the DB; FTS search works from the debug self-test.
