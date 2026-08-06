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
