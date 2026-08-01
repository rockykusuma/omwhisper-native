//
//  SemanticIndexing.swift
//  OmWhisper
//
//  The pure half of Memory's semantic search: boilerplate detection, passage
//  chunking, rank fusion, and the vector codec. No I/O, no NaturalLanguage --
//  those live in MemoryEmbedding/MemoryStore, so everything here unit-tests
//  directly (the same split as MeetingDiarization vs MeetingDiarizer).
//
//  See docs/superpowers/specs/2026-08-01-memory-embedding-spike.md for why
//  boilerplate detection is per-app.
//

import Accelerate
import Foundation

nonisolated enum SemanticIndexing {
    // MARK: - Boilerplate

    /// Tokens appearing in more than `threshold` of one app's snapshots.
    ///
    /// Per-app is load-bearing, not an optimisation: measured on the real store,
    /// a median Arc snapshot is 58% sidebar/pinned-tab chrome, but computing
    /// document frequency across ALL apps found 32 such tokens instead of 93
    /// and barely changed retrieval. Chrome differs per app.
    ///
    /// A single document yields nothing -- every token would have 100% document
    /// frequency, and stripping them all would erase the only content there is.
    static func boilerplateTokens(perAppTexts: [String], threshold: Double = 0.7) -> Set<String> {
        guard perAppTexts.count > 1 else { return [] }
        var df: [String: Int] = [:]
        for text in perAppTexts {
            for token in Set(text.split(separator: " ").map(String.init)) {
                df[token, default: 0] += 1
            }
        }
        let cutoff = Double(perAppTexts.count) * threshold
        return Set(df.filter { Double($0.value) > cutoff }.keys)
    }

    static func strip(_ text: String, boilerplate: Set<String>) -> String {
        text.split(separator: " ")
            .map(String.init)
            .filter { !boilerplate.contains($0) }
            .joined(separator: " ")
    }

    // MARK: - Chunking

    /// ~`limit`-char passages, split on word boundaries. A whole snapshot is one
    /// vector of mush (6,350 chars on average); passages are also what lets the
    /// UI show WHICH part matched.
    static func passages(_ text: String, limit: Int = 1000) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            if !current.isEmpty, current.count + word.count + 1 > limit {
                out.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Fusion

    /// Reciprocal rank fusion. bm25 and cosine live on incompatible scales, so
    /// normalising them into one score is a tuning problem with no correct
    /// answer; RRF only needs the orderings. Rows ranked well by both win.
    static func fuse(keyword: [Int64], semantic: [Int64], k: Int = 60) -> [Int64] {
        var score: [Int64: Double] = [:]
        for (i, id) in keyword.enumerated() { score[id, default: 0] += 1.0 / Double(k + i + 1) }
        for (i, id) in semantic.enumerated() { score[id, default: 0] += 1.0 / Double(k + i + 1) }
        // Stable: ties broken by first appearance, so results don't reshuffle.
        var order: [Int64: Int] = [:]
        for id in keyword + semantic where order[id] == nil { order[id] = order.count }
        return score.keys.sorted {
            let (a, b) = (score[$0] ?? 0, score[$1] ?? 0)
            return a != b ? a > b : (order[$0] ?? 0) < (order[$1] ?? 0)
        }
    }

    // MARK: - Diversity

    /// Cap how many consecutive results may come from the same app.
    ///
    /// The spike found one query whose entire top 3 was the same app: plausible
    /// content, but three near-identical windows are a worse answer than three
    /// different sources. Order is otherwise preserved -- a demoted row moves
    /// down, it is never dropped.
    static func diversified<T>(_ items: [T], maxRun: Int = 3, appName: (T) -> String) -> [T] {
        var out: [T] = []
        var deferred: [T] = []
        var run = 0
        var lastApp: String?
        for item in items {
            let app = appName(item)
            if app == lastApp {
                run += 1
                if run > maxRun { deferred.append(item); continue }
            } else {
                lastApp = app
                run = 1
            }
            out.append(item)
        }
        return out + deferred
    }

    // MARK: - Vector codec

    /// float16 halves the index (~1 KB/passage at 512 dims). Precision loss is
    /// irrelevant to cosine ranking.
    static func encode(_ v: [Float]) -> Data {
        let halves = v.map { Float16($0) }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ d: Data) -> [Float] {
        let count = d.count / MemoryLayout<Float16>.size
        guard count > 0 else { return [] }
        var halves = [Float16](repeating: 0, count: count)
        _ = halves.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        return halves.map { Float($0) }
    }

    /// Zero vectors return 0 rather than NaN -- a NaN would poison the sort.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
