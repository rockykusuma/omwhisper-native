# Vocabulary that actually changes the transcript — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a term typed into the Vocabulary tab actually change the transcript on the default engine — and measure it, rather than assert it.

**Architecture:** `--wer` currently scores raw engine output, so the user-visible pipeline is unmeasured. Task 1 makes it score the real pipeline from the same transcription pass (post-processing is pure text, so this costs nothing). Task 2 adds the one correction that is structurally unreachable today: joining tokens the engine split apart. Task 3 parameterises the fuzzy distance gate and uses the harness from Task 1 to pick a value from data rather than taste.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Swift Testing, `OmWhisper --wer` (DEBUG only).

## Global Constraints

- **No threshold is decided in this plan.** Task 3 measures two policies and records the numbers; the choice follows from the table. Writing a value here would be the "measure thresholds, never taste them" mistake this work exists to correct.
- **No default is flipped in this plan.** `fuzzyVocabCorrection` stays `false`. Whether it should change is a decision for after Task 3's measurement, and it is R's, not the implementer's.
- **The website copy constraint stands throughout**: never claim vocabulary "learns your jargon". Engine biasing is measured inert on Apple and both Parakeet variants.
- **Everything in `Vocabulary/VocabularyProcessing.swift` is `nonisolated`** — it runs from the transcription pipeline's background Task. Under this project's MainActor-by-default isolation a new free function there needs the explicit marker, as every existing one has.
- `Benchmark/WERBenchmark.swift` is inside `#if DEBUG`. Nothing added there ships in Release.
- Full suite before this work: **540 tests in 79 suites**. Run `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test` after every task; it must stay green and grow.

---

### Task 1: Score the pipeline the user actually gets

`WERBenchmark.measure` calls `MeetingTranscriber.transcribeFile` and scores the result. It never applies `applyReplacements` or `fuzzyCorrect`, so every number ever produced describes raw engine output and nobody knows what a user with a vocabulary list receives.

Post-processing is pure text, so the corrected score comes from the **same** transcription pass — a second `WER.compare` on the same string, no extra audio work.

**Files:**
- Modify: `omwhisper-native/Benchmark/WERBenchmark.swift`
- Modify: `docs/wer-corpus/README.md`
- Test: `omwhisper-nativeTests/WERBenchmarkCorrectionTests.swift` (create)

**Interfaces:**
- Consumes: `applyReplacements(_:rules:)`, `fuzzyCorrect(_:dictionary:)`, `ReplacementRule` (all existing).
- Produces:
  - `WERBenchmark.parseReplacements(_ raw: String) -> [ReplacementRule]`
  - `WERBenchmark.corpusCorrection(vocabulary:replacements:) -> (String) -> String`

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/WERBenchmarkCorrectionTests.swift`:

```swift
import Foundation
import Testing
@testable import OmWhisper

@Suite("WER corpus correction")
struct WERBenchmarkCorrectionTests {
    @Test("replacements.txt is parsed, with comments and both arrow forms")
    func parsesReplacements() {
        let raw = """
            # engine mishears these
            versal -> Vercel
            app cast → appcast

            notarise -> notarize
            """
        let rules = WERBenchmark.parseReplacements(raw)
        #expect(rules == [
            ReplacementRule(from: "versal", to: "Vercel"),
            ReplacementRule(from: "app cast", to: "appcast"),
            ReplacementRule(from: "notarise", to: "notarize"),
        ])
    }

    @Test("a line with no arrow is skipped, not guessed at")
    func skipsMalformedLines() {
        // A corpus file with a typo must not silently produce a rule that
        // replaces something unintended — the benchmark's whole job is to be
        // trustworthy about what changed.
        #expect(WERBenchmark.parseReplacements("just some words\n").isEmpty)
        #expect(WERBenchmark.parseReplacements("-> orphan\n").isEmpty)
        #expect(WERBenchmark.parseReplacements("orphan ->\n").isEmpty)
    }

    @Test("the correction closure applies replacements AND fuzzy correction")
    func correctionAppliesBothStages() {
        // The load-bearing check: a closure that applied neither, or only one,
        // would still return a String and still score. This asserts a specific
        // change in a specific direction.
        let correct = WERBenchmark.corpusCorrection(
            vocabulary: ["notarize"],
            replacements: [ReplacementRule(from: "versal", to: "Vercel")])
        // Replacement stage.
        #expect(correct("pushed to versal today").contains("Vercel"))
        // Fuzzy stage: distance 1 on an 8-char token, inside today's gate.
        #expect(correct("we notarise the build").contains("notarize"))
    }

    @Test("correction leaves text alone when the corpus has no vocabulary")
    func emptyCorpusIsIdentity() {
        // Otherwise a corpus without vocabulary.txt would silently measure
        // something other than the raw engine, and the existing published
        // numbers would stop being comparable.
        let correct = WERBenchmark.corpusCorrection(vocabulary: [], replacements: [])
        #expect(correct("I pushed the app cast to Versal") == "I pushed the app cast to Versal")
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED"`
Expected: compile failure — `parseReplacements` and `corpusCorrection` do not exist.

- [ ] **Step 3: Add the corpus loader and correction closure**

In `omwhisper-native/Benchmark/WERBenchmark.swift`, after `loadVocabulary`:

```swift
    /// `from -> to` (or `from → to`) per line; blank lines and `#` comments
    /// ignored. A line without a usable arrow and both sides is SKIPPED rather
    /// than half-parsed: a benchmark that quietly invents a rule reports a
    /// change the app would not have made.
    static func parseReplacements(_ raw: String) -> [ReplacementRule] {
        raw.split(whereSeparator: \.isNewline).compactMap { line -> ReplacementRule? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.components(separatedBy: "→").count > 1
                ? trimmed.components(separatedBy: "→")
                : trimmed.components(separatedBy: "->")
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return ReplacementRule(from: from, to: to)
        }
    }

    private static func loadReplacements(_ directory: URL) -> [ReplacementRule] {
        let url = directory.appendingPathComponent("replacements.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseReplacements(raw)
    }

    /// The post-processing a real dictation receives, in the same order
    /// AppState applies it: replacements, then fuzzy correction. Returns
    /// identity when the corpus supplies neither, so a corpus without
    /// vocabulary.txt still measures the raw engine and stays comparable with
    /// every number published before this existed.
    static func corpusCorrection(vocabulary: [String],
                                 replacements: [ReplacementRule]) -> (String) -> String {
        guard !vocabulary.isEmpty || !replacements.isEmpty else { return { $0 } }
        return { text in
            var result = applyReplacements(text, rules: replacements)
            if !vocabulary.isEmpty {
                result = fuzzyCorrect(result, dictionary: vocabulary)
            }
            return result
        }
    }
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, count above 540.

- [ ] **Step 5: Score corrected alongside raw in one pass**

Replace the `Row` struct and `measure` in `WERBenchmark.swift`.

`Row` becomes:

```swift
    private struct Row {
        let engine: String
        let result: WER.Result
        let seconds: Double
        let audioSeconds: Double
        let failures: [String]
        /// Same hypothesis, after the post-processing a real dictation gets.
        /// nil when the corpus supplies nothing to correct with.
        var corrected: WER.Result?
        /// Same engine, same audio, with custom vocabulary passed. nil when the
        /// corpus has no vocabulary.txt.
        var biased: WER.Result?
        /// The number that describes a real user with a vocabulary list:
        /// biasing on AND post-processing applied.
        var biasedCorrected: WER.Result?
    }
```

`measure` returns both scores from one transcription:

```swift
    private struct Measured {
        let raw: WER.Result
        let corrected: WER.Result
        let seconds: Double
        let audioSeconds: Double
        let failures: [String]
    }

    private static func measure(label: String, engine: TranscriptionEngine, entries: [Entry],
                                vocabulary: [String] = [],
                                correct: @escaping (String) -> String) async -> Measured {
        var rawResults: [WER.Result] = []
        var correctedResults: [WER.Result] = []
        var failures: [String] = []
        let started = Date()

        for entry in entries {
            do {
                let hypothesis = try await MeetingTranscriber.transcribeFile(
                    entry.audio, engine: engine, vocabulary: vocabulary)
                let fixed = correct(hypothesis)
                let raw = WER.compare(reference: entry.reference, hypothesis: hypothesis)
                rawResults.append(raw)
                correctedResults.append(WER.compare(reference: entry.reference, hypothesis: fixed))
                // Full hypothesis, never truncated. A 60-char preview here caused a
                // real misreading on the first run: every engine's line was cut off
                // mid-sentence, so which word actually failed was invisible and the
                // wrong word got blamed.
                print(String(format: "    %-18@ %5.1f%%  (S%d D%d I%d)",
                             entry.name as NSString, raw.rate * 100,
                             raw.substitutions, raw.deletions, raw.insertions))
                print("        \(hypothesis.isEmpty ? "<empty>" : hypothesis)")
                // Only when correction actually changed something -- an
                // unchanged echo on every line would bury the ones that matter.
                if fixed != hypothesis { print("        → \(fixed)") }
            } catch {
                failures.append("\(entry.name): \(error.localizedDescription)")
                print("    \(entry.name): FAILED — \(error.localizedDescription)")
            }
        }

        return Measured(raw: WER.aggregate(rawResults),
                        corrected: WER.aggregate(correctedResults),
                        seconds: Date().timeIntervalSince(started),
                        audioSeconds: entries.reduce(0) { $0 + $1.duration },
                        failures: failures)
    }
```

In `run(directory:)`, load the replacements, build the closure once, and fill the new fields:

```swift
        let vocabulary = loadVocabulary(directory)
        let replacements = loadReplacements(directory)
        let correct = corpusCorrection(vocabulary: vocabulary, replacements: replacements)
        let hasCorrections = !vocabulary.isEmpty || !replacements.isEmpty
        if vocabulary.isEmpty {
            print("No vocabulary.txt — measuring engines with biasing OFF.")
        } else {
            print("vocabulary.txt: \(vocabulary.count) term(s) — each engine runs twice, off then on.")
            print("  \(vocabulary.joined(separator: ", "))")
        }
        if !replacements.isEmpty {
            print("replacements.txt: \(replacements.count) rule(s).")
        }
        if hasCorrections {
            print("Post-processing (replacements + fuzzy correction) is scored alongside raw output.")
        }
        print("")

        var rows: [Row] = []
        for (label, engine, skip) in engines() {
            if let skip {
                // Never silently omit an engine — a missing row would read as
                // "not applicable" when it actually means "not measured".
                print("· \(label): SKIPPED — \(skip)")
                continue
            }
            guard let engine else { continue }
            print("· \(label): running…")
            let plain = await measure(label: label, engine: engine, entries: entries, correct: correct)
            var row = Row(engine: label, result: plain.raw, seconds: plain.seconds,
                          audioSeconds: plain.audioSeconds, failures: plain.failures,
                          corrected: hasCorrections ? plain.corrected : nil)
            if !vocabulary.isEmpty {
                print("· \(label): running with vocabulary…")
                let biased = await measure(label: label, engine: engine, entries: entries,
                                           vocabulary: vocabulary, correct: correct)
                row.biased = biased.raw
                row.biasedCorrected = hasCorrections ? biased.corrected : nil
            }
            rows.append(row)
        }
```

- [ ] **Step 6: Report the corrected columns**

In `report(_:entries:)`, replace the `hasBiased` branch's header and body:

```swift
        let hasBiased = rows.contains { $0.biased != nil }
        let hasCorrected = rows.contains { $0.corrected != nil }

        if hasBiased {
            print("engine                    off   off+fix     on    on+fix     RTF")
            print("──────────────────────────────────────────────────────────────────")
            // Sorted by the number that describes a real user: biasing on with
            // post-processing applied, falling back as those are unavailable.
            func headline(_ r: Row) -> WER.Result { r.biasedCorrected ?? r.biased ?? r.corrected ?? r.result }
            for row in rows.sorted(by: { headline($0).rate < headline($1).rate }) {
                let rtf = row.audioSeconds > 0 ? row.seconds / row.audioSeconds : 0
                func pct(_ r: WER.Result?) -> String {
                    guard let r else { return "     —" }
                    return String(format: "%5.1f%%", r.rate * 100)
                }
                print(String(format: "%-22@ %@  %@  %@  %@   %5.2fx",
                             row.engine as NSString, pct(row.result), pct(row.corrected),
                             pct(row.biased), pct(row.biasedCorrected), rtf))
            }
        } else if hasCorrected {
            print("engine                        WER   WER+fix     RTF")
            print("────────────────────────────────────────────────────")
            for row in rows.sorted(by: { ($0.corrected ?? $0.result).rate < ($1.corrected ?? $1.result).rate }) {
                let rtf = row.audioSeconds > 0 ? row.seconds / row.audioSeconds : 0
                print(String(format: "%-24@  %6.1f%%   %6.1f%%   %5.2fx",
                             row.engine as NSString, row.result.rate * 100,
                             (row.corrected ?? row.result).rate * 100, rtf))
            }
        } else {
```

(The final `else` keeps today's plain table verbatim.)

Update the legend below the table:

```swift
        print("WER = (subs + dels + ins) / reference words, pooled across samples. Lower is better.")
        print("RTF = processing time / audio duration, biasing-off pass. Below 1.00x beats real time.")
        if hasCorrected {
            print("+fix = after the post-processing a real dictation gets (replacements, then fuzzy")
            print("       correction). This is the column that describes a user; the others do not.")
        }
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Document the corpus format**

In `docs/wer-corpus/README.md`, after the `vocabulary.txt` paragraph, add:

```markdown
Add an optional `replacements.txt` (`from -> to` per line, `#` comments allowed) to measure the
hand-authored replacement rules too. With either file present every engine is scored **twice
from one transcription**: raw, and after the post-processing a real dictation receives
(`applyReplacements`, then `fuzzyCorrect`). The `+fix` columns are the only ones that describe
what a user actually sees — every number published before 2026-08-07 is a raw-engine number.
```

- [ ] **Step 9: Commit**

```bash
git add omwhisper-native/Benchmark/WERBenchmark.swift docs/wer-corpus/README.md omwhisper-nativeTests/WERBenchmarkCorrectionTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(wer): score the pipeline a user actually gets, not just the engine

Every WER number ever published by this harness describes RAW engine
output: measure() called transcribeFile and scored the result, and
applyReplacements/fuzzyCorrect were never applied. So the user-visible
pipeline has never been measured in either direction — including the
claim that vocabulary does nothing, which is established about engine
BIASING only.

Corrected scoring costs no extra transcription: post-processing is pure
text, so it is a second WER.compare on the same hypothesis.

replacements.txt makes the hand-authored path measurable too; a line
without a usable arrow is skipped rather than half-parsed, because a
benchmark that invents a rule reports a change the app would not make.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 2: Join terms the engine split apart

The failure that no threshold can reach. `fuzzyCorrect` walks whitespace-delimited tokens and never crosses a space, so `appcast` → "app cast" is structurally uncorrectable today.

**Files:**
- Modify: `omwhisper-native/Vocabulary/VocabularyProcessing.swift`
- Modify: `omwhisper-native/AppState.swift`
- Modify: `omwhisper-native/Benchmark/WERBenchmark.swift`
- Test: `omwhisper-nativeTests/VocabularyProcessingTests.swift`

**Interfaces:**
- Consumes: `corpusCorrection(vocabulary:replacements:)` (Task 1).
- Produces: `joinSplitTerms(_ text: String, dictionary: [String]) -> String`

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/VocabularyProcessingTests.swift`:

```swift
@Suite("Joining split vocabulary terms")
struct JoinSplitTermsTests {
    private let dictionary = ["appcast", "WhisperKit", "OmWhisper", "Vercel", "New York"]

    @Test("a two-token split is rejoined with the term's own casing")
    func joinsTwoTokens() {
        // The measured failure from the 2026-08-01 corpus run: Apple Speech
        // wrote "app cast" for appcast, with or without biasing.
        #expect(joinSplitTerms("I pushed the app cast to Vercel", dictionary: dictionary)
                == "I pushed the appcast to Vercel")
        #expect(joinSplitTerms("built with whisper kit today", dictionary: dictionary)
                == "built with WhisperKit today")
    }

    @Test("a three-token split is rejoined, and beats the two-token join")
    func prefersTheLongerJoin() {
        // "om whisper" is itself a term, so a greedy width-2 pass would leave
        // a stray "kit" behind. Longer joins are tried first.
        #expect(joinSplitTerms("shipped om whisper today", dictionary: ["OmWhisper"])
                == "shipped OmWhisper today")
        #expect(joinSplitTerms("the om whisper kit build", dictionary: ["OmWhisper", "OmWhisperKit"])
                == "the OmWhisperKit build")
    }

    @Test("a run that joins to nothing in the dictionary is left alone")
    func leavesUnknownRunsAlone() {
        // The half that makes this a real check: a function that joined every
        // adjacent pair would pass the tests above and destroy ordinary text.
        #expect(joinSplitTerms("the quick brown fox", dictionary: dictionary)
                == "the quick brown fox")
        #expect(joinSplitTerms("anything at all", dictionary: [])
                == "anything at all")
    }

    @Test("punctuation between the pieces blocks the join")
    func doesNotJoinAcrossPunctuation() {
        // "app, cast" is two words in two clauses, not one word split in half.
        #expect(joinSplitTerms("the app, cast a vote", dictionary: dictionary)
                == "the app, cast a vote")
        #expect(joinSplitTerms("open the app. Cast it now", dictionary: dictionary)
                == "open the app. Cast it now")
    }

    @Test("trailing punctuation and spacing survive the join")
    func preservesSurroundingText() {
        #expect(joinSplitTerms("push the app cast, then deploy", dictionary: dictionary)
                == "push the appcast, then deploy")
        #expect(joinSplitTerms("ship app cast.", dictionary: dictionary) == "ship appcast.")
    }

    @Test("a term containing a space is never a join target")
    func multiWordTermsAreNotJoined() {
        // "New York" is already two words. Joining it to "NewYork" would be a
        // corruption, not a correction.
        #expect(joinSplitTerms("flying to New York tomorrow", dictionary: dictionary)
                == "flying to New York tomorrow")
    }

    @Test("the accepted false positive is documented, not accidental")
    func knownFalsePositiveIsPinned() {
        // "the app cast a shadow" becomes "the appcast a shadow" for a user
        // who listed appcast. This is the stated cost of exact-match joining
        // (see the design doc). Pinned so that narrowing it later is a
        // deliberate, visible change rather than a silent one.
        #expect(joinSplitTerms("the app cast a shadow", dictionary: dictionary)
                == "the appcast a shadow")
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with"`
Expected: compile failure — `joinSplitTerms` does not exist.

- [ ] **Step 3: Implement**

In `omwhisper-native/Vocabulary/VocabularyProcessing.swift`, after `fuzzyCorrect`:

```swift
/// Longest run of tokens considered for a join. Three covers the CamelCase
/// product names a vocabulary list is full of ("om whisper kit"); beyond that
/// the risk of swallowing an ordinary phrase grows faster than the benefit.
nonisolated private let maxJoinWidth = 3

/// Rejoin adjacent tokens the engine split apart, when the joined form is
/// EXACTLY a dictionary term.
///
/// This is the one measured failure no threshold can reach: `fuzzyCorrect`
/// walks whitespace-delimited tokens and never crosses a space, so `appcast`
/// arriving as "app cast" is structurally uncorrectable there. Apple Speech
/// produced exactly that in the 2026-08-01 corpus run, with and without
/// biasing.
///
/// Exact match only — strictly narrower than the rewrite `fuzzyCorrect`
/// already performs. The accepted cost, stated in the design doc and pinned by
/// a test: "the app cast a shadow" becomes "the appcast a shadow" for a user
/// who listed `appcast`.
nonisolated func joinSplitTerms(_ text: String, dictionary: [String]) -> String {
    let index = joinIndex(dictionary)
    guard !index.isEmpty else { return text }

    let tokens = splitInclusiveOnWhitespace(text)
    var result = ""
    var i = 0
    while i < tokens.count {
        var width = 0
        var replacement = ""
        // Longest first: with both OmWhisper and OmWhisperKit listed, a greedy
        // width-2 pass would consume "om whisper" and strand "kit".
        for candidateWidth in stride(from: maxJoinWidth, through: 2, by: -1)
        where i + candidateWidth <= tokens.count {
            if let joined = joinCandidate(tokens[i..<(i + candidateWidth)], index: index) {
                replacement = joined
                width = candidateWidth
                break
            }
        }
        if width > 0 {
            result += replacement
            i += width
        } else {
            result += tokens[i]
            i += 1
        }
    }
    return result
}

/// joined-lowercase -> the term as the user typed it.
///
/// Terms containing whitespace are excluded: "New York" is already two words,
/// and joining it to "NewYork" would be a corruption. Very short terms are
/// excluded too — a 3-letter term is reachable by joining far too many
/// ordinary pairs.
nonisolated private func joinIndex(_ dictionary: [String]) -> [String: String] {
    var index: [String: String] = [:]
    for term in dictionary {
        guard term.count >= 4, !term.contains(where: { $0.isWhitespace }) else { continue }
        index[term.lowercased()] = term
    }
    return index
}

/// The replacement text for one run of tokens, or nil when they don't join to
/// a dictionary term.
///
/// Only the first token may carry leading punctuation and only the last may
/// carry trailing punctuation — anything between the pieces means these are
/// separate words ("the app, cast a vote"), not one word split in half.
nonisolated private func joinCandidate(_ run: ArraySlice<Substring>,
                                       index: [String: String]) -> String? {
    var cores: [String] = []
    var lead = ""
    var trail = ""
    let last = run.count - 1
    for (offset, token) in run.enumerated() {
        guard let start = token.firstIndex(where: isWordChar),
              let end = token.lastIndex(where: isWordChar) else { return nil }
        let tokenLead = String(token[token.startIndex..<start])
        let tokenTrail = String(token[token.index(after: end)...])
        if offset == 0 {
            lead = tokenLead
        } else if !tokenLead.isEmpty {
            return nil
        }
        if offset == last {
            trail = tokenTrail
        } else if !tokenTrail.allSatisfy({ $0.isWhitespace }) {
            return nil
        }
        cores.append(String(token[start...end]))
    }
    let joined = cores.joined()
    guard let term = index[joined.lowercased()] else { return nil }
    return lead + matchCase(joined, term) + trail
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Prove the join is load-bearing**

Temporarily change `guard let term = index[joined.lowercased()] else { return nil }` to
`let term = index[joined.lowercased()] ?? joined`, run the suite, and confirm
`leavesUnknownRunsAlone` fails ("the quick brown fox" would collapse). Restore the guard. A
join that fires on everything passes every positive test in this task.

- [ ] **Step 6: Wire it into the real pipeline and the benchmark**

In `omwhisper-native/AppState.swift`, inside `postProcess` (around line 2033):

```swift
                func postProcess(_ text: String) -> String {
                    var result = applyReplacements(text, rules: replacementsSnapshot)
                    if fuzzySnapshot {
                        // Join before fuzzy: "app cast" must become a single
                        // token before the token-wise pass can even see it.
                        result = joinSplitTerms(result, dictionary: vocabSnapshot)
                        result = fuzzyCorrect(result, dictionary: vocabSnapshot)
                    }
                    return result
                }
```

Gated on the existing `fuzzyVocabCorrection` toggle deliberately: it is one control for
"rewrite my words against my vocabulary list" rather than a second concept in the UI. Whether
that toggle should default to on is Task 3's measurement to inform, and R's to decide.

In `WERBenchmark.corpusCorrection`, mirror the same order so the benchmark measures the
pipeline the app runs:

```swift
            if !vocabulary.isEmpty {
                result = joinSplitTerms(result, dictionary: vocabulary)
                result = fuzzyCorrect(result, dictionary: vocabulary)
            }
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. `WERBenchmarkCorrectionTests` must still pass — Task 1's
correction closure gained a stage and must not have changed its existing behaviour.

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/Vocabulary/VocabularyProcessing.swift omwhisper-native/AppState.swift omwhisper-native/Benchmark/WERBenchmark.swift omwhisper-nativeTests/VocabularyProcessingTests.swift
git commit -m "$(cat <<'EOF'
✨ feat(vocabulary): rejoin terms the engine split apart

The measured failure no threshold can reach. fuzzyCorrect walks
whitespace-delimited tokens and never crosses a space, so `appcast`
arriving as "app cast" — which is what Apple Speech produced in the
2026-08-01 corpus run, with and without biasing — is structurally
uncorrectable there.

Exact match only, so it fires solely on terms the user typed. Longest
join first, or OmWhisper would consume "om whisper" and strand "kit".
Punctuation between the pieces blocks the join: "the app, cast a vote"
is two clauses, not one word in halves.

The accepted false positive ("the app cast a shadow" → "the appcast a
shadow") is pinned by a test asserting current behaviour, so narrowing
it later is a visible decision rather than a silent one.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

### Task 3: Parameterise the distance gate, then measure and record

Two questions currently answered by taste. This task makes both answerable, runs the
measurement, and writes down the result. **It does not change a default or pick a threshold in
code** — those follow from the table and belong to R.

**Files:**
- Modify: `omwhisper-native/Vocabulary/VocabularyProcessing.swift`
- Modify: `omwhisper-native/Benchmark/WERBenchmark.swift`
- Modify: `docs/wer-corpus/README.md`
- Test: `omwhisper-nativeTests/VocabularyProcessingTests.swift`

**Interfaces:**
- Consumes: `joinSplitTerms` (Task 2), `corpusCorrection` (Task 1).
- Produces: `FuzzyGate` enum; `fuzzyCorrect(_:dictionary:gate:)` with `gate` defaulting to `.standard`.

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/VocabularyProcessingTests.swift`:

```swift
@Suite("Fuzzy distance gate")
struct FuzzyGateTests {
    @Test("the standard gate is exactly what shipped")
    func standardGateIsUnchanged() {
        // Pins today's behaviour so widening is opt-in and measurable rather
        // than an accident of refactoring.
        #expect(FuzzyGate.standard.maxDistance(forTokenLength: 3) == nil)
        #expect(FuzzyGate.standard.maxDistance(forTokenLength: 4) == 1)
        #expect(FuzzyGate.standard.maxDistance(forTokenLength: 6) == 1)
        #expect(FuzzyGate.standard.maxDistance(forTokenLength: 7) == 2)
    }

    @Test("the wide gate reaches the measured miss")
    func wideGateReachesVercel() {
        // "Versal" -> "Vercel" is distance 2 on a 6-character token, which the
        // standard gate refuses. This is the specific failure from the
        // 2026-08-01 corpus run that motivated the candidate policy.
        #expect(FuzzyGate.wide.maxDistance(forTokenLength: 6) == 2)
        #expect(FuzzyGate.standard.maxDistance(forTokenLength: 6) == 1)
        // Still never guesses at very short tokens under either policy.
        #expect(FuzzyGate.wide.maxDistance(forTokenLength: 3) == nil)
    }

    @Test("the gate actually changes correction, not just arithmetic")
    func gateChangesTheOutput() {
        // A gate that were parameterised and then ignored would pass the two
        // tests above and correct nothing differently.
        #expect(fuzzyCorrect("pushed to versal", dictionary: ["Vercel"], gate: .standard)
                == "pushed to versal")
        #expect(fuzzyCorrect("pushed to versal", dictionary: ["Vercel"], gate: .wide)
                == "pushed to Vercel")
    }

    @Test("the default gate is standard")
    func defaultIsStandard() {
        // Shipping behaviour must not change as a side effect of this task.
        #expect(fuzzyCorrect("pushed to versal", dictionary: ["Vercel"])
                == "pushed to versal")
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -E "error:|Test run with"`
Expected: compile failure — no `FuzzyGate`, and `fuzzyCorrect` takes no `gate`.

- [ ] **Step 3: Implement**

In `omwhisper-native/Vocabulary/VocabularyProcessing.swift`, replace the private
`maxDistance(forTokenLength:)` function with a policy type:

```swift
/// How far a token may be from a vocabulary term before correction gives up.
///
/// Parameterised so the choice can be MEASURED rather than argued: `--wer`
/// scores a corpus under both policies on the same hypotheses. `.standard` is
/// what shipped; `.wide` is the candidate that reaches "Versal" -> "Vercel",
/// a distance-2 miss on a 6-character token from the 2026-08-01 corpus run.
///
/// Neither policy ever touches tokens of 3 characters or fewer: at that length
/// almost every short English word is within one edit of another.
nonisolated enum FuzzyGate: Sendable {
    case standard
    case wide

    func maxDistance(forTokenLength len: Int) -> Int? {
        switch self {
        case .standard:
            switch len {
            case 0...3: return nil
            case 4...6: return 1
            default: return 2
            }
        case .wide:
            switch len {
            case 0...3: return nil
            case 4:     return 1
            case 5...7: return 2
            default:    return 3
            }
        }
    }
}
```

Change `fuzzyCorrect`'s signature and its one lookup:

```swift
nonisolated func fuzzyCorrect(_ text: String, dictionary: [String],
                              gate: FuzzyGate = .standard) -> String {
```

```swift
        guard let maxDistance = gate.maxDistance(forTokenLength: coreLower.count) else {
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. Every pre-existing `fuzzyCorrect` test must still pass
unchanged — that is the proof the default is genuinely unchanged.

- [ ] **Step 5: Report both gates in the benchmark**

`corpusCorrection` gains a gate parameter:

```swift
    static func corpusCorrection(vocabulary: [String],
                                 replacements: [ReplacementRule],
                                 gate: FuzzyGate = .standard) -> (String) -> String {
```
```swift
                result = joinSplitTerms(result, dictionary: vocabulary)
                result = fuzzyCorrect(result, dictionary: vocabulary, gate: gate)
```

In `run(directory:)`, build both closures and score both — again free, since both operate on the
same hypothesis:

```swift
        let correct = corpusCorrection(vocabulary: vocabulary, replacements: replacements)
        let correctWide = corpusCorrection(vocabulary: vocabulary, replacements: replacements,
                                           gate: .wide)
```

`Measured` gains a third aggregate and `measure` a second closure:

```swift
    private struct Measured {
        let raw: WER.Result
        let corrected: WER.Result
        let correctedWide: WER.Result
        let seconds: Double
        let audioSeconds: Double
        let failures: [String]
    }

    private static func measure(label: String, engine: TranscriptionEngine, entries: [Entry],
                                vocabulary: [String] = [],
                                correct: @escaping (String) -> String,
                                correctWide: @escaping (String) -> String) async -> Measured {
```

Inside the per-entry loop, beside the existing two scores:

```swift
                let wide = correctWide(hypothesis)
                wideResults.append(WER.compare(reference: entry.reference, hypothesis: wide))
```

declaring `var wideResults: [WER.Result] = []` alongside the other two, and returning
`correctedWide: WER.aggregate(wideResults)`.

`Row` gains one field:

```swift
        /// The same user-visible pipeline under the candidate distance gate.
        var biasedCorrectedWide: WER.Result?
```

Both `measure` call sites in `run(directory:)` pass `correct: correct, correctWide: correctWide`,
and the biased one also sets `row.biasedCorrectedWide = hasCorrections ? biased.correctedWide : nil`.

The biased table gains a column:

```swift
            print("engine                    off   off+fix     on    on+fix   on+wide     RTF")
            print("──────────────────────────────────────────────────────────────────────────")
```
```swift
                print(String(format: "%-22@ %@  %@  %@  %@  %@   %5.2fx",
                             row.engine as NSString, pct(row.result), pct(row.corrected),
                             pct(row.biased), pct(row.biasedCorrected),
                             pct(row.biasedCorrectedWide), rtf))
```

Add to the legend:

```swift
        if hasCorrected {
            print("+wide = the candidate distance gate (5...7 chars allow 2 edits, 8+ allow 3).")
            print("        Better means loosen it; worse means the tight gate was right.")
        }
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Run the measurement and record it**

This step produces the numbers the whole plan exists for. It is not optional and it is not a
code change.

```bash
bash scripts/make-wer-corpus.sh /tmp/wer
# add the terms the 2026-08-01 run found failing
printf 'appcast\nWhisperKit\nOmWhisper\nVercel\nnotarize\nParakeet\nKeychain\nGRDB\nSwiftUI\n' > /tmp/wer/vocabulary.txt
# build and run the DEBUG binary
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build
"$(ls -d ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/Build/Products/Debug/OmWhisper-Dev.app | head -1)/Contents/MacOS/OmWhisper-Dev" --wer /tmp/wer
```

Record the resulting table in `docs/wer-corpus/README.md` as a new dated run, and state
plainly:

- whether `+fix` beats raw on Apple Speech (the default engine) — the evidence for or against
  turning `fuzzyVocabCorrection` on by default;
- whether `+wide` beats `+fix` — the evidence for or against the looser gate;
- **any case where a corrected column is WORSE than raw**, which means correction is damaging
  ordinary words and must be reported rather than buried.

Do not change a default or pick a gate in this task. Write the numbers down and stop.

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/Vocabulary/VocabularyProcessing.swift omwhisper-native/Benchmark/WERBenchmark.swift omwhisper-nativeTests/VocabularyProcessingTests.swift docs/wer-corpus/README.md
git commit -m "$(cat <<'EOF'
✨ feat(vocabulary): make the fuzzy distance gate measurable, and measure it

Two questions that were being answered by taste: how far a token may
sit from a vocabulary term before correction gives up, and whether
fuzzy correction should default to on at all.

FuzzyGate makes the first one a parameter, so --wer scores a corpus
under both policies on the same hypotheses — free, since post-processing
is pure text. .standard is exactly what shipped, pinned by a test so
widening stays opt-in.

The numbers are recorded in docs/wer-corpus/README.md. No default is
changed and no gate is chosen here: this task exists to replace an
argument with a table.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JckitW7trZATwktGKw59ti
EOF
)"
```

---

## After this plan

Two decisions become available, both R's, both now backed by a table rather than a preference:

1. **Should `fuzzyVocabCorrection` default to on?** Currently `false`, which is the single
   biggest reason the Vocabulary tab does nothing out of the box.
2. **Should the gate widen?** Only if `+wide` measurably beat `+fix` without a column going
   backwards.

And one thing worth more than either: **a recorded corpus.** The synthetic `say` corpus is
clean, unaccented and close-mic'd — a floor, not a prediction. Reading the same script in R's
own voice, in R's room, is the only version whose numbers describe R's dictation. Threshold
tuning against synthetic audio can be confidently wrong in a way this would catch.
