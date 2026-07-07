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
