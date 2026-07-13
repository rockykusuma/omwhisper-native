//
//  CrossLingual.swift
//  OmWhisper
//
//  Pure decisions for cross-lingual dictation (F4). Deliberately nonisolated and
//  WhisperKit-free so they unit-test without MainActor or the app-only engine.
//  See docs/superpowers/specs/2026-07-13-cross-lingual-dictation-design.md.
//

import Foundation

nonisolated enum CrossLingual {
    /// The built-in Translate style's fixed UUID (see PolishStyles). Cross-lingual
    /// supersedes it — folding "translate into {language}" on top of our own
    /// translate prompt would double-translate.
    static let translateStyleID = UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000004")!

    /// Which engine actually transcribes. Cross-lingual forces Whisper (the only
    /// multilingual engine); otherwise the user's pick stands.
    static func engineKind(base: EngineKind, crossLingual: Bool) -> EngineKind {
        crossLingual ? .whisper : base
    }

    /// True when Whisper should translate to English in-engine (the degraded
    /// "lane b" fallback): only when cross-lingual is on AND there's no polish
    /// backend to do the higher-quality LLM translate.
    static func whisperTranslatesInEngine(crossLingual: Bool, hasBackend: Bool) -> Bool {
        crossLingual && !hasBackend
    }

    /// The combined translate + normalize + apply-active-style prompt, as a
    /// PolishStyle the existing backend call consumes. `spokenLanguage` is the
    /// human-readable name ("Telugu"); "" or "auto" means auto-detect.
    static func style(spokenLanguage: String, activeStyle: PolishStyle?) -> PolishStyle {
        let source = spokenLanguage.isEmpty || spokenLanguage.lowercased() == "auto"
            ? "another language (possibly mixed with English)"
            : "\(spokenLanguage) (possibly mixed with English)"
        var prompt = """
            The following was dictated in \(source). Translate and normalize it \
            into fluent, natural English — fix the code-switching, do not \
            translate word-for-word.
            """
        // Compose the user's active style, EXCEPT the Translate style (would
        // double-translate) and the no-style case → neutral clean English.
        if let activeStyle, activeStyle.id != translateStyleID {
            prompt += "\n\nAdditionally, follow this style instruction: \(activeStyle.prompt)"
        }
        prompt += "\n\nOutput only the English text, nothing else."
        return PolishStyle(
            id: UUID(uuidString: "F4000000-0000-4000-8000-000000000001")!,
            name: "Cross-Lingual",
            prompt: prompt,
            isBuiltIn: true
        )
    }
}
