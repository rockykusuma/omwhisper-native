//
//  SalientTermExtractorTests.swift
//  omwhisper-nativeTests
//

import Foundation
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

    @Test func detectsRareWords() async {
        let words = await SalientTermExtractor.rareWords(in: "Please check the polymorphism in that classe")
        #expect(words.contains(where: { $0.caseInsensitiveCompare("classe") == .orderedSame }))
    }

    @Test func commonWordsNotFlaggedAsRare() async {
        let words = await SalientTermExtractor.rareWords(in: "the quick brown fox jumps over the lazy dog")
        #expect(words.isEmpty)
    }

    @Test func combinesAllThreeCategories() async {
        let text = "Sarah Connor uses getUserById in her codebase with polymorphism and classe issues."
        let terms = await SalientTermExtractor.extractSalientTerms(from: text)
        #expect(terms.contains("Sarah Connor"))
        #expect(terms.contains("getUserById"))
        #expect(terms.contains(where: { $0.caseInsensitiveCompare("classe") == .orderedSame }))
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
}
