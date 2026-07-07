//
//  PolishBackend.swift
//  OmWhisper
//
//  AI text polish contract. Backends (M3): SystemLLM (Foundation Models, default),
//  Ollama, CloudLLM (OpenAI-compatible, keys in Keychain) — the latter two are a
//  separate sub-project. See docs/superpowers/specs/2026-07-07-m3-core-ai-polish-design.md.
//

import Foundation

// nonisolated: plain data, no MainActor affinity — without this, the project's
// MainActor-by-default setting also pins the synthesized Equatable/Hashable
// conformance, which then can't be used from a nonisolated context (e.g. tests).
nonisolated struct PolishStyle: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var prompt: String
    var isBuiltIn: Bool
    /// Only meaningful for the Translate style; false for every other style.
    var requiresTargetLanguage: Bool = false
}

protocol PolishBackend: Sendable {
    /// `targetLanguage` is non-nil only when `style.requiresTargetLanguage`.
    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String
}
