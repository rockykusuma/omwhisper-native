//
//  ShortFormBackend.swift
//  OmWhisper
//
//  Which backend polishes a sentence of dictation, and drafts a reply.
//
//  Returns a FeatureBackend, NOT a model-less kind. That is the whole design
//  decision: `LongFormBackends.Kind` has no model field, so an earlier attempt
//  to "share one rule" by routing short-form through it threw away WHICH Ollama
//  model the user picked — a row set to `Ollama · qwen3.5:latest` silently ran
//  Apple Intelligence, or nothing, whenever the shared `ollamaModel` happened to
//  be empty. Sharing a rule is not worth losing information the rule needs.
//
//  The long-form path keeps its own ordering for a measured reason: dictation is
//  latency-bound (SystemLLM ~2.1s vs Ollama qwen3.5 36.4s cold, evicted after
//  ~5 minutes idle) so short-form prefers Apple Intelligence, while long-form is
//  envelope-bound so it prefers Ollama. The duplication is one `if` in each
//  place, and it is honest.
//

import Foundation

nonisolated enum ShortFormBackend {
    /// The backend that will actually run, model included. nil means none:
    /// dictation polish is switched off, or nothing on this Mac can serve it.
    /// Callers treat nil as a configuration state, never as a failure.
    ///
    /// Cloud is returned only when explicitly chosen — never as a fallback for
    /// an on-device backend that is missing. The reverse is allowed.
    static func resolve(feature: AIFeature,
                        choice: FeatureBackend,
                        defaultChoice: FeatureBackend,
                        sharedOllamaModel: String,
                        systemAvailable: Bool,
                        dictationPolishEnabled: Bool) -> FeatureBackend? {
        // The toggle is dictation polish's own off-switch, not a global one.
        // Reply Assist has `replyAssistEnabled`.
        if feature == .dictationPolish, !dictationPolishEnabled { return nil }

        /// Apple Intelligence first, then Ollama — the short-form order.
        func automatic() -> FeatureBackend? {
            if systemAvailable { return .system }
            return sharedOllamaModel.isEmpty ? nil : .ollama(model: sharedOllamaModel)
        }

        switch choice == .useDefault ? defaultChoice : choice {
        case .useDefault:
            return automatic()
        case .system:
            // An unavailable choice falls back on-device, never to cloud.
            return systemAvailable ? .system : (sharedOllamaModel.isEmpty ? nil : .ollama(model: sharedOllamaModel))
        case .ollama(let model):
            // A row carries its own model; the shared setting is the fallback,
            // not the gate. Gating on the shared value is what discarded an
            // explicit choice before.
            let name = model.isEmpty ? sharedOllamaModel : model
            return name.isEmpty ? automatic() : .ollama(model: name)
        case .cloud:
            return .cloud
        }
    }

    /// Whether this feature's own row, or the Default row it defers to, NAMES
    /// Apple Intelligence. Distinct from what `resolve` returns, which may have
    /// fallen back — the nudge exists to explain a choice that could not be
    /// honoured, so it must not fire for a choice nobody made.
    static func wantsSystem(choice: FeatureBackend, defaultChoice: FeatureBackend) -> Bool {
        (choice == .useDefault ? defaultChoice : choice) == .system
    }

    /// Whether a feature's data would leave the Mac. Resolver-independent by
    /// construction: cloud is reachable only from an explicit choice on either
    /// path, so this is the right answer for long-form features too.
    static func egresses(choice: FeatureBackend, defaultChoice: FeatureBackend) -> Bool {
        (choice == .useDefault ? defaultChoice : choice) == .cloud
    }
}
