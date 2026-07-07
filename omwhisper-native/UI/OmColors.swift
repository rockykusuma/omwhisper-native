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
