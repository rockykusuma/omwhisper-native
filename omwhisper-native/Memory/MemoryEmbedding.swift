//
//  MemoryEmbedding.swift
//  OmWhisper
//
//  On-device sentence embeddings for Memory search. NLEmbedding was chosen over
//  NLContextualEmbedding by measurement (see the embedding spike): comparable
//  retrieval quality, no downloadable model asset, ~4x cheaper on short text.
//
//  Behind a protocol because the evidence separating the two models is weak --
//  if real-world quality disappoints, a CoreML retrieval-trained bi-encoder
//  drops in here without touching the store or the UI. Apple's NL embeddings
//  are general-purpose similarity models, not retrieval-trained ones.
//

import Foundation
// @preconcurrency: NLEmbedding is not marked Sendable, but the model is
// immutable after creation and vector(for:) is a pure read -- the same
// invariant-we-assert-ourselves pattern as `@preconcurrency import
// AVFoundation` for AVAudioPCMBuffer (see CLAUDE.md, Concurrency).
@preconcurrency import NaturalLanguage

nonisolated protocol MemoryEmbedder: Sendable {
    var dimension: Int { get }
    /// nil when this text cannot be embedded. Callers skip the passage rather
    /// than failing the snapshot -- partial coverage still beats none.
    func vector(_ text: String) -> [Float]?
}

nonisolated struct AppleEmbedder: MemoryEmbedder {
    private let embedding: NLEmbedding

    init?() {
        guard let e = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        embedding = e
    }

    static func isAvailable() -> Bool { NLEmbedding.sentenceEmbedding(for: .english) != nil }

    var dimension: Int { embedding.dimension }

    func vector(_ text: String) -> [Float]? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let v = embedding.vector(for: text) else { return nil }
        return v.map { Float($0) }
    }
}
