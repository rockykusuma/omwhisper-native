//
//  WhisperModel.swift
//  OmWhisper
//
//  User-selectable Whisper variant + pure mapping helpers. No WhisperKit types,
//  so it backs a UserDefaults setting and is unit-testable without linking
//  WhisperKit into the test target (WhisperKit is app-target-only, like FluidAudio).
//

import Foundation

nonisolated enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case base, small, largeV3Turbo   // largeV3Turbo is the default

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base: "Base"
        case .small: "Small"
        case .largeV3Turbo: "Large v3"
        }
    }

    var subtitle: String {
        switch self {
        case .base: "~150 MB · fastest, lower accuracy"
        case .small: "~500 MB · balanced"
        case .largeV3Turbo: "~950 MB · most accurate, best multilingual"
        }
    }

    /// Exact `argmaxinc/whisperkit-coreml` variant folder name. The `.largeV3Turbo`
    /// case points at the FULL large-v3 build (compressed `_947MB`), WhisperKit's
    /// flagship — the v20240930 "turbo" checkpoint returns empty output in both
    /// WhisperKit 0.18.0 and 1.0.0 (base/small work; every turbo build/compute/
    /// prefill/version combo produced text=""). Case name kept to avoid churning the
    /// persisted UserDefaults value; the user-facing label is just "Large v3".
    static func whisperKitModelID(for model: WhisperModel) -> String {
        switch model {
        case .base: "openai_whisper-base"
        case .small: "openai_whisper-small"
        case .largeV3Turbo: "openai_whisper-large-v3_947MB"
        }
    }

    /// "auto" → nil (WhisperKit auto-detects); otherwise the language code.
    static func decodeLanguage(_ code: String) -> String? {
        code == "auto" ? nil : code
    }

    /// Custom vocabulary → a Whisper decoding prompt (its context-biasing input).
    /// Empty terms → empty string (caller passes no promptTokens).
    static func vocabularyPrompt(_ terms: [String]) -> String {
        terms.joined(separator: ", ")
    }
}
