//
//  CloudProviderKind.swift
//  OmWhisper
//
//  User-selectable cloud transcription provider (CloudEngine dispatches on it).
//  Pure — no networking — so it backs a UserDefaults setting and is unit-testable.
//  Two shapes: streaming (WebSocket, live partials) and batch (POST audio, one
//  final on release). See docs/superpowers/specs/2026-07-12-cloud-multi-provider-design.md.
//

import Foundation

nonisolated enum CloudProviderKind: String, CaseIterable, Identifiable, Sendable {
    case assemblyAI, deepgram, elevenLabs, openAI, groq

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .assemblyAI: "AssemblyAI"
        case .deepgram: "Deepgram"
        case .elevenLabs: "ElevenLabs Scribe"
        case .openAI: "OpenAI"
        case .groq: "Groq (Whisper)"
        }
    }

    /// Live partials (streaming WS) vs. text-on-release (batch POST).
    var isStreaming: Bool {
        switch self {
        case .assemblyAI, .deepgram: true
        case .elevenLabs, .openAI, .groq: false
        }
    }

    /// Distinct Keychain generic-password account per provider. `.assemblyAI` keeps
    /// its existing account string so keys saved under M4.2 still load.
    var keychainAccount: String {
        switch self {
        case .assemblyAI: "assemblyai-api-key"
        case .deepgram: "deepgram-api-key"
        case .elevenLabs: "elevenlabs-api-key"
        case .openAI: "cloud-stt-openai-api-key"
        case .groq: "groq-api-key"
        }
    }

    var signupHint: String {
        switch self {
        case .assemblyAI: "assemblyai.com"
        case .deepgram: "deepgram.com"
        case .elevenLabs: "elevenlabs.io"
        case .openAI: "platform.openai.com"
        case .groq: "console.groq.com"
        }
    }

    var privacyNote: String {
        "Streams your voice \(isStreaming ? "live " : "")to \(displayName) (a third-party service) while dictating. Requires your own API key from \(signupHint)."
    }
}
