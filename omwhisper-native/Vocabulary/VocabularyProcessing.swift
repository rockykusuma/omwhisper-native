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

struct ReplacementRule: Codable, Equatable, Hashable {
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
nonisolated func fuzzyCorrect(_ text: String, dictionary: [String]) -> String {
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
        guard let maxDistance = maxDistance(forTokenLength: coreLower.count) else {
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

/// Threshold by token length: skip short words (high false-positive risk);
/// tighter for medium words.
nonisolated private func maxDistance(forTokenLength len: Int) -> Int? {
    switch len {
    case 0...3: return nil
    case 4...6: return 1
    default: return 2
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
