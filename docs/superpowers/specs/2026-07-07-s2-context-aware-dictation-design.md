# Design: S2 — Context-Aware Dictation

> Written 2026-07-07. Brainstormed via `superpowers:brainstorming`. Implements the
> "S2 — Context-aware dictation" milestone from `docs/SMRITI_INTEGRATION_PLAN.md`
> (the ⭐ headline feature, confirmed "M2 finishes first" in that doc's Order
> section — M2 is now code-complete apart from Sparkle's key generation and
> onboarding, both explicitly deferred, so S2 proceeds).

## Goal

On dictation start, read the frontmost window's visible text via the Accessibility
API, extract salient terms (proper nouns, code identifiers, rare/technical words),
and feed them into the transcription engine's vocabulary biasing — alongside the
user's own `customVocabulary` — so dictating names/jargon visible on screen gets
transcribed correctly without the user having to pre-type them into Settings.

Works without S1 (memory core) — a single on-demand AX read per session, nothing
stored, nothing sent anywhere. Off by default, per the project's privacy contract
for every Smriti-derived feature.

## Reference: Smriti's existing implementation

Investigated directly from `/Users/rakeshkusuma/Documents/PersonalProjects/smriti`
(same author, MIT, read-only reference per the integration plan):

- `Sources/SmritiKit/AXReader.swift` — `AXReader.captureFrontmost(timeBudget:)` walks
  the frontmost app's focused window via `AXUIElementCreateApplication` /
  `AXUIElementCopyAttributeValue`, collecting text from a fixed set of text-bearing
  roles (`AXStaticText`, `AXTextArea`, `AXTextField`, `AXLink`, `AXHeading`, `AXCell`,
  `AXMenuItem`, `AXButton`), depth-capped at 40, deadline-checked throughout (default
  budget 2.0s), character-budgeted at 50,000. Returns `nil` when there's nothing
  meaningful.
- `Sources/SmritiKit/BrowserURL.swift` — resolves the active tab's URL for a fixed
  set of browser bundle IDs, via `AXWebArea`'s `AXURL` or an address-bar fallback.
  Not used by S2 directly (no domain-exclusion list in this pass — see Scope) but
  ported alongside `AXReader` since the two are used together upstream.
- `Sources/SmritiKit/Redactor.swift` — regex-based secret/PII scrubber. **Not
  applied in this pass** — see Scope.
- `Sources/SmritiKit/Config.swift` — `Config.defaults.excludedBundleIds` =
  `["com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password",
  "com.agilebits.onepassword7"]`; `excludedTitleSubstrings` = `["Private Browsing",
  "Incognito"]`. Reused verbatim as this pass's hardcoded exclusion list.

No existing "salient term extraction" logic exists in Smriti — Smriti stores raw
snapshot text for FTS5 full-text search, not keyterm extraction for ASR biasing.
The three-category extraction (proper nouns / code identifiers / rare words) is new
to this integration.

## Scope for this pass

In scope: on-demand AX read of the frontmost window at dictation start, salient-term
extraction, merging into the existing `TranscriptionEngine.transcribe(_:vocabulary:)`
parameter, a single Settings toggle.

Explicitly **not** in scope, decided during brainstorming:

- **No storage.** Nothing captured here is written to disk (that's S1's job, a
  separate, bigger trust ask that comes later per the plan doc's ordering).
- **No redaction pass.** Matches Smriti's own philosophy — `Redactor` exists to guard
  egress to third-party cloud infrastructure, not local processing. Only
  `AppleEngine` (fully on-device) consumes this vocabulary today. **Must be
  revisited when M4's `CloudEngine` starts consuming `vocabulary:`** — a cloud
  keyterm-biasing call is exactly the egress case `Redactor` was built for.
- **No exclusion-list UI.** The hardcoded list above ships as-is; a Settings UI for
  customizing it is a future addition if it turns out to matter.
- **No domain-based browser exclusions.** `BrowserURL` is ported for URL resolution
  (useful context for future work) but S2 doesn't act on it — no per-domain
  exclusion list in this pass, matching "no exclusion-list UI" above.
- **No live mid-session vocabulary updates.** `TranscriptionEngine.transcribe`
  reads `vocabulary` once per session (existing contract, unchanged) — extracted
  terms bias the whole session or not at all, no "update partway through" mechanism.

## Architecture

New `Context/` group, following the existing collaborator pattern (`History/`,
`Vocabulary/`).

### `Context/ScreenContextReader.swift`

Ports `AXReader.swift` + `BrowserURL.swift` with a Swift 6 concurrency pass —
`nonisolated`, matching `AudioCapture`'s rationale (real AX/IPC work has no MainActor
affinity and must run off the main thread without an actor hop).

```swift
nonisolated enum ScreenContextReader {
    static let excludedBundleIDs: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7",
    ]
    static let excludedTitleSubstrings = ["Private Browsing", "Incognito"]

    /// nil when there's nothing meaningful, the app/window is excluded, or the
    /// walk hits its deadline before finding anything. Never throws.
    static func captureFrontmostWindowText(timeBudget: TimeInterval = 0.6) -> String?
}
```

Internals ported near-verbatim from `AXReader.captureFrontmost`: same text-bearing
role set, same depth/character/deadline budgets, just the tighter default budget
(0.6s vs Smriti's 2.0s — see Timing below) and an exclusion check (bundle ID +
window title substring, both from the list above) before the tree walk starts.

### `Context/SalientTermExtractor.swift`

Three independently-testable pure functions, each mapped to the technique that's
actually good at that category — not a single one-size-fits-all pass:

```swift
nonisolated enum SalientTermExtractor {
    /// NLTagger .nameType (PersonalName/PlaceName/OrganizationName) — Apple's
    /// on-device NER, no bundled model, better precision than a capitalization
    /// heuristic (which false-positives on sentence-initial words).
    static func properNouns(in text: String) -> [String]

    /// Regex: camelCase, PascalCase, snake_case, dotted.paths. NLTagger's NER
    /// doesn't recognize these as "names" at all.
    static func codeIdentifiers(in text: String) -> [String]

    /// NSSpellChecker: tokens the system dictionary doesn't recognize. A free,
    /// already-available proxy for "rare/technical" without a bundled corpus.
    static func rareWords(in text: String) -> [String]

    /// Merges all three, case-insensitive dedupe, caps at `limit`.
    static func extractSalientTerms(from text: String, limit: Int = 30) -> [String]
}
```

### `AppState` integration

- New setting, same pattern as existing ones:
  ```swift
  var contextAwareDictationEnabled: Bool {
      get { UserDefaults.standard.object(forKey: SettingsKeys.contextAwareDictationEnabled) as? Bool ?? false }
      set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.contextAwareDictationEnabled) }
  }
  ```
- New private property: `private var contextCaptureTask: Task<[String], Never>?`.
- New `nonisolated` helper, matching `runHistoryStartupTasks`'s rationale — the
  `Task` it creates must run on the cooperative thread pool, not MainActor, or the
  AX walk blocks the very thread it's meant to run *alongside*, not after.
  `enabled` is a plain `Bool` parameter, not read from `AppState` inside the
  nonisolated body, for the same reason `vocabSnapshot`/`replacementsSnapshot`/
  `fuzzySnapshot` are already read on MainActor and passed by value into
  `startDictation()`'s transcription `Task` — `contextAwareDictationEnabled` is a
  MainActor-isolated computed property and can't be read from a nonisolated
  context directly:
  ```swift
  nonisolated private func startContextCapture(enabled: Bool) -> Task<[String], Never>? {
      guard enabled else { return nil }
      return Task {
          ScreenContextReader.captureFrontmostWindowText()
              .map { SalientTermExtractor.extractSalientTerms(from: $0) } ?? []
      }
  }
  ```
- In `toggleDictation()`'s `.idle` case and `beginPushToTalk()` — the same two
  places `dictation = .starting` is claimed synchronously — call it:
  ```swift
  contextCaptureTask = startContextCapture(enabled: contextAwareDictationEnabled)
  ```
- In `startDictation()`, right before `engine.transcribe(...)`. Screen-extracted
  terms feed **only** the engine's biasing, not `vocabSnapshot` itself —
  `vocabSnapshot` also doubles as `fuzzyCorrect`'s post-hoc snap-to-nearest-term
  dictionary (a harder rewrite than soft engine biasing), and mixing noisy
  auto-extracted terms into that path is a different risk profile the plan doc
  didn't ask for ("merge with user vocabulary → `AnalysisContext.contextualStrings`
  / engine keyterms" — engine biasing specifically). So `vocabSnapshot` (used for
  both `engine.transcribe` and `fuzzyCorrect`) stays exactly as it is today —
  `customVocabulary` alone — and a second, engine-only value is merged in:
  ```swift
  let screenTerms = await contextCaptureTask?.value ?? []
  let engineVocabulary = vocabSnapshot + screenTerms.filter { term in
      !vocabSnapshot.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
  }
  let events = engine.transcribe(audioStream, vocabulary: engineVocabulary)
  ```
- `contextCaptureTask = nil` reset alongside the existing `pttPressedAt`/
  `recordingStartedAt` resets at the end of `stopDictation()`.

## Timing

The capture `Task` starts at the earliest possible instant (same moment as the
overlay's early-show, before permission checks or `audioCapture.start()`) and runs
concurrently with them on the cooperative thread pool. It's awaited only once,
immediately before `engine.transcribe(...)` — bounded by `ScreenContextReader`'s own
0.6s internal deadline, no separate outer timeout needed.

0.6s (not Smriti's 2.0s default) because this sits on the critical path to
first-partial latency (sign-off criterion #1, already the app's weakest-measured
metric per `CLAUDE.md`) even in the best case — "concurrent" only means it overlaps
with other startup work, which is typically much faster than 2s once permissions are
already granted. A capped-but-real chance of finishing in time beats either an
unbounded wait or skipping the read outright.

## Settings

Toggle added to `VocabularySettingsView` (folded in, not a new tab — same
`contextualStrings`/engine-biasing mechanism as `customVocabulary` and
`wordReplacements`): "Use On-Screen Context", off by default, with a one-line
caption explaining what it reads and that nothing is stored. No new Accessibility
prompt — reuses the grant `PasteService` already requests at launch.

## Error handling

Every failure mode (Accessibility not granted, no focused window, excluded
app/window, deadline exceeded, empty extraction result) resolves the capture task to
`[]` — never throws, never blocks dictation beyond the 0.6s budget, never surfaces
an error to the user. Purely additive: with the setting off (the default), this
entire path is skipped and behavior is identical to today.

## Testing

- **`SalientTermExtractorTests.swift`** (Swift Testing) — `properNouns(in:)` on
  sample sentences (names amid ordinary text, sentence-initial words correctly
  *not* flagged); `codeIdentifiers(in:)` on sample tokens (camelCase, snake_case,
  PascalCase, dotted paths, plus ordinary words correctly *not* matched);
  `rareWords(in:)` edge cases (common words excluded, invented/technical terms
  included); `extractSalientTerms(from:limit:)` merge/dedupe/cap behavior.
- **Exclusion matching** — `ScreenContextReader`'s bundle-ID/title-substring checks
  are pure and tested separately from the AX walk itself.
- **`ScreenContextReader`'s actual AX tree walk is not unit-tested** — hardware/
  permission-dependent, matching the project's existing convention (`AudioCapture`,
  `PasteService` have no tests either). Verified live instead: real AX read against
  a real frontmost window, confirming extracted terms actually change the
  transcription engine's vocabulary snapshot for a real dictation session.
