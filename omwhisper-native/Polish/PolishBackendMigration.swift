//
//  PolishBackendMigration.swift
//  OmWhisper
//
//  One-time move from the old global `polishBackend` to per-feature slots.
//
//  The rule that matters is what this does NOT touch. `polishBackend` governed
//  dictation polish and Reply Assist, and only when those were left on Default.
//  Meetings, chronicles and brain-dump have always resolved through
//  `defaultBackend`. Writing the old global into `defaultAIBackend` would
//  therefore move a recorded call's transcript to whatever the user had picked
//  for polishing a sentence — cloud included — with nothing on screen changing.
//
//  `Plan` has no field for the global or for the long-form features, so that
//  mistake is unrepresentable rather than merely discouraged.
//

import Foundation

nonisolated enum PolishBackendMigration {
    struct Plan: Equatable {
        var dictationPolishEnabled: Bool
        /// nil means "leave that slot exactly as it is".
        var dictationBackend: FeatureBackend?
        var replyAssistBackend: FeatureBackend?
    }

    /// `old` is the raw stored `polishBackend` string, nil when absent.
    /// `ollamaModel` is the separate setting the old global did not carry.
    static func plan(old: String?,
                     existingDictation: FeatureBackend,
                     existingReplyAssist: FeatureBackend,
                     ollamaModel: String) -> Plan {
        let off = Plan(dictationPolishEnabled: false, dictationBackend: nil, replyAssistBackend: nil)
        guard let old else { return off }

        let migrated: FeatureBackend
        switch old {
        case "disabled": return off
        case "system":   migrated = .system
        case "cloud":    migrated = .cloud
        case "ollama":   migrated = .ollama(model: ollamaModel)
        default:         return off   // unrecognised must not switch anything on
        }

        // Only fill a slot the user never set themselves.
        func fill(_ existing: FeatureBackend) -> FeatureBackend? {
            existing == .useDefault ? migrated : nil
        }
        return Plan(dictationPolishEnabled: true,
                    dictationBackend: fill(existingDictation),
                    replyAssistBackend: fill(existingReplyAssist))
    }
}
