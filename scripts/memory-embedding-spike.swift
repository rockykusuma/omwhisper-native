// Memory semantic-search spike, v2.
//
// v1 found the real bottleneck: 58% of a typical Arc snapshot (median) is
// boilerplate — the browser sidebar and pinned-tab list, identical across
// snapshots. Arc is 59% of the corpus. So this compares FOUR conditions:
//   {NLEmbedding, NLContextualEmbedding} x {raw text, boilerplate stripped}
//
// Targets are snapshot IDs, not substrings: v1's substring markers were
// worthless because "dev.azure.com" appears in 175/600 rows (pinned tabs).

import Foundation
import NaturalLanguage
import Accelerate

let passageChars = 1000

struct Snap { let id: Int; let title: String; let text: String }

// ── corpus ──────────────────────────────────────────────────────────────────
let tsv = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let snaps: [Snap] = tsv.components(separatedBy: "\n").compactMap { line in
    let f = line.components(separatedBy: "\t")
    guard f.count >= 3, let id = Int(f[0]) else { return nil }
    return Snap(id: id, title: f[1], text: f[2])
}

// ── boilerplate detection: tokens present in >70% of snapshots ──────────────
var df: [String: Int] = [:]
for s in snaps { for t in Set(s.text.split(separator: " ").map(String.init)) { df[t, default: 0] += 1 } }
let cutoff = Int(Double(snaps.count) * 0.7)
let boiler = Set(df.filter { $0.value > cutoff }.keys)

func strip(_ text: String) -> String {
    text.split(separator: " ").map(String.init).filter { !boiler.contains($0) }.joined(separator: " ")
}

func passages(_ text: String, limit: Int = passageChars) -> [String] {
    var out: [String] = []; var cur = ""
    for w in text.split(separator: " ") {
        if cur.count + w.count + 1 > limit { if !cur.isEmpty { out.append(cur) }; cur = "" }
        cur += (cur.isEmpty ? "" : " ") + w
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

// ── embedders ───────────────────────────────────────────────────────────────
protocol Embedder { var name: String { get }; func vector(_ s: String) -> [Float]? }

struct StaticEmb: Embedder {
    let name = "NLEmbedding"
    let e = NLEmbedding.sentenceEmbedding(for: .english)!
    func vector(_ s: String) -> [Float]? { e.vector(for: s).map { $0.map(Float.init) } }
}
struct ContextualEmb: Embedder {
    let name = "NLContextual"
    let c: NLContextualEmbedding
    init() { c = NLContextualEmbedding(language: .english)!; try? c.load() }
    func vector(_ s: String) -> [Float]? {
        guard let r = try? c.embeddingResult(for: s, language: .english) else { return nil }
        var sum = [Float](repeating: 0, count: c.dimension); var n: Float = 0
        r.enumerateTokenVectors(in: s.startIndex..<s.endIndex) { v, _ in
            for (i, d) in v.enumerated() where i < sum.count { sum[i] += Float(d) }
            n += 1; return true
        }
        return n > 0 ? sum.map { $0 / n } : nil
    }
}
func cosine(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    vDSP_svesq(a, 1, &na, vDSP_Length(a.count)); vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
    return (na == 0 || nb == 0) ? 0 : dot / (sqrt(na) * sqrt(nb))
}

// ── queries: paraphrases sharing no distinctive keyword with the target ─────
// target = snapshot id, verified by hand from the real store.
let queries: [(q: String, target: Int)] = [
    ("book an appointment for a medical scan",        2755),  // medplus diagnostic
    ("reviewing code changes someone submitted",      97),    // pull request CR fixes
    ("automated test run results for the firmware",   3279),  // HIL pipeline run
    ("new product launches and upvotes",              1311),  // Product Hunt
    ("bluetooth software kit for hearing devices",    72),    // HearingAid Ble SDK
]

print("corpus \(snaps.count) snapshots · boilerplate tokens \(boiler.count)\n")
print("condition                  top5   ranks")

// CONTROL: also index the window TITLE alone — clean, distinctive text. If
// title retrieval works while content retrieval fails, the bottleneck is
// capture quality (browser chrome), not the embedding model.
for mode in ["raw", "stripped", "title-only"] {
    let texts = snaps.map { s -> (Snap, [String]) in
        switch mode {
        case "raw":      return (s, passages(s.text))
        case "stripped": return (s, passages(strip(s.text)))
        default:         return (s, [s.title])
        }
    }
    for emb in [StaticEmb() as Embedder, ContextualEmb() as Embedder] {
        let t0 = Date()
        let vecs = texts.map { (snap: $0.0, vs: $0.1.compactMap { emb.vector($0) }) }
        let dt = Date().timeIntervalSince(t0)
        var hits = 0; var detail: [String] = []
        for (q, target) in queries {
            guard let qv = emb.vector(q) else { continue }
            let ranked = vecs.map { (id: $0.snap.id, s: $0.vs.map { cosine(qv, $0) }.max() ?? -1) }
                .sorted { $0.s > $1.s }
            let rank = ranked.firstIndex { $0.id == target }.map { $0 + 1 } ?? 999
            if rank <= 5 { hits += 1 }
            detail.append(rank <= 5 ? "\(rank)" : "—")
            // Near-duplicate corpus: the exact ID is not the only right answer,
            // so print the top 3 titles and judge topical correctness by eye.
            if mode != "stripped" {
                let names = ranked.prefix(3).compactMap { r in snaps.first { $0.id == r.id }?.title.prefix(42) }
                print("        Q: \(q)")
                for n in names { print("           - \(n)") }
            }
        }
        let label = "\(emb.name) \(mode)"
        let pad = label.padding(toLength: 26, withPad: " ", startingAt: 0)
        let ms = String(format: "%.0f", dt * 1000 / Double(max(snaps.count, 1)))
        print("\(pad) \(hits)/\(queries.count)    \(detail.joined(separator: " "))   (\(ms) ms/snapshot)")
    }
}
