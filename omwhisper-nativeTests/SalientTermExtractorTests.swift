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
}
