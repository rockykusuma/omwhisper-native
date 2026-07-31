//
//  WER.swift
//  OmWhisper
//
//  Word Error Rate — the standard ASR accuracy measure, and the one number
//  M4 has owed since the beginning (docs/NATIVE_MIGRATION_PLAN.md risk #1:
//  "SpeechTranscriber accuracy is the big unknown").
//
//  WER = (substitutions + deletions + insertions) / reference word count.
//  Reported per-category as well as combined, because the categories say
//  different things: heavy insertions means an engine is hallucinating
//  (Whisper on near-silence does exactly this — see the
//  whisper-hallucinates-on-silence memory), heavy deletions means it is
//  dropping speech.
//
//  Pure and directly tested. The effectful runner is WERBenchmark (DEBUG only).
//

import Foundation

nonisolated enum WER {
    struct Result: Equatable {
        var substitutions: Int
        var deletions: Int
        var insertions: Int
        var referenceWords: Int

        var errors: Int { substitutions + deletions + insertions }

        /// Errors per reference word. Can exceed 1.0 — an engine that invents
        /// more words than were spoken is worse than one that outputs nothing,
        /// and the number should say so rather than clamping.
        ///
        /// An empty reference is degenerate: 0 if the hypothesis is also empty,
        /// otherwise 1 per spurious word.
        var rate: Double {
            guard referenceWords > 0 else { return insertions == 0 ? 0 : Double(insertions) }
            return Double(errors) / Double(referenceWords)
        }
    }

    /// Lowercase, drop punctuation, split on whitespace.
    ///
    /// Apostrophes are kept inside words so "don't" stays one token rather than
    /// becoming two errors, then trimmed at the edges so a quoted 'word' does
    /// not differ from the same word unquoted.
    ///
    /// ponytail: no number/currency normalization — an engine writing "5" against
    /// a reference of "five" is counted wrong, as are "%" vs "percent" and
    /// "Dr." vs "doctor". Standard benchmarks run a full text normalizer here
    /// (Whisper ships its own). Write the references the way you would want the
    /// text pasted, keep them consistent across engines, and the comparison stays
    /// fair even though the absolute number is slightly pessimistic. Add a
    /// normalizer only if a real comparison turns on it.
    static func normalize(_ text: String) -> [String] {
        let cleaned = String(text.lowercased().map { ch in
            (ch.isLetter || ch.isNumber || ch == "'") ? ch : " "
        })
        return cleaned
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// Levenshtein alignment over words, with a backtrace so the three error
    /// kinds can be reported separately.
    static func compare(reference: String, hypothesis: String) -> Result {
        let r = normalize(reference)
        let h = normalize(hypothesis)
        let n = r.count, m = h.count

        // Degenerate cases first: the DP loops below need both dimensions.
        if n == 0 { return Result(substitutions: 0, deletions: 0, insertions: m, referenceWords: 0) }
        if m == 0 { return Result(substitutions: 0, deletions: n, insertions: 0, referenceWords: n) }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                if r[i - 1] == h[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j - 1], min(dp[i - 1][j], dp[i][j - 1]))
                }
            }
        }

        var i = n, j = m
        var subs = 0, dels = 0, ins = 0
        while i > 0 || j > 0 {
            if i > 0, j > 0, r[i - 1] == h[j - 1], dp[i][j] == dp[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, dp[i][j] == dp[i - 1][j - 1] + 1 {
                subs += 1; i -= 1; j -= 1
            } else if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                dels += 1; i -= 1
            } else {
                ins += 1; j -= 1
            }
        }
        return Result(substitutions: subs, deletions: dels, insertions: ins, referenceWords: n)
    }

    /// Corpus-level WER: errors and reference words are pooled across samples
    /// rather than averaging per-sample rates, so one short sample cannot swing
    /// the result as much as a long one. This is how WER is normally aggregated.
    static func aggregate(_ results: [Result]) -> Result {
        Result(
            substitutions: results.reduce(0) { $0 + $1.substitutions },
            deletions: results.reduce(0) { $0 + $1.deletions },
            insertions: results.reduce(0) { $0 + $1.insertions },
            referenceWords: results.reduce(0) { $0 + $1.referenceWords })
    }
}
