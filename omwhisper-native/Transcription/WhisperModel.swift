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
        case .largeV3Turbo: "Large v3 Turbo"
        }
    }

    var subtitle: String {
        switch self {
        case .base: "~150 MB · fastest, lower accuracy"
        case .small: "~500 MB · balanced"
        case .largeV3Turbo: "~630 MB · best accuracy, fast on Apple Silicon"
        }
    }

    /// Exact `argmaxinc/whisperkit-coreml` variant folder name. For large-v3-turbo
    /// use the device-blessed compressed build of the v20240930 (turbo) checkpoint —
    /// the `_turbo`-suffixed variant is a separate extra-optimized build that isn't a
    /// device default and produces empty output in WhisperKit 0.18.0.
    static func whisperKitModelID(for model: WhisperModel) -> String {
        switch model {
        case .base: "openai_whisper-base"
        case .small: "openai_whisper-small"
        case .largeV3Turbo: "openai_whisper-large-v3-v20240930_626MB"
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
