//
//  ShortFormBackend.swift
//  OmWhisper
//
//  Which backend polishes a sentence of dictation, and drafts a reply.
//
//  This is NOT a second resolution rule. It calls the same
//  `LongFormBackends.candidates(...)` meetings and chronicles use, handing it a
//  System-first on-device order instead of an Ollama-first one — because
//  dictation is latency-bound (SystemLLM ~2.1s vs Ollama qwen3.5 36.4s cold)
//  while long-form work is envelope-bound.
//
//  Between 2026-08-28 and 2026-08-30 it *was* a second rule, and resolved
//  Default-on-Default to nothing: on a stock install, switching polish on did
//  nothing at all, silently, while a meeting summary on the same machine worked.
//  Found by review, not by use — because the failure mode is silence.
//

import Foundation

nonisolated enum ShortFormBackend {
    /// Ordered candidates for a short-form feature. Empty means no backend:
    /// dictation polish is switched off, or nothing on this Mac can serve it.
    /// Callers treat empty as a configuration state, never as a failure.
    static func candidates(feature: AIFeature,
                           choice: FeatureBackend,
                           defaultChoice: FeatureBackend,
                           ollamaConfigured: Bool,
                           systemAvailable: Bool,
                           cloudConfigured: Bool,
                           dictationPolishEnabled: Bool) -> [LongFormBackends.Kind] {
        // The toggle is dictation polish's own off-switch, not a global one.
        // Reply Assist has `replyAssistEnabled`; coupling them would recreate
        // the bug this file exists to remove, in a new place.
        if feature == .dictationPolish, !dictationPolishEnabled { return [] }
        return LongFormBackends.candidates(
            choice: choice,
            defaultChoice: defaultChoice,
            onDevice: LongFormBackends.shortFormOrder(ollamaConfigured: ollamaConfigured,
                                                      systemAvailable: systemAvailable),
            cloudConfigured: cloudConfigured)
    }
}
