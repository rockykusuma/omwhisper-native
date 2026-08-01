//
//  SystemLLM.swift
//  OmWhisper
//
//  PolishBackend backed by Apple's Foundation Models framework — the default,
//  on-device polish backend. API verified directly against the macOS 26 SDK's
//  FoundationModels.swiftinterface (not guessed):
//    SystemLanguageModel.default.availability -> .available | .unavailable(reason)
//    LanguageModelSession(instructions: String?) — fresh session per call, stateless
//    session.respond(to: String) async throws -> Response<String>, .content is the text
//
//  A fresh LanguageModelSession per polish() call, not a shared/reused session —
//  each call is a one-shot rewrite with its own style-specific instructions, not
//  a multi-turn conversation.
//

import FoundationModels
import Foundation

nonisolated struct SystemLLM: PolishBackend {
    /// Wraps a slow/stuck model call so it can never stall a paste — the old
    /// app hard-capped its (much smaller, bundled) model at 2.5s for the same
    /// reason. 5s starting point for Foundation Models; tune from live testing.
    struct PolishError: Error, LocalizedError {
        var errorDescription: String? { "Polish timed out" }
    }

    static func isAvailable() -> Bool { unavailableReason() == nil }

    /// nil when Foundation Models can actually be used; otherwise a sentence
    /// naming the real cause.
    ///
    /// `availability == .available` alone is NOT a sufficient gate, and that
    /// was a real shipped bug: on an `en_IN` Mac availability reports
    /// `.available` while `supportedLanguages` contains only 23 locales --
    /// `en-US`, `en-GB` and `en-AU`, but not `en-IN` -- so every generation
    /// threw `unsupportedLanguageOrLocale`. Chronicles surfaced that as a raw
    /// alert; polish surfaced nothing at all, because its fail-safe pastes the
    /// original text, so Smart Dictation silently did nothing for months.
    /// Measured on the real machine, not inferred.
    static func unavailableReason() -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .unavailable(.deviceNotEligible):
            return "Apple Intelligence isn't supported on this Mac."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off — enable it in System Settings."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model."
        case .unavailable:
            return "Apple Intelligence is unavailable."
        case .available:
            break
        }

        let current = Locale.current.language
        guard !model.supportedLanguages.contains(current) else { return nil }
        let name = Locale.current.localizedString(forIdentifier: Locale.current.identifier)
            ?? Locale.current.identifier
        return "Apple Intelligence doesn't support your Mac's language (\(name))."
    }

    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        let session = LanguageModelSession(instructions: style.systemPrompt(targetLanguage: targetLanguage))

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let response = try await session.respond(to: text)
                return response.content
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw PolishError()
            }
            guard let result = try await group.next() else { throw PolishError() }
            group.cancelAll()
            return result
        }
    }
}
