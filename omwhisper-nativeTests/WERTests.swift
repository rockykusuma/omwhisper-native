import Testing
import Foundation
@testable import OmWhisper

@Suite("WER")
struct WERTests {

    // MARK: normalize

    @Test func lowercasesAndDropsPunctuation() {
        #expect(WER.normalize("Hello, World!") == ["hello", "world"])
    }

    @Test func keepsApostrophesInsideWordsButNotAtEdges() {
        // "don't" must stay one token — splitting it would score two errors
        // against an engine that got it exactly right.
        #expect(WER.normalize("Don't 'quote' me") == ["don't", "quote", "me"])
    }

    @Test func collapsesWhitespaceAndIgnoresEmptyTokens() {
        #expect(WER.normalize("  a \n\n b\t—\tc  ") == ["a", "b", "c"])
    }

    // MARK: compare

    @Test func identicalTextIsZeroErrors() {
        let r = WER.compare(reference: "the quick brown fox", hypothesis: "The quick brown fox.")
        #expect(r.errors == 0)
        #expect(r.rate == 0)
        #expect(r.referenceWords == 4)
    }

    @Test func countsSubstitutionSeparately() {
        let r = WER.compare(reference: "the quick brown fox", hypothesis: "the quick brown box")
        #expect(r.substitutions == 1)
        #expect(r.deletions == 0)
        #expect(r.insertions == 0)
        #expect(r.rate == 0.25)
    }

    @Test func countsDeletionSeparately() {
        let r = WER.compare(reference: "the quick brown fox", hypothesis: "the quick fox")
        #expect(r.deletions == 1)
        #expect(r.substitutions == 0)
        #expect(r.insertions == 0)
    }

    @Test func countsInsertionSeparately() {
        let r = WER.compare(reference: "the quick fox", hypothesis: "the quick brown fox")
        #expect(r.insertions == 1)
        #expect(r.substitutions == 0)
        #expect(r.deletions == 0)
    }

    /// The failure mode that motivated reporting the three kinds separately:
    /// Whisper inventing text over near-silence. A combined rate alone would
    /// look like an ordinary bad score; the insertion count names the cause.
    @Test func hallucinationShowsAsInsertionsAndCanExceedOne() {
        let r = WER.compare(reference: "hello", hypothesis: "thank you for watching this video")
        #expect(r.insertions > 0)
        #expect(r.rate > 1.0)
    }

    @Test func emptyHypothesisIsAllDeletions() {
        let r = WER.compare(reference: "one two three", hypothesis: "")
        #expect(r.deletions == 3)
        #expect(r.rate == 1.0)
    }

    @Test func emptyReferenceWithEmptyHypothesisIsPerfect() {
        #expect(WER.compare(reference: "", hypothesis: "").rate == 0)
    }

    @Test func emptyReferenceWithOutputIsPenalized() {
        // Silence in, words out — must not score as 0% error.
        #expect(WER.compare(reference: "", hypothesis: "two words").rate > 0)
    }

    // MARK: aggregate

    /// Pooled, not the mean of per-sample rates: a 1-error/2-word sample and a
    /// 1-error/98-word sample is 2/100, not the 25.5% a naive average gives.
    @Test func aggregatePoolsErrorsRatherThanAveragingRates() {
        let a = WER.Result(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 2)
        let b = WER.Result(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 98)
        let total = WER.aggregate([a, b])
        #expect(total.referenceWords == 100)
        #expect(total.errors == 2)
        #expect(abs(total.rate - 0.02) < 0.0001)
    }
}
