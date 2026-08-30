//
//  PolishBackendMigration.swift
//  OmWhisper
//
//  One-time move from the old global `polishBackend` to per-feature slots.
//
//  Two rules, both learned from a review of the first version:
//
//  1. **A migration may make things more private, never less.** If the faithful
//     result would be cloud, this writes nothing and leaves the feature on
//     Default, which resolves on-device. Someone who genuinely had cloud polish
//     re-picks it once, in a screen that names it. The alternative — writing a
//     cloud choice into a slot the user never set — is an upgrade moving data
//     off the Mac with nothing on screen changing.
//
//  2. **Never touch the global or a long-form feature.** `polishBackend`
//     governed dictation polish and Reply Assist only. `Plan` has no field for
//     `defaultAIBackend`, meetings, chronicles or brain-dump, so that is
//     unrepresentable rather than merely discouraged.
//

import Foundation

nonisolated enum PolishBackendMigration {
    struct Plan: Equatable {
        var dictationPolishEnabled: Bool
        /// nil means "leave that slot exactly as it is".
        var dictationBackend: FeatureBackend?
        var replyAssistBackend: FeatureBackend?
        /// Set only when the old global said Disabled — see below.
        var replyAssistEnabled: Bool?
    }

    /// `old` is the raw stored `polishBackend` string, nil when absent.
    /// `ollamaModel` is the separate setting the old global did not carry.
    static func plan(old: String?,
                     existingDictation: FeatureBackend,
                     existingReplyAssist: FeatureBackend,
                     ollamaModel: String) -> Plan {
        // An explicit per-feature choice already worked on the old build:
        // activePolishBackend switched on `backend(for:)` FIRST and only fell
        // through to the global on .useDefault. Keying the toggle off the global
        // alone silently switched polish OFF for those users.
        let explicitDictation = existingDictation != .useDefault

        guard let old else {
            return Plan(dictationPolishEnabled: explicitDictation,
                        dictationBackend: nil, replyAssistBackend: nil, replyAssistEnabled: nil)
        }

        if old == "disabled" {
            // The global meant "no AI" for BOTH short-form features. Dictation
            // keeps that via its new toggle. Reply Assist has no equivalent
            // backend value, and leaving it on Default would now resolve through
            // the Default row — cloud included — so its own switch carries the
            // meaning across. It could not have worked before anyway: every
            // draft failed with NO AI BACKEND.
            return Plan(dictationPolishEnabled: explicitDictation,
                        dictationBackend: nil,
                        replyAssistBackend: nil,
                        replyAssistEnabled: existingReplyAssist == .useDefault ? false : nil)
        }

        // Two separate questions, and conflating them was a bug the tests caught:
        // "was polish working before" and "is there something safe to write".
        // Declining to carry a CLOUD choice across must not also switch polish
        // off — the user wanted their dictation polished; this only refuses to
        // send it off the Mac, so it keeps working through the on-device order.
        let wasOn: Bool
        let migrated: FeatureBackend?
        switch old {
        case "system":
            wasOn = true;  migrated = .system
        case "ollama":
            // An empty model produced NO polish on the old build, and
            // `.ollama(model: "")` encodes as "ollama:", which
            // FeatureBackend(rawValue:) rejects — the slot would read back as
            // Default and resolve through the Default row instead.
            wasOn = !ollamaModel.isEmpty
            migrated = ollamaModel.isEmpty ? nil : .ollama(model: ollamaModel)
        case "cloud":
            wasOn = true;  migrated = nil     // Rule 1: never write cloud
        default:
            wasOn = false; migrated = nil     // unrecognised must not switch anything on
        }

        guard let migrated else {
            return Plan(dictationPolishEnabled: wasOn || explicitDictation,
                        dictationBackend: nil, replyAssistBackend: nil, replyAssistEnabled: nil)
        }

        func fill(_ existing: FeatureBackend) -> FeatureBackend? {
            existing == .useDefault ? migrated : nil
        }
        return Plan(dictationPolishEnabled: true,
                    dictationBackend: fill(existingDictation),
                    replyAssistBackend: fill(existingReplyAssist),
                    replyAssistEnabled: nil)
    }
}
