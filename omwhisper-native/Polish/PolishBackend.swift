//
//  PolishBackend.swift
//  OmWhisper
//
//  AI text polish contract. Backends (M3): SystemLLM (Foundation Models, default),
//  Ollama, CloudLLM (OpenAI-compatible, keys in Keychain).
//

import Foundation

struct PolishStyle: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var prompt: String
    // TODO(M3): port the 6 built-in styles + custom style CRUD from the Tauri app's styles.rs
}

protocol PolishBackend: Sendable {
    func polish(_ text: String, style: PolishStyle) async throws -> String
}
