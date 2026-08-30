//
//  LongFormBackends.swift
//  OmWhisper
//
//  Which local backend should do work with LARGE inputs -- meeting summaries,
//  chronicles, brain-dump structuring -- as opposed to polishing a sentence of
//  dictation.
//
//  The ORDER differs from short-form dictation on purpose, and the difference
//  is measured, not stylistic. Dictation is where latency dominates: on this
//  Mac, SystemLLM answers in ~2.1s while Ollama qwen3.5 takes 36.4s from cold,
//  and Ollama evicts after ~5 minutes idle, so a first dictation after any gap
//  blows the 30s dictation timeout and pastes raw text. Long-form work has the
//  opposite shape: nobody is waiting on a keystroke, and what matters is how
//  much fits in one call -- 12,000 characters against 1,800 turns an hour-long
//  call into ~6 passes instead of ~40, and every extra compression pass loses
//  detail.
//
//  So both paths share ONE resolution rule -- `candidates(...)` below -- and
//  differ only in which on-device order they hand it. Until 2026-08-30 they did
//  not: short-form resolved Default-on-Default to *nothing*, so enabling polish
//  on a stock install silently did nothing while meetings worked fine.
//
//  The on-device candidates run locally, so preferring the better-fitting one
//  carries no privacy consequence. Cloud used to be absent BY CONSTRUCTION --
//  the enum had no case for it. Since 2026-08-16 features can be pointed at
//  cloud individually, so the guarantee moved into `candidates(...)`: cloud is
//  a candidate ONLY where explicitly chosen, and never a fallback for an
//  on-device backend that failed to answer.
//
//  Pure and free of AppState on purpose -- constructing AppState in a test opens
//  the real history and memory stores.
//

import Foundation

nonisolated enum LongFormBackends {
    enum Kind: Equatable, CaseIterable {
        case ollama
        case system
        /// Only ever reachable when a feature is EXPLICITLY set to cloud --
        /// see `candidates(...)`. Never a fallback.
        case cloud
    }

    /// Ordered candidates for one feature.
    ///
    /// The rule this function exists to enforce: **cloud appears only when
    /// explicitly chosen.** An on-device choice that is unavailable falls back
    /// to the other on-device backend and then to nothing. A fallback that
    /// reached for cloud because Ollama was not answering would look like
    /// resilience and be a privacy breach.
    ///
    /// The reverse is allowed: a cloud choice may fall back on-device, which
    /// is less capable but never less private.
    ///
    /// Until 2026-08-16 this guarantee was expressed by `Kind` having no cloud
    /// case at all, pinned by a test on `allCases`. Per-feature cloud made that
    /// impossible, so the guarantee moved here -- and the test moved with it
    /// rather than being deleted.
    static func candidates(choice: FeatureBackend,
                           defaultChoice: FeatureBackend,
                           ollamaConfigured: Bool,
                           systemAvailable: Bool,
                           cloudConfigured: Bool) -> [Kind] {
        candidates(choice: choice, defaultChoice: defaultChoice,
                   onDevice: order(ollamaConfigured: ollamaConfigured,
                                   systemAvailable: systemAvailable),
                   cloudConfigured: cloudConfigured)
    }

    /// The rule itself, with the on-device order supplied by the caller. Short-
    /// form dictation passes a System-first order; long-form passes Ollama-first.
    /// One rule, two orderings — rather than two rules that happen to agree in
    /// some cases, which is what shipped between 2026-08-28 and 2026-08-30.
    static func candidates(choice: FeatureBackend,
                           defaultChoice: FeatureBackend,
                           onDevice: [Kind],
                           cloudConfigured: Bool) -> [Kind] {
        // Resolve the sentinel once. A Default row left on Default means the
        // automatic on-device order — never "no backend".
        var resolved = choice
        if case .useDefault = choice { resolved = defaultChoice }

        switch resolved {
        case .useDefault:
            return onDevice
        // Membership of `onDevice` IS availability — it is built from exactly
        // those two facts — so the rule needs no separate flags.
        case .system:
            return onDevice.contains(.system) ? [.system] + onDevice.filter { $0 != .system } : onDevice
        case .ollama:
            return onDevice.contains(.ollama) ? [.ollama] + onDevice.filter { $0 != .ollama } : onDevice
        case .cloud:
            return (cloudConfigured ? [.cloud] : []) + onDevice
        }
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

    /// Short-form preference: Apple Intelligence FIRST. Measured on this Mac,
    /// SystemLLM answers in ~2.1s while Ollama qwen3.5 takes 36.4s from cold and
    /// Ollama evicts after ~5 minutes idle, so preferring Ollama for dictation
    /// blows the 30s timeout and pastes raw text on the first dictation after
    /// any gap. The long-form order above is the exact opposite, for the exact
    /// opposite reason.
    static func shortFormOrder(ollamaConfigured: Bool, systemAvailable: Bool) -> [Kind] {
        var order: [Kind] = []
        if systemAvailable { order.append(.system) }
        if ollamaConfigured { order.append(.ollama) }
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
        case .cloud:  return "Cloud"
        }
    }
}
