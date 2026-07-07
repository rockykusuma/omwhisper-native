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
