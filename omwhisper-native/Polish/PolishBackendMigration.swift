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
    /// Bumped when the rules change, so a machine that ran an earlier, buggier
    /// version gets the corrections. A Bool could not express that: the
    /// 2026-08-28 version wrote cloud into unset slots and switched polish off
    /// for explicit-choice users, then set its flag, locking those accounts out
    /// of every later fix. Safe to re-run — the plan never overwrites an
    /// explicit choice.
    static let currentVersion = 2

    /// `defaultIsCloud` is an INPUT, not an output: the plan still cannot write
    /// the Default row (Rule 2), but it must know whether leaving a feature on
    /// Default would send its data off the Mac.
    static func plan(old: String?,
                     existingDictation: FeatureBackend,
                     existingReplyAssist: FeatureBackend,
                     ollamaModel: String,
                     defaultIsCloud: Bool) -> Plan {
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
            // keeps that via its new toggle.
            //
            // Reply Assist is switched off ONLY where leaving it on Default
            // would now egress. Disabling it unconditionally was a regression:
            // on a stock install the Default row is `.useDefault`, which
            // resolves on-device, so turning the feature off gained no privacy
            // and silently killed something the user had enabled.
            let replyWouldEgress = defaultIsCloud && existingReplyAssist == .useDefault
            return Plan(dictationPolishEnabled: explicitDictation,
                        dictationBackend: nil,
                        replyAssistBackend: nil,
                        replyAssistEnabled: replyWouldEgress ? false : nil)
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
