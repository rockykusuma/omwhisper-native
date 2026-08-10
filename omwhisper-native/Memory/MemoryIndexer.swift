//
//  MemoryIndexer.swift
//  OmWhisper
//
//  Turns snapshots into passage vectors: strip per-app boilerplate, chunk,
//  embed, store. Runs off the UI thread and never blocks capture or search.
//
//  Incremental indexing and the one-time backfill are the SAME code path --
//  both just process "snapshots with no passages yet". That makes a missed
//  nudge self-healing and an interrupted backfill resumable, with no cursor
//  to persist and get wrong.
//

import Foundation

nonisolated final class MemoryIndexer: Sendable {
    private let embedder: MemoryEmbedder

    init?(embedder: MemoryEmbedder? = AppleEmbedder()) {
        guard let embedder else { return nil }
        self.embedder = embedder
    }

    /// Boilerplate is computed per app from the batch being indexed. Per-app is
    /// load-bearing: measured on the real store, a median Arc snapshot is 58%
    /// sidebar/pinned-tab chrome, and computing document frequency across all
    /// apps at once found a third as many tokens and barely helped.
    func index(snapshot: MemorySnapshot, boilerplate: Set<String>, in store: MemoryStore) throws {
        guard let id = snapshot.id else { return }
        let cleaned = SemanticIndexing.strip(snapshot.content, boilerplate: boilerplate)
        var rows: [(text: String, vector: Data)] = []
        for p in SemanticIndexing.passages(cleaned) {
            // Reuse before embedding. Capture takes the same window every few
            // seconds and one line changes, so most passages of a "new"
            // snapshot are byte-identical to ones already embedded -- measured
            // at 57% of all passages, one text 285 times over. Embedding was
            // 57.7% of a core, sustained, and the machine's top battery drain.
            if let cached = try store.vectorForText(hash: MemoryStore.contentHash(p)) {
                rows.append((p, cached))
                continue
            }
            guard let v = embedder.vector(p) else { continue }
            rows.append((p, SemanticIndexing.encode(v)))
        }
        // Even with no embeddable passages, write the (empty) result so this
        // snapshot leaves the pending set -- otherwise one unembeddable row
        // would be retried forever and block the backfill behind it.
        try store.replacePassages(snapshotId: id, passages: rows)
    }

    /// Process pending snapshots in batches until none remain. Serves both the
    /// one-time catch-up (~20 min for 6,000 snapshots) and the steady-state
    /// trickle of one snapshot per capture.
    @discardableResult
    func processPending(store: MemoryStore, batch: Int = 50, maxBatches: Int = Int.max,
                        progress: @Sendable (Int) -> Void = { _ in }) throws -> Int {
        var done = 0
        var batches = 0
        while batches < maxBatches {
            let pending = try store.snapshotsMissingPassages(limit: batch)
            guard !pending.isEmpty else { break }
            for (_, group) in Dictionary(grouping: pending, by: \.appName) {
                let boilerplate = SemanticIndexing.boilerplateTokens(perAppTexts: group.map(\.content))
                for snapshot in group {
                    try index(snapshot: snapshot, boilerplate: boilerplate, in: store)
                    done += 1
                }
            }
            batches += 1
            progress(done)
        }
        return done
    }
}
