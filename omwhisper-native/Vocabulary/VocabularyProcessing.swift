//
//  VocabularyProcessing.swift
//  OmWhisper
//
//  Engine-agnostic post-processing applied to transcript text after any
//  TranscriptionEngine produces it: whole-word replacements, then (opt-in)
//  fuzzy vocabulary correction. Ported from the Tauri app's engine.rs/
//  vocab_correct.rs — same algorithm and thresholds, Swift idiom throughout.
//

import Foundation

/// nonisolated for the same reason the functions below are: this crosses into
/// the transcription pipeline's background Task. Unmarked, the project's
/// MainActor-by-default isolation makes its Equatable conformance MainActor-
/// bound, and comparing two rules from a plain test function fails to compile
/// — the identical gap TranscriptEvent, EngineKind and HomeStats each hit the
/// first time something outside MainActor compared them.
nonisolated struct ReplacementRule: Codable, Equatable, Hashable {
    var from: String
    var to: String
}

/// Case-insensitive whole-word replacement. A rule with an empty `from` is
/// skipped — `\b\b` would otherwise match every zero-width word boundary and
/// replace at every position in the string.
// nonisolated: these are pure, stateless text functions with no MainActor
// affinity — opts them out of the project's MainActor default so they're
// callable from the transcription pipeline's background Task without a hop.
nonisolated func applyReplacements(_ text: String, rules: [ReplacementRule]) -> String {
    guard !rules.isEmpty else { return text }
    var result = text
    for rule in rules {
        guard !rule.from.isEmpty else { continue }
        let escaped = NSRegularExpression.escapedPattern(for: rule.from)
        guard let regex = try? Regex("\\b\(escaped)\\b").ignoresCase() else { continue }
        result = result.replacing(regex, with: rule.to)
    }
    return result
}

/// Snap near-miss whitespace-delimited tokens to a single qualifying
/// dictionary term. Conservative by design: short tokens are never touched,
/// and a token within threshold distance of more than one dictionary term is
/// left alone rather than guessed at.
nonisolated func fuzzyCorrect(_ text: String, dictionary: [String],
                              gate: FuzzyGate = .standard) -> String {
    guard !dictionary.isEmpty else { return text }
    let dictLower = dictionary.map { $0.lowercased() }

    var result = ""
    for token in splitInclusiveOnWhitespace(text) {
        guard let start = token.firstIndex(where: isWordChar),
              let end = token.lastIndex(where: isWordChar) else {
            result += token
            continue
        }
        let lead = token[token.startIndex..<start]
        let core = token[start...end]
        let trail = token[token.index(after: end)...]
        let coreLower = core.lowercased()

        if dictLower.contains(coreLower) {
            result += token
            continue
        }
        guard let maxDistance = gate.maxDistance(forTokenLength: coreLower.count) else {
            result += token
            continue
        }

        var hit: String?
        var ambiguous = false
        for (original, lower) in zip(dictionary, dictLower) {
            if boundedLevenshtein(coreLower, lower, max: maxDistance) <= maxDistance {
                if hit != nil {
                    ambiguous = true
                    break
                }
                hit = original
            }
        }

        if ambiguous || hit == nil {
            result += token
        } else {
            result += lead + matchCase(String(core), hit!) + trail
        }
    }
    return result
}

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
/// Exact match only -- strictly narrower than the rewrite `fuzzyCorrect`
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
/// excluded too -- a 3-letter term is reachable by joining far too many
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
/// carry trailing punctuation -- anything between the pieces means these are
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

/// Assembles the vocabulary handed to a TranscriptionEngine for biasing.
/// Apple/Parakeet get the user's custom terms plus S2's auto-extracted
/// screen terms (deduped case-insensitively); Cloud gets only the user's
/// own explicitly-typed terms -- screen terms were never reviewed or
/// approved by the user, and shouldn't leave the device just because
/// Cloud was selected. See docs/superpowers/specs/2026-07-09-m4-2-cloud-engine-design.md.
nonisolated func mergeEngineVocabulary(customTerms: [String], screenTerms: [String], engineKind: EngineKind) -> [String] {
    guard engineKind != .cloud else { return customTerms }
    return customTerms + screenTerms.filter { term in
        !customTerms.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
    }
}

/// Splits inclusive on whitespace: each element (except possibly the last)
/// ends with the whitespace character that terminated it, mirroring Rust's
/// `str::split_inclusive` — this is what lets whitespace layout (including
/// runs of spaces/tabs) survive untouched.
nonisolated private func splitInclusiveOnWhitespace(_ text: String) -> [Substring] {
    var tokens: [Substring] = []
    var start = text.startIndex
    var idx = text.startIndex
    while idx < text.endIndex {
        if text[idx].isWhitespace {
            let end = text.index(after: idx)
            tokens.append(text[start..<end])
            start = end
        }
        idx = text.index(after: idx)
    }
    if start < text.endIndex {
        tokens.append(text[start...])
    }
    return tokens
}

nonisolated private func isWordChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "'"
}

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

/// Bounded Levenshtein distance, capped at `max + 1` via early-out once every
/// entry in the current row exceeds `max`.
nonisolated private func boundedLevenshtein(_ a: String, _ b: String, max: Int) -> Int {
    let a = Array(a), b = Array(b)
    if abs(a.count - b.count) > max { return max + 1 }

    var prev = Array(0...b.count)
    for (i, ca) in a.enumerated() {
        var cur = [i + 1]
        var rowMin = cur[0]
        for (j, cb) in b.enumerated() {
            let cost = ca == cb ? 0 : 1
            let v = min(prev[j] + cost, prev[j + 1] + 1, cur[j] + 1)
            cur.append(v)
            rowMin = min(rowMin, v)
        }
        if rowMin > max { return max + 1 }
        prev = cur
    }
    return prev[b.count]
}

/// Carries the casing pattern of `src` onto `dst` (all-caps, Titlecase, else
/// `dst` unchanged).
nonisolated private func matchCase(_ src: String, _ dst: String) -> String {
    let letters = src.filter { $0.isLetter }
    if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) {
        return dst.uppercased()
    }
    if let first = src.first, first.isUppercase {
        return dst.prefix(1).uppercased() + dst.dropFirst()
    }
    return dst
}
