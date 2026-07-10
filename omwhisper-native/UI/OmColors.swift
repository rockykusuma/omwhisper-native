//
//  OmColors.swift
//  OmWhisper
//
//  Fixed, dark-only overlay palette — see docs/OVERLAY_SPEC.md §2. Defined in
//  code, not an Assets.xcassets colorset: these must never adapt to system
//  appearance (the HUD floats over arbitrary content and needs the
//  green-black brand ground regardless of light/dark mode) — a colorset could
//  silently pick up a light-mode variant; a code constant can't.
//
//  Base colors are full-strength; usage-site opacity (e.g. "omBackground @
//  92%") is applied with `.opacity(_:)` where each color is used, since some
//  usages need a dynamic/different opacity (e.g. the orb's amplitude-driven
//  blob alpha) even when they share the same base hex.
//

import SwiftUI

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Color {
    static let omBackground = Color(hex: 0x0A0F0D)
    static let omBorder = Color(hex: 0x34D399)
    static let omEmerald = Color(hex: 0x34D399)
    static let omTeal = Color(hex: 0x2DD4BF)
    static let omMint = Color(hex: 0x6EE7B7)
    static let omGlyphCore = Color(hex: 0xEAFFF5)
    static let omGlyphPeak = Color.white
    static let omVolatile = Color(hex: 0x6EE7B7)
    static let omError = Color(hex: 0xF87171)
    /// Dark under-copy behind the glyph fill (§5.3) — keeps it legible when the
    /// field behind it is bright. "omTeal 900-ish".
    static let omGlyphUnderCopy = Color(hex: 0x04342C)
}

/// Porcelain — the light palette for every app window (hub, Settings, menu-bar
/// panel). Fixed values, not adaptive to system appearance, for the same reason
/// as the dark HUD tokens above: see docs/DESIGN_DIRECTION.md and
/// .claude/skills/omwhisper-design/SKILL.md §1 ("Scope rule" — dark palette is
/// HUD + onboarding ONLY, everything else is Porcelain).
extension Color {
    enum Porcelain {
        static let bg = Color(hex: 0xF7FAF8)
        static let panel = Color.white
        static let panel2 = Color(hex: 0xF0F5F1)
        static let ink = Color(hex: 0x0F241B)
        static let dim = Color(hex: 0x66796F)
        static let hair = Color(hex: 0xE3ECE5)
        static let emerald = Color(hex: 0x0FA97C)
        static let mint = Color(hex: 0x0D9488)
        static let teal = Color(hex: 0x0E7490)
        /// Card/window depth shadow — green-tinted, never pure black (skill §1).
        static let shadow = Color(hex: 0x173A2C)

        /// Big stat numerals (hub-concept.html `.big`).
        static let numeralGradient = LinearGradient(
            colors: [emerald, teal],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        /// Hover fill.
        static var accentTint: Color { emerald.opacity(0.07) }
        /// Active/selected nav-row fill.
        static var accentTint2: Color { emerald.opacity(0.13) }
    }
}
