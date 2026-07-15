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

    /// Exact `argmaxinc/whisperkit-coreml` variant folder name. `.largeV3Turbo` uses
    /// the FULL large-v3 build (`_947MB`), WhisperKit's flagship — chosen for
    /// RELIABILITY. Two turbo builds were tried and rejected: OpenAI's v20240930
    /// checkpoint returned empty output in every 0.18.0/1.0.0 config, and WhisperKit's
    /// own pruned `large-v3_turbo` transcribed but inconsistently (pruning trades
    /// robustness for speed — it drops some utterances). The full model is slower but
    /// dependable, which matters more for dictation. Case name kept so the persisted
    /// UserDefaults selection isn't churned; the user-facing label is just "Large v3".
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

    /// Strip Whisper's special tokens from segment text.
    /// TranscriptionResult.text is already clean, but TranscriptionSegment.text —
    /// what transcribeSegments must use, since only segments carry timestamps —
    /// comes back raw, e.g.
    /// "<|startoftranscript|><|en|><|transcribe|><|0.00|> hello<|3.44|>".
    /// Collapses the whitespace the removed tokens leave behind.
    static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
