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
}
