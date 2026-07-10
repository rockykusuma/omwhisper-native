# D3a — Home Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace D2a's `HubHomeView` placeholder with the real dashboard —
greeting + streak sentence, three stat cards (words today, time saved vs.
typing, speaking pace), a 7-day quiet-reflection bar line, and the last 3
dictations with Copy/Re-polish — all backed by real `HistoryStore` data, per
`docs/DESIGN_DIRECTION.md` §3 and `docs/hub-concept.html`'s Home view.

**Architecture:** D3 (Home + menu-bar mini-panel) was split into D3a (this)
and D3b (the mini-panel) — the two surfaces share no code and have entirely
different mechanics (SwiftUI content pane vs. `NSPopover` on the status
item), so there's no dependency forcing them together, matching this
project's established pattern of splitting loosely-coupled multi-surface
milestones. `HistoryStore` gains one new read query (`homeStats()`); `AppState`
gains one new thin wrapper (`rePolish(_:)`, reusing the exact same
fallback-safe polish call the live dictation path already uses); `HubHomeView`
is rebuilt from a placeholder into the real dashboard.

**Tech Stack:** SwiftUI, GRDB (raw SQL for date-grouping/streak queries,
matching the exact algorithm the old Tauri app's `get_stats_summary` used —
verified by reading `omwhisper/src-tauri/src/history.rs` directly, not
guessed), `RelativeDateTimeFormatter` (native, for "2 min ago" row timestamps).

## Global Constraints

- The old Tauri app's `StatsSummary`/`get_stats_summary` (`omwhisper/src-tauri/src/history.rs`)
  is the reference for the streak-day algorithm specifically (consecutive
  distinct days including today, walking backward, break on first gap) — port
  that logic faithfully. "Words today," "time saved vs. typing," and "speaking
  pace" are **not** in the old app (its stats card only ever showed
  totals/today's *count*/streak) — these are new computations for the new
  mockup, designed here from the real schema (`wordCount`, `durationSeconds`),
  not invented without grounding.
- `TranscriptionEntry` has no "destination app" field — `hub-concept.html`'s
  per-row app icon has no backing data in this schema. Recent-dictation rows
  show a generic icon + the entry's polish style (`polishStyle`/`source`)
  instead of an app icon, rather than adding a new column (a schema/importer
  change is out of scope for a dashboard task).
- Re-polish is Copy-only — it copies the polished result to the clipboard,
  it never pastes into whatever app happens to be frontmost while the user is
  sitting in the hub window. Matches `HistoryView`'s existing Copy action's
  safety profile, not live dictation's paste-on-stop.
- Count-up numeral animation and the 7-day bar's "breathing" pulse
  (`hub-concept.html`'s `@keyframes breathebar`) are explicitly deferred to
  D4 (motion polish) — this task ships correct, static numbers and bar
  heights first, matching D1/D2a's established "structural correctness now,
  animation timing later" phasing (see D2a's sidebar-aurora `ponytail` note
  for precedent).
- New declarations default to `@MainActor` per this project's
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — `HistoryStore` stays
  `nonisolated` (existing convention, GRDB I/O has no MainActor affinity);
  `AppState.rePolish(_:)` is a normal (MainActor) async method, matching
  every other `AppState` polish call site.

## Task 1: `HistoryStore.homeStats()`

**Files:**
- Modify: `omwhisper-native/History/HistoryStore.swift`
- Test: `omwhisper-nativeTests/HistoryStoreTests.swift`

**Interfaces:**
- Produces: `struct HomeStats: Equatable { wordsToday: Int, durationTodaySeconds: Double, streakDays: Int, last7DaysWordCounts: [Int] }` with computed `speakingPaceWPM: Int` and `minutesSavedVsTyping: Int`; `HistoryStore.homeStats() throws -> HomeStats` — consumed by Task 3's `HubHomeView`.

- [ ] **Step 1: Write the failing tests**

Add to `omwhisper-nativeTests/HistoryStoreTests.swift`. The file already has
exactly the helper this needs: `makeStore() throws -> (HistoryStore,
DatabaseQueue)` and a `seed(_:text:createdAt:duration:modelUsed:)` that writes
a row with an explicit `createdAt` directly via the returned `DatabaseQueue`
(bypassing `record()`, which always stamps "now"). Reuse both — no new
production API needed. Append a new suite at the end of the file:

```swift
@Suite("HistoryStore.homeStats")
struct HistoryStoreHomeStatsTests {
    private func makeStore() throws -> (HistoryStore, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let store = try HistoryStore(dbQueue)
        return (store, dbQueue)
    }

    private func seed(_ dbQueue: DatabaseQueue, words: Int, duration: Double, daysAgo: Int) throws {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        var entry = TranscriptionEntry(
            id: nil, text: text, durationSeconds: duration, modelUsed: "test",
            createdAt: ISO8601DateFormatter().string(from: date), wordCount: words,
            source: "raw", rawText: nil, polishStyle: nil
        )
        try dbQueue.write { db in try entry.insert(db) }
    }

    @Test("wordsToday sums only today's entries")
    func wordsTodaySumsOnlyToday() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, words: 10, duration: 30, daysAgo: 0)
        try seed(dbQueue, words: 5, duration: 15, daysAgo: 0)
        try seed(dbQueue, words: 100, duration: 300, daysAgo: 1)
        let stats = try store.homeStats()
        #expect(stats.wordsToday == 15)
        #expect(stats.durationTodaySeconds == 45)
    }

    @Test("streakDays counts consecutive days including today")
    func streakCountsConsecutiveDays() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, words: 10, duration: 30, daysAgo: 0)
        try seed(dbQueue, words: 10, duration: 30, daysAgo: 1)
        try seed(dbQueue, words: 10, duration: 30, daysAgo: 2)
        let stats = try store.homeStats()
        #expect(stats.streakDays == 3)
    }

    @Test("streakDays stops at the first gap")
    func streakStopsAtGap() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, words: 10, duration: 30, daysAgo: 0)
        try seed(dbQueue, words: 10, duration: 30, daysAgo: 1)
        try seed(dbQueue, words: 10, duration: 30, daysAgo: 3)   // gap at day 2
        let stats = try store.homeStats()
        #expect(stats.streakDays == 2)
    }

    @Test("streakDays is 0 with no entries today")
    func streakIsZeroWithoutToday() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, words: 10, duration: 30, daysAgo: 1)
        let stats = try store.homeStats()
        #expect(stats.streakDays == 0)
    }

    @Test("last7DaysWordCounts has 7 entries, 0 for empty days")
    func last7DaysHasSevenEntries() throws {
        let (store, dbQueue) = try makeStore()
        try seed(dbQueue, words: 20, duration: 60, daysAgo: 0)
        try seed(dbQueue, words: 30, duration: 90, daysAgo: 6)
        let stats = try store.homeStats()
        #expect(stats.last7DaysWordCounts.count == 7)
        #expect(stats.last7DaysWordCounts.last == 20)    // today, last in the array
        #expect(stats.last7DaysWordCounts.first == 30)   // 6 days ago, first in the array
        #expect(stats.last7DaysWordCounts[1...5].allSatisfy { $0 == 0 })
    }

    @Test("homeStats on an empty store returns all zeros")
    func emptyStoreReturnsZeros() throws {
        let (store, _) = try makeStore()
        let stats = try store.homeStats()
        #expect(stats.wordsToday == 0)
        #expect(stats.durationTodaySeconds == 0)
        #expect(stats.streakDays == 0)
        #expect(stats.last7DaysWordCounts == [0, 0, 0, 0, 0, 0, 0])
    }
}

@Suite("HomeStats derived values")
struct HomeStatsDerivedTests {
    @Test("speakingPaceWPM computes words per minute")
    func wpmComputes() {
        let stats = HomeStats(wordsToday: 150, durationTodaySeconds: 60, streakDays: 1, last7DaysWordCounts: Array(repeating: 0, count: 7))
        #expect(stats.speakingPaceWPM == 150)
    }

    @Test("speakingPaceWPM is 0 with no dictation time")
    func wpmIsZeroWithNoDuration() {
        let stats = HomeStats(wordsToday: 0, durationTodaySeconds: 0, streakDays: 0, last7DaysWordCounts: Array(repeating: 0, count: 7))
        #expect(stats.speakingPaceWPM == 0)
    }

    @Test("minutesSavedVsTyping is positive when dictation is faster than typing at 45wpm")
    func minutesSavedPositive() {
        // 450 words dictated in 2 minutes (120s); typing at 45wpm would take 10 minutes.
        let stats = HomeStats(wordsToday: 450, durationTodaySeconds: 120, streakDays: 1, last7DaysWordCounts: Array(repeating: 0, count: 7))
        #expect(stats.minutesSavedVsTyping == 8)
    }

    @Test("minutesSavedVsTyping never goes negative")
    func minutesSavedClampedToZero() {
        // 10 words dictated in 10 minutes (600s) -- slower than typing.
        let stats = HomeStats(wordsToday: 10, durationTodaySeconds: 600, streakDays: 1, last7DaysWordCounts: Array(repeating: 0, count: 7))
        #expect(stats.minutesSavedVsTyping == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/HistoryStoreHomeStatsTests -only-testing:omwhisper-nativeTests/HomeStatsDerivedTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — "Cannot find 'HomeStats' in scope" / "value of type 'HistoryStore' has no member 'homeStats'"

- [ ] **Step 3: Implement `HomeStats` and `homeStats()`**

In `omwhisper-native/History/HistoryStore.swift`, add after the `ExportFormat`
enum:

```swift
struct HomeStats: Equatable {
    let wordsToday: Int
    let durationTodaySeconds: Double
    let streakDays: Int
    /// Oldest to newest (index 0 = 6 days ago, index 6 = today); 0 for any
    /// day with no dictations.
    let last7DaysWordCounts: [Int]

    var speakingPaceWPM: Int {
        guard durationTodaySeconds > 0 else { return 0 }
        return Int((Double(wordsToday) / (durationTodaySeconds / 60)).rounded())
    }

    /// Typing time at 45wpm minus actual dictation time, clamped to >= 0 --
    /// dictating slower than you'd type is a real (if rare) outcome and
    /// shouldn't show as negative "time saved."
    var minutesSavedVsTyping: Int {
        let typingMinutes = Double(wordsToday) / 45.0
        let dictationMinutes = durationTodaySeconds / 60.0
        return max(0, Int((typingMinutes - dictationMinutes).rounded()))
    }
}
```

Then add the query method (after `storageInfo()`):

```swift
    /// Backs the hub's Home dashboard. `streakDays`' algorithm is a direct
    /// port of the old Tauri app's get_stats_summary (omwhisper/src-tauri/src/
    /// history.rs) -- consecutive distinct days including today, walking
    /// backward, stopping at the first gap. "Words today"/"time saved"/
    /// "speaking pace" are new for this dashboard (the old app never computed
    /// them), derived from the real wordCount/durationSeconds columns.
    func homeStats() throws -> HomeStats {
        try dbQueue.read { db in
            let todayRow = try Row.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(wordCount), 0) AS words, COALESCE(SUM(durationSeconds), 0) AS duration
                FROM transcriptions WHERE DATE(createdAt) = DATE('now')
                """
            )
            let wordsToday: Int = todayRow?["words"] ?? 0
            let durationToday: Double = todayRow?["duration"] ?? 0

            let dayRows = try Row.fetchAll(
                db,
                sql: "SELECT DISTINCT DATE(createdAt) AS day FROM transcriptions ORDER BY day DESC"
            )
            let dayStrings: [String] = dayRows.compactMap { $0["day"] }
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.timeZone = TimeZone.current
            let calendar = Calendar.current

            var streak = 0
            var expected = Date()
            for dayString in dayStrings {
                guard let day = dayFormatter.date(from: dayString) else { break }
                if calendar.isDate(day, inSameDayAs: expected) {
                    streak += 1
                    expected = calendar.date(byAdding: .day, value: -1, to: expected) ?? expected
                } else {
                    break
                }
            }

            var last7: [Int] = []
            for offset in stride(from: 6, through: 0, by: -1) {
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(wordCount), 0) AS words FROM transcriptions WHERE DATE(createdAt) = DATE('now', ?)",
                    arguments: ["-\(offset) days"]
                )
                last7.append(row?["words"] ?? 0)
            }

            return HomeStats(wordsToday: wordsToday, durationTodaySeconds: durationToday, streakDays: streak, last7DaysWordCounts: last7)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/HistoryStoreHomeStatsTests -only-testing:omwhisper-nativeTests/HomeStatsDerivedTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS (10/10)

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/History/HistoryStore.swift omwhisper-nativeTests/HistoryStoreTests.swift
git commit -m "feat(hub): add HistoryStore.homeStats() for the Home dashboard"
```

## Task 2: `AppState.rePolish(_:)`

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: existing `private func polishedText(for:) async -> String`.
- Produces: `func rePolish(_ text: String) async -> String` — consumed by Task 3's `HubHomeView`.

No new tests — this is a one-line wrapper around an already-tested-by-usage
private method; nothing new to verify beyond "it compiles and delegates."

- [ ] **Step 1: Add the wrapper**

In `omwhisper-native/AppState.swift`, add directly after `polishedText(for:)`:

```swift
    /// Re-runs a past history entry's text through the current polish
    /// backend/style. Callers copy the result to the clipboard -- this never
    /// pastes into the frontmost app the way live dictation's stop-and-paste
    /// does, since there's no "target app" context for a hub-window action.
    func rePolish(_ text: String) async -> String {
        await polishedText(for: text)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "feat(hub): add AppState.rePolish() for the Home dashboard's recent-row action"
```

## Task 3: Rebuild `HubHomeView`

**Files:**
- Modify: `omwhisper-native/UI/HubHomeView.swift`

**Interfaces:**
- Consumes: `HistoryStore.homeStats()` (Task 1), `AppState.rePolish(_:)` (Task 2), `AppState.historyStore`/`fetchPage(offset:limit:)` (existing), `omCard()`/`Color.Porcelain.*` (D1).
- Produces: the real `HubHomeView` — consumed by `HubShellView`'s existing `.home` case (no change needed there, same type name).

No unit tests — pure SwiftUI view code, matching this project's established
convention (D1's `PorcelainComponents.swift`, D2a's `HubShellView.swift`) —
verified visually once live, not by test.

- [ ] **Step 1: Replace `HubHomeView.swift`**

Replace the full contents of `omwhisper-native/UI/HubHomeView.swift`:

```swift
//
//  HubHomeView.swift
//  OmWhisper
//
//  The real Home dashboard (D3a) -- greeting + streak, three stat cards,
//  a 7-day quiet-reflection bar line, and the last 3 dictations with
//  Copy/Re-polish. See docs/DESIGN_DIRECTION.md §3 and docs/hub-concept.html.
//  Count-up numeral animation and the bar line's "breathing" pulse are
//  deferred to D4 (motion polish) -- this ships correct static values first.
//

import SwiftUI

struct HubHomeView: View {
    @Environment(AppState.self) private var appState

    @State private var stats: HomeStats?
    @State private var recent: [TranscriptionEntry] = []
    @State private var rePolishingID: Int64?
    @State private var copiedID: Int64?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let stats {
                    statCards(stats)
                    weekBar(stats)
                }
                recentSection
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.Porcelain.bg)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)
            Text(streakSentence)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Porcelain.dim)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12: "Good morning."
        case 12..<18: "Good afternoon."
        default: "Good evening."
        }
    }

    private var streakSentence: String {
        guard let stats else { return " " }
        switch stats.streakDays {
        case 0: "Press ⌘⇧V to start dictating."
        case 1: "You've dictated today — nice start."
        default: "You've spoken instead of typed for \(stats.streakDays) days straight."
        }
    }

    // MARK: Stat cards

    private func statCards(_ stats: HomeStats) -> some View {
        HStack(spacing: 14) {
            statCard(label: "WORDS TODAY", value: "\(stats.wordsToday)")
            statCard(label: "TIME SAVED", value: "\(stats.minutesSavedVsTyping)", suffix: "min")
            statCard(label: "SPEAKING PACE", value: "\(stats.speakingPaceWPM)", suffix: "wpm")
        }
    }

    private func statCard(label: String, value: String, suffix: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Porcelain.dim)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.Porcelain.numeralGradient)
                if let suffix {
                    Text(suffix)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.Porcelain.dim)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omCard()
    }

    // MARK: 7-day bar

    private func weekBar(_ stats: HomeStats) -> some View {
        let maxCount = max(stats.last7DaysWordCounts.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(stats.last7DaysWordCounts.enumerated()), id: \.offset) { _, count in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.Porcelain.emerald.opacity(count == 0 ? 0.12 : 0.55))
                    .frame(height: max(4, 34 * Double(count) / Double(maxCount)))
            }
        }
        .frame(height: 34, alignment: .bottom)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omCard()
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)
            if recent.isEmpty {
                Text("Nothing dictated yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Porcelain.dim)
            } else {
                VStack(spacing: 8) {
                    ForEach(recent) { entry in
                        recentRow(entry)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    private func recentRow(_ entry: TranscriptionEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .foregroundStyle(Color.Porcelain.emerald)
                .frame(width: 28, height: 28)
                .background(Color.Porcelain.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.Porcelain.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(entry.polishStyle ?? entry.source) · \(relativeTime(entry.createdAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Porcelain.dim)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(copiedID == entry.id ? "Copied" : "Copy") { copy(entry) }
                Button(rePolishingID == entry.id ? "Polishing…" : "Re-polish") {
                    Task { await rePolish(entry) }
                }
                .disabled(rePolishingID == entry.id)
            }
            .font(.system(size: 11.5))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.Porcelain.mint)
        }
        .padding(12)
        .omCard()
    }

    private func relativeTime(_ iso8601: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Data

    private func load() async {
        guard let store = appState.historyStore else { return }
        do {
            stats = try store.homeStats()
            recent = try store.fetchPage(offset: 0, limit: 3)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copy(_ entry: TranscriptionEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedID = entry.id
    }

    private func rePolish(_ entry: TranscriptionEntry) async {
        rePolishingID = entry.id
        let result = await appState.rePolish(entry.rawText ?? entry.text)
        rePolishingID = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        copiedID = entry.id
    }
}

#Preview {
    HubHomeView().environment(AppState())
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/HubHomeView.swift
git commit -m "feat(hub): build the real Home dashboard (D3a)"
```

## Task 4: Full verification pass + docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED, all tests pass (existing 205 + 10 new `HistoryStoreHomeStatsTests`/`HomeStatsDerivedTests` = 215).

- [ ] **Step 2: Update `CLAUDE.md`'s D1–D4 Progress Tracker row**

Update the status cell to `🔶 D1 + D2 + D3a shipped, D3b–D4 not started`.
Append a new paragraph covering: D3a shipped 2026-07-10 per
`docs/superpowers/plans/2026-07-10-d3a-home-dashboard.md`, executed inline (4
tasks) in `.worktrees/d3a-home-dashboard` — D3 split into D3a (this, the Home
dashboard) and D3b (the menu-bar mini-panel), since the two share no code and
have entirely different mechanics (SwiftUI content pane vs. `NSPopover` on
the status item). `HistoryStore.homeStats()` (new): `wordsToday`/
`durationTodaySeconds` (today's sums), `streakDays` (a direct port of the old
Tauri app's `get_stats_summary` streak algorithm — read `omwhisper/src-tauri/src/
history.rs` directly rather than guessing, since the old app's stats card
turned out to be much simpler than the new mockup: totals/today's count/streak
only, no words-today sum, no wpm, no time-saved, no 7-day bar — those four are
new computations for this dashboard, designed from the real `wordCount`/
`durationSeconds` columns, not carried over from anywhere), `last7DaysWordCounts`
(a 7-entry array for the quiet-reflection bar line). `HomeStats` also carries
two pure computed properties (`speakingPaceWPM`, `minutesSavedVsTyping`,
clamped to never go negative) kept separate from the DB query so they're
directly unit-testable without I/O. 10 new tests (`HistoryStoreHomeStatsTests`
— real GRDB round-trips backdating `createdAt` by reusing
`HistoryStoreTests.swift`'s own existing `seed()` helper rather than adding
any new production API, since that file already solved exactly this need;
`HomeStatsDerivedTests` — pure arithmetic, no DB), all passing (215 total in
the full suite). `AppState.rePolish(_:)` (new, one line):
reuses the exact same fallback-safe `polishedText(for:)` the live dictation
path already calls — Home's "Re-polish" row action copies the result to the
clipboard rather than pasting into the frontmost app, since sitting in the hub
window gives no meaningful "target app" the way live dictation's stop-and-paste
has. `HubHomeView.swift` rebuilt from D2a's placeholder into the real
dashboard: time-of-day greeting (no user-name setting exists in this app, so
it's nameless — "Good morning."/"Good afternoon."/"Good evening."), a
streak-days-aware sentence (0/1/N-days-straight get three different lines),
three `omCard()` stat cards with `Color.Porcelain.numeralGradient` numerals,
the 7-day bar (static heights — the mockup's pulsing `breathebar` animation is
explicitly D4's job), and the last 3 dictations via the already-existing
`fetchPage(offset:limit:)` with Copy/Re-polish actions. One real schema gap
found and resolved, not silently worked around: `TranscriptionEntry` has no
"destination app" field, so `hub-concept.html`'s per-row app icon (💬/✉️/📝)
has no backing data — recent rows show a generic icon + the entry's polish
style/source instead, rather than adding a new column (real schema/importer
scope, out of bounds for a dashboard task). **Not yet live-verified** — like
D1/D2, nobody has actually opened the hub and looked at Home with real
dictation history behind it in this pass; whether the stat card layout, the
7-day bar's proportions, and the streak sentence read naturally with real
numbers (not just the unit tests' synthetic ones) are all open until then.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: mark D3a (Home dashboard) shipped"
```
