//
//  LongFormBackends.swift
//  OmWhisper
//
//  Which local backend should do work with LARGE inputs -- meeting summaries,
//  chronicles, brain-dump structuring -- as opposed to polishing a sentence of
//  dictation.
//
//  Deliberately NOT a function of AppState.polishBackend. That setting says
//  what should polish your dictation, where latency dominates: measured on this
//  Mac, SystemLLM answers in ~2.1s while Ollama qwen3.5 takes 36.4s from cold,
//  and Ollama evicts after ~5 minutes idle, so a first dictation after any gap
//  blows the 30s dictation timeout and pastes raw text. Long-form work has the
//  opposite shape: nobody is waiting on a keystroke, and what matters is how
//  much fits in one call -- 12,000 characters against 1,800 turns an hour-long
//  call into ~6 passes instead of ~40, and every extra compression pass loses
//  detail.
//
//  Both candidates run on-device, so preferring the better-fitting one carries
//  no privacy consequence. Cloud is absent BY CONSTRUCTION rather than by a
//  check: recordings and chronicles never reach a cloud provider.
//
//  Pure and free of AppState on purpose -- constructing AppState in a test opens
//  the real history and memory stores.
//

import Foundation

nonisolated enum LongFormBackends {
    /// CaseIterable so a test can assert cloud never joins this list.
    enum Kind: Equatable, CaseIterable {
        case ollama
        case system
    }

    /// Preference order, best fit first. Empty when nothing is usable: callers
    /// distinguish "no backend at all" from "every backend failed", so this
    /// must not invent a fallback.
    ///
    /// - Parameters:
    ///   - ollamaConfigured: an Ollama model name is set (`!ollamaModel.isEmpty`).
    ///   - systemAvailable: `SystemLLM.isAvailable()`, which since 2026-08-01
    ///     checks language support as well as availability.
    static func order(ollamaConfigured: Bool, systemAvailable: Bool) -> [Kind] {
        var order: [Kind] = []
        if ollamaConfigured { order.append(.ollama) }
        if systemAvailable { order.append(.system) }
        return order
    }

    /// What to show the user for a backend that produced a summary. The model
    /// name is included deliberately: preferring Ollama is only better if the
    /// Ollama model is good, and this app cannot judge that. A poor summary
    /// labelled "Ollama (llama3.2:latest)" tells you what to change, where
    /// "Ollama" alone does not -- that model was measured answering "Nothing
    /// relevant." to questions the transcript plainly answered.
    static func displayName(for kind: Kind, ollamaModel: String) -> String {
        switch kind {
        case .ollama: return ollamaModel.isEmpty ? "Ollama" : "Ollama (\(ollamaModel))"
        case .system: return "Apple Intelligence"
        }
    }
}
