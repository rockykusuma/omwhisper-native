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

import AppKit
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

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A color that resolves to `light` under Aqua and `dark` under Dark Aqua,
/// following the host window's effective appearance. Bridged through a dynamic
/// `NSColor` so it re-resolves live when the system theme flips — the whole
/// Porcelain palette is built on this so the hub tracks system dark mode.
private func porcelainAdaptive(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(hex: dark)
            : NSColor(hex: light)
    })
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

/// Porcelain — the palette for every app window (hub, Settings, menu-bar panel).
/// Light "porcelain" (F7FAF8 canvas, forest ink) in Light Mode; the brand's dark
/// emerald-on-green-black identity in Dark Mode. Adaptive per system appearance
/// (decided 2026-07-10, R chose "adapt to system dark" over the original
/// always-light rule — the dark values reuse the existing HUD token family so
/// the app reads as one brand across both themes). The overlay HUD stays
/// hard-dark via the `om*` tokens regardless — only these hub tokens adapt.
extension Color {
    enum Porcelain {
        static let bg = porcelainAdaptive(light: 0xF7FAF8, dark: 0x0A0F0D)
        static let panel = porcelainAdaptive(light: 0xFFFFFF, dark: 0x0E1512)
        static let panel2 = porcelainAdaptive(light: 0xF0F5F1, dark: 0x16211C)
        static let ink = porcelainAdaptive(light: 0x0F241B, dark: 0xEAFFF5)
        // Dark `dim` brightened above the HUD's omDim (5D7A6E) so caption text
        // stays AA-legible on the darker hub card panel.
        static let dim = porcelainAdaptive(light: 0x66796F, dark: 0x8CA69B)
        static let hair = porcelainAdaptive(light: 0xE3ECE5, dark: 0x243029)
        static let emerald = porcelainAdaptive(light: 0x0FA97C, dark: 0x34D399)
        static let mint = porcelainAdaptive(light: 0x0D9488, dark: 0x6EE7B7)
        static let teal = porcelainAdaptive(light: 0x0E7490, dark: 0x2DD4BF)
        /// Card/window depth shadow — green-tinted on light; near-black on dark
        /// (green-tinted shadow reads as a halo on a dark ground).
        static let shadow = porcelainAdaptive(light: 0x173A2C, dark: 0x000000)

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
