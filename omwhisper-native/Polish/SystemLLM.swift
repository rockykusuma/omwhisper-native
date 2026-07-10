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

    static func isAvailable() -> Bool {
        SystemLanguageModel.default.availability == .available
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
