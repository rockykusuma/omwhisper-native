//
//  PorcelainComponents.swift
//  OmWhisper
//
//  Reusable Porcelain-palette building blocks for the hub window (D2) —
//  built once here (D1) so every migrated screen shares one card/nav-row/
//  section-header implementation instead of each screen styling its own.
//  See docs/DESIGN_DIRECTION.md §4 and docs/hub-concept.html (.card, .nav a,
//  .eyebrow/h1 rules) for the exact reference this ports.
//

import AppKit
import SwiftUI

// MARK: - Motion

/// The hub's single spring family (design skill §2: one spring, reused). ~350ms
/// with slight overshoot. `resolved(reduceMotion:)` returns nil under Reduced
/// Motion so callers degrade to no animation (non-negotiable, skill §2.5).
enum PorcelainMotion {
    static let spring: Animation = .spring(response: 0.35, dampingFraction: 0.82)

    static func resolved(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : spring
    }
}

// MARK: - Porcelain appearance (pin the window to light)

extension AppearancePreference {
    /// nil = follow the system; otherwise pin to light/dark. Drives both
    /// SwiftUI `.preferredColorScheme` and the window's NSAppearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Cleans up the hub window's chrome (title-less, transparent titlebar so the
/// Porcelain canvas reads to the top edge) AND applies the user's appearance
/// preference to the window's NSAppearance: nil = follow system, else pin
/// light/dark. Pinning the window is what makes NSAppearance-driven bits (the
/// `porcelainAdaptive` dynamic NSColor, native controls, the titlebar) honor a
/// Light/Dark override even when the whole Mac is the other way.
private struct PorcelainWindowConfigurator: NSViewRepresentable {
    let preferredScheme: ColorScheme?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.appearance = switch preferredScheme {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .none: nil            // follow system
        case .some: nil            // future ColorScheme cases → follow system
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }
}

extension View {
    /// Give the host window a title-less top edge and apply the appearance
    /// preference (`nil` = follow system). Apply once at a window-root view.
    func porcelainWindow(colorScheme: ColorScheme?) -> some View {
        background(PorcelainWindowConfigurator(preferredScheme: colorScheme))
    }
}

// MARK: - PorcelainPage / PorcelainSection

/// Standard scrollable Porcelain content pane: fixed `bg` canvas, consistent
/// outer padding, sections stacked with even gaps. Every settings screen uses
/// this so their spacing/background are identical rather than each re-deriving
/// its own `ScrollView { VStack ... }.background(...)`.
struct PorcelainPage<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Porcelain.bg)
    }
}

/// One card-wrapped settings group with an optional uppercase eyebrow. Always
/// full-column-width (`maxWidth: .infinity`) so stacked cards line up instead
/// of shrink-wrapping to their content (the ragged-width look found live).
struct PorcelainSection<Content: View>: View {
    var eyebrow: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .omCard()
    }
}

// MARK: - porcelainField

private struct PorcelainFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(Color.Porcelain.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.Porcelain.panel2)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.Porcelain.hair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    /// Porcelain text-field chrome (panel2 fill, hair border) — matches the card
    /// system instead of the native inset `.roundedBorder` bezel, which renders
    /// dark under Dark Mode. Apply to `TextField`/`SecureField`.
    func porcelainField() -> some View {
        modifier(PorcelainFieldModifier())
    }
}

// MARK: - omCard

private struct OmCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.Porcelain.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.Porcelain.hair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.Porcelain.shadow.opacity(0.10), radius: 18, x: 0, y: 8)
            .shadow(color: Color.Porcelain.shadow.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

extension View {
    /// hub-concept.html `.card`: white panel, 1pt hair border, 16pt radius,
    /// two-layer green-tinted shadow (soft ambient + tight contact shadow).
    func omCard() -> some View {
        modifier(OmCardModifier())
    }
}

// MARK: - omRowCard

private struct OmRowCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color.Porcelain.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Color.Porcelain.hair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

extension View {
    /// hub-concept.html `.rowc`: panel bg, 1pt hair border, 13pt radius, no
    /// shadow (lighter than `omCard()`) — used for list rows (history,
    /// memory snapshots, chronicle days).
    func omRowCard() -> some View {
        modifier(OmRowCardModifier())
    }
}

// MARK: - OmBrandJewel

/// The brand mark: the dark additive-light orb in a green-black well. Used in
/// the hub sidebar and the menu-bar mini-panel. The dark ground is what makes
/// the orb's ambient drift/breath legible — the Porcelain washes were
/// near-invisible on the light surface. Always `.dark` regardless of app theme;
/// the well delimits it even in Dark Mode. See docs/sidebar-brand-ideas.html.
struct OmBrandJewel: View {
    let appState: AppState
    var size: CGFloat = 38

    private var radius: CGFloat { size * 0.29 }   // 38→11, 40→11.6: same rounding

    var body: some View {
        OmOrbView(appState: appState, palette: .dark)
            .frame(width: size, height: size)
            .background(Color.omBackground)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: Color.omBackground.opacity(0.35), radius: 2, y: 1)
    }
}

// MARK: - NavRow

/// One sidebar navigation row. `isSelected` drives the accent-tint fill and
/// the leading gradient bar (hub-concept.html `.nav a.on`).
struct NavRow: View {
    let icon: String
    let title: String
    var isSelected: Bool = false
    var badge: String? = nil

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isSelected ? Color.Porcelain.emerald : Color.Porcelain.ink.opacity(0.85))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Porcelain.ink)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.Porcelain.mint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.Porcelain.accentTint2))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.Porcelain.accentTint2 : (isHovering ? Color.Porcelain.accentTint : .clear))
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color.Porcelain.emerald, Color.Porcelain.teal], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2.5)
                    .padding(.vertical, 8)
                    .offset(x: -12)
                    .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .center)))
            }
        }
        .onHover { isHovering = $0 }
        .animation(PorcelainMotion.resolved(reduceMotion: reduceMotion), value: isSelected)
        .animation(PorcelainMotion.resolved(reduceMotion: reduceMotion), value: isHovering)
    }
}

// MARK: - SectionHeader

/// hub-concept.html `.eyebrow` + `h1`: an uppercase tracked label above a
/// serif-weight (system semibold, at native sizes per the design skill's
/// "App UI (SwiftUI): system font" rule) title.
struct SectionHeader: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(Color.Porcelain.emerald)
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)
        }
    }
}
