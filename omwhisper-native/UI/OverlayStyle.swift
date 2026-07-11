//
//  OverlayStyle.swift
//  OmWhisper
//
//  The three dictation-overlay presentations (OVERLAY_SPEC §3 / docs/overlay-styles.html).
//  Full = orb + live words; Orb = orb only; Whisper line = micro-ॐ + amplitude bars.
//

import Foundation

nonisolated enum OverlayStyle: String, CaseIterable, Identifiable {
    case full, orb, whisperLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full"
        case .orb: "Orb"
        case .whisperLine: "Whisper line"
        }
    }

    /// One-line card description (verbatim from the mockup).
    var caption: String {
        switch self {
        case .full: "Orb + live words as you speak. See everything land."
        case .orb: "Just the orb, breathing with your voice. No text."
        case .whisperLine: "A tiny pulse of sound. Barely there."
        }
    }
}
