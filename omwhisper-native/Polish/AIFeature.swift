//
//  AIFeature.swift
//  OmWhisper
//
//  Which AI backend each feature uses. One choice per feature rather than one
//  global setting, because cloud introduces an axis a single control cannot
//  express: whether that feature's data leaves the Mac. A day of screen text,
//  a recorded call with other people in it, and one dictated sentence are not
//  the same decision.
//
//  Pure and free of AppState on purpose -- constructing AppState in a test
//  opens the real history and memory stores.
//

import Foundation

/// The features that choose a backend. Granularity follows the DATA that would
/// egress, not the button pressed: all five meeting functions (summary, title,
/// regenerate, Ask, follow-up email) touch the same recording, so splitting
/// them would let a user send a summary to the cloud but refuse a question
/// about it -- incoherent, since the summary already went.
nonisolated enum AIFeature: String, CaseIterable, Sendable {
    case dictationPolish
    case replyAssist
    case meetings
    case chronicles
    case brainDump

    var displayName: String {
        switch self {
        case .dictationPolish: return "Dictation polish"
        case .replyAssist:     return "Reply Assist"
        case .meetings:        return "Meeting summaries"
        case .chronicles:      return "Chronicles"
        case .brainDump:       return "Brain-dump"
        }
    }

    /// Persisted. Never rename one: a changed key silently resets that feature
    /// to Default on the next launch.
    var settingsKey: String { "aiBackend.\(rawValue)" }
}

/// One feature's choice. `useDefault` defers to the Default row, which is what
/// keeps the common case a single control.
nonisolated enum FeatureBackend: Equatable, Hashable, Sendable {
    case useDefault
    case system
    case ollama(model: String)
    case cloud

    /// Stored as a string rather than Codable JSON: it goes in UserDefaults,
    /// is read on every backend selection, and is worth being able to read by
    /// eye in a defaults dump.
    var rawValue: String {
        switch self {
        case .useDefault:        return "default"
        case .system:            return "system"
        case .cloud:             return "cloud"
        case .ollama(let model): return "ollama:\(model)"
        }
    }

    /// nil for anything unrecognised, so the caller falls back to Default.
    /// Deliberately never guesses -- above all it must never resolve an
    /// unknown value to `.cloud`.
    init?(rawValue: String) {
        switch rawValue {
        case "default": self = .useDefault
        case "system":  self = .system
        case "cloud":   self = .cloud
        default:
            // Drop only the "ollama:" prefix and keep the rest verbatim: real
            // model names are "qwen3.5:latest", and splitting on every colon
            // would store "qwen3.5" and quietly select a model the user does
            // not have.
            guard rawValue.hasPrefix("ollama:") else { return nil }
            let model = String(rawValue.dropFirst("ollama:".count))
            guard !model.isEmpty else { return nil }
            self = .ollama(model: model)
        }
    }
}
