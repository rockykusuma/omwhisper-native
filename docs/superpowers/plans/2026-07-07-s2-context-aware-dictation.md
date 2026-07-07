# S2 — Context-Aware Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On dictation start, read the frontmost window's visible text, extract salient terms (proper nouns, code identifiers, rare/technical words), and merge them into the engine's vocabulary biasing — off by default, no storage, no added latency in the common case.

**Architecture:** Two new pure(ish)-logic files in a new `Context/` group — `SalientTermExtractor` (fully pure/testable term extraction) and `ScreenContextReader` (AX tree walk, ported from the `smriti` reference repo, with a testable exclusion-check and an untestable-by-design hardware-dependent walk). `AppState` fires the capture concurrently with dictation startup and awaits it right before calling the transcription engine.

**Tech Stack:** Swift 6, NaturalLanguage (NLTagger, proper-noun NER), AppKit (NSSpellChecker, rare-word detection), ApplicationServices (AXUIElement, screen reading) — all system frameworks already available, no new dependencies.

## Global Constraints

- Off by default (`contextAwareDictationEnabled` defaults to `false`) — every Smriti-derived feature in this project ships off by default.
- No storage — nothing captured here is written to disk.
- No redaction pass in this pass — deferred to when M4's `CloudEngine` starts consuming `vocabulary:` (see spec's Scope section).
- `ScreenContextReader`'s AX walk budget is 0.6s (not Smriti's 2.0s default) — it sits on the critical path to first-partial latency.
- Screen-extracted terms feed **only** `engine.transcribe`'s `vocabulary:` parameter, never `fuzzyCorrect`'s dictionary (`vocabSnapshot` stays `customVocabulary` alone, unchanged from today).
- Deviation from the spec: `BrowserURL.swift` is **not** ported in this plan. The spec listed it as "ported alongside AXReader" for future use, but nothing in S2 actually calls it (no domain-exclusion list in this pass) — porting an unused file is scope creep the spec shouldn't have included. `ScreenContextReader.swift` is self-contained.
- Reference source: `/Users/rakeshkusuma/Documents/PersonalProjects/smriti/Sources/SmritiKit/AXReader.swift` and `Config.swift` (read-only reference, MIT, same author — attribution noted in the new file's header).
- Full spec: `docs/superpowers/specs/2026-07-07-s2-context-aware-dictation-design.md`.

---

### Task 1: SalientTermExtractor — proper nouns, code identifiers, rare words

**Files:**
- Create: `omwhisper-native/Context/SalientTermExtractor.swift`
- Test: `omwhisper-nativeTests/SalientTermExtractorTests.swift`

**Interfaces:**
- Produces: `SalientTermExtractor.properNouns(in: String) -> [String]`, `SalientTermExtractor.codeIdentifiers(in: String) -> [String]`, `SalientTermExtractor.rareWords(in: String) -> [String]` (both `nonisolated`), and `@MainActor SalientTermExtractor.rareWords(in: String) -> [String]`, `SalientTermExtractor.extractSalientTerms(from: String, limit: Int = 30) async -> [String]` (`nonisolated`, `async` because it awaits the `@MainActor` `rareWords`). These four functions are the only public surface Task 3 (`AppState` wiring) depends on.

- [ ] **Step 1: Write the failing tests for `properNouns(in:)`**

Create `omwhisper-nativeTests/SalientTermExtractorTests.swift`:

```swift
//
//  SalientTermExtractorTests.swift
//  omwhisper-nativeTests
//

import Testing
@testable import OmWhisper

struct SalientTermExtractorTests {
    @Test func detectsPersonalPlaceAndOrgNames() {
        let text = "I met Sarah Connor at Google headquarters in London."
        let names = SalientTermExtractor.properNouns(in: text)
        #expect(names.contains("Sarah Connor"))
        #expect(names.contains("Google"))
        #expect(names.contains("London"))
    }

    @Test func ordinaryWordsNotFlaggedAsNames() {
        let text = "The quick brown fox jumps over the lazy dog."
        let names = SalientTermExtractor.properNouns(in: text)
        #expect(names.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SalientTermExtractorTests 2>&1 | tail -30`
Expected: FAIL — `Cannot find 'SalientTermExtractor' in scope` (compile error is the expected RED state here, same as every other new-type test in this codebase's history — see `HistoryStoreTests`).

- [ ] **Step 3: Create the file with `properNouns(in:)` only**

Create `omwhisper-native/Context/SalientTermExtractor.swift`:

```swift
//
//  SalientTermExtractor.swift
//  OmWhisper
//
//  Extracts salient terms (proper nouns, code identifiers, rare/technical words)
//  from on-screen text for engine vocabulary biasing (S2). Three techniques, one
//  per category — not a single one-size-fits-all pass. New to this integration;
//  Smriti itself only stores raw text for FTS5 search, no keyterm extraction.
//

import AppKit
import Foundation
import NaturalLanguage

nonisolated enum SalientTermExtractor {
    /// NLTagger .nameType (PersonalName/PlaceName/OrganizationName) — Apple's
    /// on-device NER, better precision than a capitalization heuristic (which
    /// false-positives on every sentence-initial word).
    static func properNouns(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var results: [String] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, tag == .personalName || tag == .placeName || tag == .organizationName {
                results.append(String(text[range]))
            }
            return true
        }
        return results
    }
}
```

- [ ] **Step 4: Run tests to verify `properNouns` tests pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SalientTermExtractorTests 2>&1 | tail -30`
Expected: `detectsPersonalPlaceAndOrgNames` and `ordinaryWordsNotFlaggedAsNames` PASS (the other test functions referenced below don't exist yet, so limit to these two with `-only-testing` filters on the class only — both should now compile and pass; if NLTagger doesn't tag "Sarah Connor"/"Google"/"London" as expected on this specific sentence, adjust the example sentence to one that does, verified via this same run — don't hand-wave past an actual failure here).

- [ ] **Step 5: Commit**

```bash
cd /Users/rakeshkusuma/Documents/PersonalProjects/omwhisper-native
git add omwhisper-native/Context/SalientTermExtractor.swift omwhisper-nativeTests/SalientTermExtractorTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(context): add SalientTermExtractor.properNouns

First piece of S2 (context-aware dictation) — NLTagger-based proper noun
detection (personal/place/organization names), on-device NER.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: Write the failing tests for `codeIdentifiers(in:)`**

Append to `omwhisper-nativeTests/SalientTermExtractorTests.swift` (inside the `SalientTermExtractorTests` struct, after the two existing tests):

```swift
    @Test func detectsCamelCaseAndSnakeCaseAndDottedIdentifiers() {
        let text = "Please call getUserById to fetch the record, then check max_retry_count and see com.example.Foo for details."
        let identifiers = SalientTermExtractor.codeIdentifiers(in: text)
        #expect(identifiers.contains("getUserById"))
        #expect(identifiers.contains("max_retry_count"))
        #expect(identifiers.contains("com.example.Foo"))
    }

    @Test func detectsAcronymPrefixedPascalCase() {
        let text = "The class NSAttributedString handles rich text and URLSession handles networking."
        let identifiers = SalientTermExtractor.codeIdentifiers(in: text)
        #expect(identifiers.contains("NSAttributedString"))
        #expect(identifiers.contains("URLSession"))
    }

    @Test func ordinaryWordsNotFlaggedAsCodeIdentifiers() {
        let text = "This is a normal sentence with no code in it."
        let identifiers = SalientTermExtractor.codeIdentifiers(in: text)
        #expect(identifiers.isEmpty)
    }
```

- [ ] **Step 7: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SalientTermExtractorTests 2>&1 | tail -40`
Expected: FAIL — `Cannot find 'codeIdentifiers' in scope`.

- [ ] **Step 8: Add `codeIdentifiers(in:)`**

Add to `omwhisper-native/Context/SalientTermExtractor.swift`, inside the `SalientTermExtractor` enum, after `properNouns`:

```swift
    /// Regex: camelCase, PascalCase (including acronym-prefixed like NSFoo/URLSession),
    /// snake_case, dotted.paths. NLTagger's NER doesn't recognize any of these as
    /// "names" — this is why proper nouns and code identifiers are separate passes.
    static func codeIdentifiers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: codeIdentifierPattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range) }
    }

    /// Alternative 1: snake_case / dotted.path (has an internal `_`/`.` separator).
    /// Alternative 2: mixed-case with a real case transition — either a lowercase-
    /// to-uppercase "hump" (getUserById, iPhone) or an acronym-to-word boundary
    /// (NSAttributedString, URLSession). Plain capitalized words like "Hello" have
    /// exactly one uppercase letter with nothing before it to transition from, so
    /// they don't match either branch.
    private static let codeIdentifierPattern =
        #"\b[A-Za-z]+(?:[_.][A-Za-z0-9]+)+\b|\b(?=[A-Za-z0-9]*(?:[a-z][A-Z]|[A-Z]{2,}[a-z]))[A-Za-z][A-Za-z0-9]*\b"#
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SalientTermExtractorTests 2>&1 | tail -40`
Expected: All 5 tests so far PASS. If `detectsAcronymPrefixedPascalCase` fails, verify with `swift -e` or a scratch file that the regex's `[A-Z]{2,}[a-z]` lookahead branch actually matches "NSAttributedString"/"URLSession" before changing the test — the pattern is designed to catch this shape (see the code comment above), so a failure here means the regex needs a fix, not the test.

- [ ] **Step 10: Commit**

```bash
git add omwhisper-native/Context/SalientTermExtractor.swift omwhisper-nativeTests/SalientTermExtractorTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(context): add SalientTermExtractor.codeIdentifiers

Regex-based camelCase/PascalCase/snake_case/dotted.path detection,
including acronym-prefixed identifiers (NSFoo, URLSession) via a
case-transition lookahead rather than an enumerated pattern list.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 11: Write the failing tests for `rareWords(in:)`**

Append to `omwhisper-nativeTests/SalientTermExtractorTests.swift`:

```swift
    @Test func detectsRareWords() async {
        let words = await SalientTermExtractor.rareWords(in: "I really enjoyed the Kubernetes deployment")
        #expect(words.contains("Kubernetes"))
    }

    @Test func commonWordsNotFlaggedAsRare() async {
        let words = await SalientTermExtractor.rareWords(in: "the quick brown fox jumps over the lazy dog")
        #expect(words.isEmpty)
    }
```

- [ ] **Step 12: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SalientTermExtractorTests 2>&1 | tail -40`
Expected: FAIL — `Cannot find 'rareWords' in scope`.

- [ ] **Step 13: Add `rareWords(in:)`**

Add to `omwhisper-native/Context/SalientTermExtractor.swift`, inside the `SalientTermExtractor` enum, after `codeIdentifiers`:

```swift
    /// @MainActor: NSSpellChecker is an AppKit API with main-thread affinity —
    /// unlike properNouns/codeIdentifiers (pure Foundation, safe from anywhere),
    /// this one specifically needs the hop. Anything the system dictionary
    /// doesn't recognize is a free, already-available proxy for "rare/technical"
    /// without bundling a word-frequency corpus.
    @MainActor static func rareWords(in text: String) -> [String] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var results: [String] = []
        var offset = 0
        while offset < ns.length {
            let misspelled = checker.checkSpelling(of: text, startingAt: offset)
            guard misspelled.location != NSNotFound else { break }
            let word = ns.substring(with: misspelled)
            if word.count >= 4 {
                results.append(word)
            }
            offset = misspelled.location + misspelled.length
        }
        return results
    }
```

- [ ] **Step 14: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SalientTermExtractorTests 2>&1 | tail -40`
Expected: All 7 tests so far PASS.

- [ ] **Step 15: Commit**

```bash
git add omwhisper-native/Context/SalientTermExtractor.swift omwhisper-nativeTests/SalientTermExtractorTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(context): add SalientTermExtractor.rareWords

NSSpellChecker-based detection of system-dictionary-unrecognized
words as a proxy for rare/technical terms. @MainActor — NSSpellChecker
has main-thread affinity, unlike the two pure Foundation-based passes.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 16: Write the failing tests for `extractSalientTerms(from:limit:)`**

Append to `omwhisper-nativeTests/SalientTermExtractorTests.swift`:

```swift
    @Test func combinesAllThreeCategories() async {
        let text = "Sarah Connor uses getUserById in her Kubernetes cluster."
        let terms = await SalientTermExtractor.extractSalientTerms(from: text)
        #expect(terms.contains("Sarah Connor"))
        #expect(terms.contains("getUserById"))
        #expect(terms.contains("Kubernetes"))
    }

    @Test func dedupesCaseInsensitively() async {
        let text = "getUserById GetUserById"
        let terms = await SalientTermExtractor.extractSalientTerms(from: text)
        let matching = terms.filter { $0.caseInsensitiveCompare("getUserById") == .orderedSame }
        #expect(matching.count == 1)
    }

    @Test func respectsLimit() async {
        let text = (1...50).map { "properNoun\($0) getFunctionCall\($0)" }.joined(separator: " ")
        let terms = await SalientTermExtractor.extractSalientTerms(from: text, limit: 5)
        #expect(terms.count <= 5)
    }
```

- [ ] **Step 17: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SalientTermExtractorTests 2>&1 | tail -50`
Expected: FAIL — `Cannot find 'extractSalientTerms' in scope`.

- [ ] **Step 18: Add `extractSalientTerms(from:limit:)`**

Add to `omwhisper-native/Context/SalientTermExtractor.swift`, inside the `SalientTermExtractor` enum, after `rareWords`:

```swift
    /// Merges all three categories, case-insensitive dedupe (first-seen casing
    /// wins), capped at `limit` — kept separate from the user's own
    /// customVocabulary, which is never trimmed.
    static func extractSalientTerms(from text: String, limit: Int = 30) async -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        let candidates = properNouns(in: text) + codeIdentifiers(in: text) + (await rareWords(in: text))
        for term in candidates {
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(term)
            if results.count >= limit { break }
        }
        return results
    }
```

- [ ] **Step 19: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/SalientTermExtractorTests 2>&1 | tail -50`
Expected: All 10 tests PASS.

- [ ] **Step 20: Run the full test suite to confirm no regressions**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: `Test run with 61 tests in 8 suites passed` (51 existing + 10 new), `** TEST SUCCEEDED **`.

- [ ] **Step 21: Commit**

```bash
git add omwhisper-native/Context/SalientTermExtractor.swift omwhisper-nativeTests/SalientTermExtractorTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(context): add SalientTermExtractor.extractSalientTerms

Combines proper nouns + code identifiers + rare words, case-insensitive
dedupe, capped at 30 by default. This is the single entry point AppState
will call — Task 1 of S2 (context-aware dictation) complete.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: ScreenContextReader — exclusions + AX tree walk

**Files:**
- Create: `omwhisper-native/Context/ScreenContextReader.swift`
- Test: `omwhisper-nativeTests/ScreenContextReaderTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (independent).
- Produces: `ScreenContextReader.isExcluded(bundleID: String, windowTitle: String) -> Bool`, `ScreenContextReader.captureFrontmostWindowText(timeBudget: TimeInterval = 0.6) -> String?` (both `nonisolated`). Task 3 (`AppState` wiring) calls `captureFrontmostWindowText()`.

- [ ] **Step 1: Write the failing tests for `isExcluded(bundleID:windowTitle:)`**

Create `omwhisper-nativeTests/ScreenContextReaderTests.swift`:

```swift
//
//  ScreenContextReaderTests.swift
//  omwhisper-nativeTests
//

import Testing
@testable import OmWhisper

struct ScreenContextReaderTests {
    @Test func excludesKnownPasswordManagers() {
        #expect(ScreenContextReader.isExcluded(bundleID: "com.1password.1password", windowTitle: "Vault"))
        #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.Passwords", windowTitle: "Passwords"))
    }

    @Test func excludesPrivateBrowsingByTitle() {
        #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.Safari", windowTitle: "Private Browsing"))
        #expect(ScreenContextReader.isExcluded(bundleID: "com.google.Chrome", windowTitle: "New Incognito Tab"))
    }

    @Test func allowsOrdinaryApps() {
        #expect(!ScreenContextReader.isExcluded(bundleID: "com.apple.TextEdit", windowTitle: "Untitled"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/ScreenContextReaderTests 2>&1 | tail -30`
Expected: FAIL — `Cannot find 'ScreenContextReader' in scope`.

- [ ] **Step 3: Create the file with exclusion checking + the AX walk**

Create `omwhisper-native/Context/ScreenContextReader.swift`:

```swift
//
//  ScreenContextReader.swift
//  OmWhisper
//
//  On-demand read of the frontmost window's visible text via the macOS
//  Accessibility API, for S2 (context-aware dictation). Ported from
//  github.com/rockykusuma/smriti (same author, MIT) — Sources/SmritiKit/
//  AXReader.swift — with a Swift 6 concurrency pass and a tighter time budget
//  (0.6s vs Smriti's 2.0s default; this sits on the critical path to
//  first-partial latency, unlike Smriti's background daemon use). Exclusion
//  defaults (excludedBundleIDs/excludedTitleSubstrings) match Smriti's
//  Config.defaults verbatim.
//
//  nonisolated: AXUIElement calls are cross-process IPC with no MainActor
//  affinity, same rationale as AudioCapture — must run off the main thread
//  without an actor hop (see AppState concurrency note in CLAUDE.md).
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum ScreenContextReader {
    static let excludedBundleIDs: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7",
    ]
    static let excludedTitleSubstrings = ["Private Browsing", "Incognito"]

    static func isExcluded(bundleID: String, windowTitle: String) -> Bool {
        if excludedBundleIDs.contains(bundleID) { return true }
        return excludedTitleSubstrings.contains { windowTitle.localizedCaseInsensitiveContains($0) }
    }

    /// nil when there's nothing meaningful, the app/window is excluded, or the
    /// walk hits its deadline before finding anything. Never throws.
    static func captureFrontmostWindowText(timeBudget: TimeInterval = 0.6) -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        let windowElement = window as! AXUIElement

        let title = (copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        guard !isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }

        var lines: [String] = []
        var budget = 50_000
        let deadline = Date().addingTimeInterval(timeBudget)
        collectText(windowElement, depth: 0, into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    // MARK: - Tree walking (ported near-verbatim from AXReader.collectText)

    private static let textBearingRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole,
        "AXLink", "AXHeading", "AXCell", "AXMenuItem", "AXButton",
    ]

    private static func collectText(
        _ element: AXUIElement,
        depth: Int,
        into lines: inout [String],
        budget: inout Int,
        deadline: Date
    ) {
        guard depth < 40, budget > 0, Date() < deadline else { return }

        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""

        if textBearingRoles.contains(role) {
            if let value = copyAttribute(element, kAXValueAttribute) as? String, !value.isEmpty {
                append(value, to: &lines, budget: &budget)
            } else if let title = copyAttribute(element, kAXTitleAttribute) as? String,
                      !title.isEmpty, role != kAXButtonRole {
                append(title, to: &lines, budget: &budget)
            }
        }

        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            guard budget > 0, Date() < deadline else { return }
            collectText(child, depth: depth + 1, into: &lines, budget: &budget, deadline: deadline)
        }
    }

    private static func append(_ text: String, to lines: inout [String], budget: inout Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clipped = String(trimmed.prefix(budget))
        lines.append(clipped)
        budget -= clipped.count
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test -only-testing:omwhisper-nativeTests/ScreenContextReaderTests 2>&1 | tail -30`
Expected: All 3 tests PASS.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: `Test run with 64 tests in 9 suites passed` (61 from Task 1 + 3 new), `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Context/ScreenContextReader.swift omwhisper-nativeTests/ScreenContextReaderTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(context): add ScreenContextReader

Ports Smriti's AXReader.swift (frontmost-window AX tree walk) with a
Swift 6 concurrency pass and a 0.6s budget (vs Smriti's 2.0s — this sits
on the critical path to first-partial latency). Exclusion defaults
(password managers, private/incognito browsing) match Smriti's
Config.defaults verbatim. The AX walk itself isn't unit-tested
(hardware/permission-dependent, matching AudioCapture/PasteService's
existing no-test convention) — only isExcluded, which is pure.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: AppState wiring

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `SalientTermExtractor.extractSalientTerms(from:limit:) async -> [String]` (Task 1), `ScreenContextReader.captureFrontmostWindowText(timeBudget:) -> String?` (Task 2).
- Produces: `AppState.contextAwareDictationEnabled: Bool` (new setting Task 4's UI reads/writes).

This task is integration wiring calling already-tested functions — no new pure logic to unit-test in isolation, so its "test cycle" is build success + the full existing suite staying green, followed by live verification in Task 5. This matches how every other `AppState` integration this session (History, Sparkle, Audio settings) was actually verified.

- [ ] **Step 1: Add the `contextAwareDictationEnabled` setting**

In `omwhisper-native/AppState.swift`, find:

```swift
    var fuzzyVocabCorrection: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.fuzzyVocabCorrection) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.fuzzyVocabCorrection) }
    }
    /// SMAppService is itself the source of truth (macOS's login-item registry) —
```

Replace with:

```swift
    var fuzzyVocabCorrection: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.fuzzyVocabCorrection) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.fuzzyVocabCorrection) }
    }
    /// Off by default — every Smriti-derived feature in this project ships off
    /// by default. Reads the frontmost window's visible text at dictation start
    /// to bias engine vocabulary; nothing is stored. See S2 design spec.
    var contextAwareDictationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.contextAwareDictationEnabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.contextAwareDictationEnabled) }
    }
    /// SMAppService is itself the source of truth (macOS's login-item registry) —
```

- [ ] **Step 2: Add the `contextAwareDictationEnabled` key to `SettingsKeys`**

Find:

```swift
nonisolated enum SettingsKeys {
    static let pasteAfterStop = "pasteAfterStop"
    static let soundEnabled = "soundEnabled"
    static let soundVolume = "soundVolume"
    static let audioInputDeviceUID = "audioInputDeviceUID"
    static let customVocabulary = "customVocabulary"
    static let wordReplacements = "wordReplacements"
    static let fuzzyVocabCorrection = "fuzzyVocabCorrection"
    static let hasImportedLegacyHistory = "hasImportedLegacyHistory"
    static let autoDeleteAfterDays = "autoDeleteAfterDays"
}
```

Replace with:

```swift
nonisolated enum SettingsKeys {
    static let pasteAfterStop = "pasteAfterStop"
    static let soundEnabled = "soundEnabled"
    static let soundVolume = "soundVolume"
    static let audioInputDeviceUID = "audioInputDeviceUID"
    static let customVocabulary = "customVocabulary"
    static let wordReplacements = "wordReplacements"
    static let fuzzyVocabCorrection = "fuzzyVocabCorrection"
    static let contextAwareDictationEnabled = "contextAwareDictationEnabled"
    static let hasImportedLegacyHistory = "hasImportedLegacyHistory"
    static let autoDeleteAfterDays = "autoDeleteAfterDays"
}
```

- [ ] **Step 3: Add the `contextCaptureTask` property**

Find:

```swift
    /// Set right after audioCapture.start() succeeds; read at stop to compute the
    /// session duration recorded in history, and to time the start-to-first-partial
    /// latency log. Cleared at the end of every stopDictation().
    private var recordingStartedAt: ContinuousClock.Instant?
```

Replace with:

```swift
    /// Set right after audioCapture.start() succeeds; read at stop to compute the
    /// session duration recorded in history, and to time the start-to-first-partial
    /// latency log. Cleared at the end of every stopDictation().
    private var recordingStartedAt: ContinuousClock.Instant?

    /// Fired the instant dictation=.starting is claimed (S2 context-aware
    /// dictation), concurrently with permission checks/audioCapture.start() so
    /// the AX read doesn't add latency on top of work already happening. Awaited
    /// once, right before engine.transcribe(). nil when the feature is off.
    private var contextCaptureTask: Task<[String], Never>?
```

- [ ] **Step 4: Add the `startContextCapture` helper**

Find:

```swift
    /// nonisolated so the Task it spawns runs on the cooperative thread pool, not
    /// MainActor — see AppState concurrency note in CLAUDE.md. Runs the legacy
    /// importer, then auto-delete cleanup; both are fire-and-forget, errors logged.
    nonisolated private func runHistoryStartupTasks(store: HistoryStore, autoDeleteAfterDays: Int?) {
        Task {
            LegacyHistoryImporter.importIfNeeded(into: store)
            guard let autoDeleteAfterDays else { return }
            do {
                try store.deleteOlderThan(days: autoDeleteAfterDays)
            } catch {
                log.error("startup cleanup — deleteOlderThan failed: \(error)")
            }
        }
    }

    // MARK: Actions
```

Replace with:

```swift
    /// nonisolated so the Task it spawns runs on the cooperative thread pool, not
    /// MainActor — see AppState concurrency note in CLAUDE.md. Runs the legacy
    /// importer, then auto-delete cleanup; both are fire-and-forget, errors logged.
    nonisolated private func runHistoryStartupTasks(store: HistoryStore, autoDeleteAfterDays: Int?) {
        Task {
            LegacyHistoryImporter.importIfNeeded(into: store)
            guard let autoDeleteAfterDays else { return }
            do {
                try store.deleteOlderThan(days: autoDeleteAfterDays)
            } catch {
                log.error("startup cleanup — deleteOlderThan failed: \(error)")
            }
        }
    }

    /// nonisolated so the Task it creates runs on the cooperative thread pool —
    /// same rationale as runHistoryStartupTasks. `enabled` is a plain Bool
    /// parameter rather than reading contextAwareDictationEnabled inside the
    /// nonisolated body, because that property is MainActor-isolated and can't
    /// be read from here directly (same reason vocabSnapshot/replacementsSnapshot/
    /// fuzzySnapshot are read on MainActor and passed by value into
    /// startDictation()'s transcription Task).
    nonisolated private func startContextCapture(enabled: Bool) -> Task<[String], Never>? {
        guard enabled else { return nil }
        return Task {
            guard let text = ScreenContextReader.captureFrontmostWindowText() else { return [] }
            return await SalientTermExtractor.extractSalientTerms(from: text)
        }
    }

    // MARK: Actions
```

- [ ] **Step 5: Fire the capture in `toggleDictation()`**

Find:

```swift
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            pttPressedAt = nil   // toggle has no "hold" concept — never inherit a stale PTT timestamp
            dictation = .starting
            overlay.show(appState: self)   // instant — warming look, before any permission/capture work
            Task { await startDictation() }
```

Replace with:

```swift
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            pttPressedAt = nil   // toggle has no "hold" concept — never inherit a stale PTT timestamp
            dictation = .starting
            overlay.show(appState: self)   // instant — warming look, before any permission/capture work
            contextCaptureTask = startContextCapture(enabled: contextAwareDictationEnabled)
            Task { await startDictation() }
```

- [ ] **Step 6: Fire the capture in `beginPushToTalk()`**

Find:

```swift
        stopRequestedWhilePTTStarting = false
        pttPressedAt = .now
        dictation = .starting
        overlay.show(appState: self)   // instant — warming look, before any permission/capture work
        Task { await startDictation() }
```

Replace with:

```swift
        stopRequestedWhilePTTStarting = false
        pttPressedAt = .now
        dictation = .starting
        overlay.show(appState: self)   // instant — warming look, before any permission/capture work
        contextCaptureTask = startContextCapture(enabled: contextAwareDictationEnabled)
        Task { await startDictation() }
```

- [ ] **Step 7: Merge screen terms into engine vocabulary in `startDictation()`**

Find:

```swift
            // Snapshot once per session — read fresh at the moment this specific
            // dictation starts, not re-read per streamed partial.
            let vocabSnapshot = customVocabulary
            let replacementsSnapshot = wordReplacements
            let fuzzySnapshot = fuzzyVocabCorrection

            let events = engine.transcribe(audioStream, vocabulary: vocabSnapshot)
```

Replace with:

```swift
            // Snapshot once per session — read fresh at the moment this specific
            // dictation starts, not re-read per streamed partial.
            let vocabSnapshot = customVocabulary
            let replacementsSnapshot = wordReplacements
            let fuzzySnapshot = fuzzyVocabCorrection

            // Screen-extracted terms (S2) feed engine biasing only — never
            // vocabSnapshot itself, which also doubles as fuzzyCorrect's
            // post-hoc snap-to-nearest-term dictionary below. Mixing noisy
            // auto-extracted terms into that harder rewrite is a different
            // risk profile than soft engine biasing.
            let screenTerms = await contextCaptureTask?.value ?? []
            let engineVocabulary = vocabSnapshot + screenTerms.filter { term in
                !vocabSnapshot.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
            }

            let events = engine.transcribe(audioStream, vocabulary: engineVocabulary)
```

- [ ] **Step 8: Reset `contextCaptureTask` at the end of `stopDictation()`**

Find:

```swift
        pttPressedAt = nil
        recordingStartedAt = nil
        await finishOverlayExit(exitDuration(for: phase))
```

Replace with:

```swift
        pttPressedAt = nil
        recordingStartedAt = nil
        contextCaptureTask = nil
        await finishOverlayExit(exitDuration(for: phase))
```

- [ ] **Step 9: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`. If a MainActor-isolation error appears referencing `contextAwareDictationEnabled` from inside `startContextCapture`, re-check Step 4 — the parameter must be read at the two call sites (Steps 5/6, both already MainActor) and passed in, never read inside the `nonisolated` function body.

- [ ] **Step 10: Run the full test suite to confirm no regressions**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: `Test run with 64 tests in 9 suites passed`, `** TEST SUCCEEDED **` (same count as end of Task 2 — this task adds no new tests, only wiring).

- [ ] **Step 11: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "$(cat <<'EOF'
✨ feat(context): wire S2 context capture into AppState

contextAwareDictationEnabled setting (off by default), fired concurrently
with dictation startup via a nonisolated Task, awaited right before
engine.transcribe() and merged into engine vocabulary only — never into
vocabSnapshot, which also feeds fuzzyCorrect's harder post-hoc rewrite.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Settings toggle

**Files:**
- Modify: `omwhisper-native/UI/VocabularySettingsView.swift`

**Interfaces:**
- Consumes: `AppState.contextAwareDictationEnabled` (Task 3).

- [ ] **Step 1: Add the toggle**

In `omwhisper-native/UI/VocabularySettingsView.swift`, find:

```swift
            Section {
                Toggle("Fuzzy-match near-miss words", isOn: $state.fuzzyVocabCorrection)
                Text("Auto-correct near-misses to your terms. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Examples: \"okay\" → \"OK\" · \"gonna\" → \"going to\" · \"OmWhisper\" as a custom word")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
```

Replace with:

```swift
            Section {
                Toggle("Fuzzy-match near-miss words", isOn: $state.fuzzyVocabCorrection)
                Text("Auto-correct near-misses to your terms. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Examples: \"okay\" → \"OK\" · \"gonna\" → \"going to\" · \"OmWhisper\" as a custom word")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use On-Screen Context", isOn: $state.contextAwareDictationEnabled)
                Text("Reads the frontmost window's visible text when dictation starts, to bias recognition toward names and terms already on screen. Nothing is stored. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/VocabularySettingsView.swift
git commit -m "$(cat <<'EOF'
✨ feat(context): add On-Screen Context toggle to Vocabulary settings

Folded into the existing Vocabulary tab rather than a new tab — same
contextualStrings/engine-biasing mechanism as customVocabulary and
wordReplacements. Off by default.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Live verification and progress tracker update

**Files:**
- Modify: `CLAUDE.md` (progress tracker)

No new interfaces — this task verifies the whole feature actually works end-to-end on real hardware, since `ScreenContextReader`'s AX walk and the `AppState` wiring around it are exactly the pieces Task 1–3 couldn't unit-test.

- [ ] **Step 1: Full clean build and test suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' clean build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -destination 'platform=macOS' test 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: `Test run with 64 tests in 9 suites passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 2: Launch the app and enable the setting**

```bash
pkill -f "OmWhisper.app/Contents/MacOS/OmWhisper" 2>/dev/null
sleep 1
APP=$(find ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/Build/Products/Debug -maxdepth 1 -name "OmWhisper.app" | head -1)
open "$APP"
sleep 3
```

Then open Settings (via the menu bar "Settings…" item), go to the Vocabulary tab, and toggle "Use On-Screen Context" on — either manually, or via `osascript`/System Events the same way the menu items were driven earlier this session (`click menu bar item 1 of menu bar 2` → `click menu item "Settings…"` → find the `AXCheckBox` for this toggle via `entire contents of window "General"` and click it).

- [ ] **Step 3: Open a text-heavy window with distinctive on-screen terms**

Open any app with visible technical/proper-noun text on screen — e.g. this very terminal, or a text editor showing this plan file (which contains distinctive terms like "ScreenContextReader", "Kubernetes", "SalientTermExtractor"). Bring it to the front.

- [ ] **Step 4: Trigger a real dictation session and confirm no crash/regression**

Via the menu bar "Start Dictation" item (or `osascript`), start a session, wait 1-2 seconds, then "Stop Dictation". Confirm:
- The app doesn't crash (`ps aux | grep "OmWhisper.app/Contents/MacOS/OmWhisper$" | grep -v grep` still shows the process).
- `latencyLog`'s `start-to-first-partial` log line (visible via `log show --last 1m --predicate 'process == "OmWhisper"' | grep "start-to-first-partial"`) doesn't show a dramatic regression versus pre-S2 measurements in `CLAUDE.md`'s "Measured status" section (1.3–2.0s typical) — a jump to several seconds would indicate the 0.6s AX budget is being paid in full and serially rather than overlapping with startup as designed, worth investigating before calling this done.
- With the setting off (toggle back off, repeat a session), behavior is unchanged from before this feature existed — confirms the off-by-default path is truly a no-op.

- [ ] **Step 5: Clean up the test instance**

```bash
pkill -f "OmWhisper.app/Contents/MacOS/OmWhisper" 2>/dev/null
```

- [ ] **Step 6: Update the CLAUDE.md progress tracker**

The `M2` row in `CLAUDE.md`'s Progress Tracker table has grown across several
sessions, so anchor on its start rather than its full (long, changing) text.

Run: `grep -n "^| M2 — Daily-driver parity" CLAUDE.md`

This prints the M2 row's line number (call it `N`). Read lines `N` to `N+1` with
the `Read` tool (`offset: N, limit: 2`) to see the exact current M2 row and the
row immediately after it (`M3–M5`). Insert a new row **between them** — after the
M2 row, before the `M3–M5` row — with this exact content (fill in the two
`<...>` placeholders from what Step 4 actually observed; every other word is
final, not a placeholder):

```
| Phase S1/S2 — Context-aware dictation | 🔶 S2 shipped, S1 not started | S2 (2026-07-0<day>): `Context/SalientTermExtractor.swift` (NLTagger `.nameType` for proper nouns, regex for camelCase/PascalCase/snake_case/dotted-path code identifiers including acronym-prefixed like `NSFoo`/`URLSession`, `NSSpellChecker` for rare/technical words, merge+case-insensitive-dedupe+cap-at-30); `Context/ScreenContextReader.swift` (ported from `smriti`'s `AXReader.swift`, 0.6s time budget — tighter than Smriti's 2.0s default since this sits on the critical path to first-partial latency — hardcoded exclusions for password managers + private/incognito browsing, matching Smriti's `Config.defaults`). `AppState` fires the AX read concurrently with dictation startup (same instant `dictation = .starting` is claimed) via a `nonisolated` Task, awaited once right before `engine.transcribe(...)`; screen-extracted terms feed engine vocabulary only, never `fuzzyCorrect`'s dictionary. `contextAwareDictationEnabled` toggle in the Vocabulary settings tab, off by default — every Smriti-derived feature ships off by default. 13 new tests, all passing (64 total). Live-verified: <latency observation from Step 4>. S1 (memory core) not started. |
```

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
📝 docs: mark S2 context-aware dictation shipped

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
