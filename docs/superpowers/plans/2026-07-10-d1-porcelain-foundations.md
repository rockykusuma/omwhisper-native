# D1 — Porcelain Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay the reusable foundation the Hub window (D2) builds on: Porcelain color
tokens, a palette-parameterized `OmOrbView` that can render on either the dark HUD
ground or the light Porcelain ground without forking the view, three reusable
Porcelain components (`omCard`, `NavRow`, `SectionHeader`), and a debug-only
component gallery window to see all of it rendered together before D2 wires it
into real screens.

**Architecture:** No new subsystems — this is additive UI surface only. Design is
already approved and fully specified (not re-litigated here): `docs/DESIGN_DIRECTION.md`
§1/§4, `docs/hub-concept.html` (canonical color/behavior reference, including its
`orbTheme` JS object for the Porcelain orb variant), and
`.claude/skills/omwhisper-design/SKILL.md` §1 (exact token table).

**Tech Stack:** SwiftUI (`Canvas`, `TimelineView`, `ViewModifier`), Swift Testing.

## Global Constraints

- Porcelain tokens are fixed values, NOT adaptive to system light/dark mode —
  same rule as the existing dark HUD tokens (design skill §1, "Scope rule").
- `OmOrbView`'s existing dark-palette behavior must not change by even one pixel
  — `OverlayView.swift`'s call site passes no palette argument today and must
  keep compiling and rendering identically. The palette parameter defaults to
  `.dark`.
- No new colors beyond what's in the design skill's token table (§1) or
  `hub-concept.html`'s `orbTheme` object — every hex value in this plan is
  copied from one of those two sources, not invented.
- The debug gallery window is `#if DEBUG` only, mirroring
  `Meetings/MeetingSelfTest.swift`'s whole-file gating — it must not exist in
  release builds.
- Component names match `docs/DESIGN_DIRECTION.md` §4's table exactly:
  `omCard()`, nav row, section header — so D2 can consume them without a
  rename pass.

---

## Task 1: Porcelain color tokens

**Files:**
- Modify: `omwhisper-native/UI/OmColors.swift`

**Interfaces:**
- Produces: `Color.Porcelain.{bg,panel,panel2,ink,dim,hair,emerald,mint,teal,shadow,numeralGradient,accentTint,accentTint2}` — consumed by Task 4 (components) and Task 5 (gallery), and later by D2.

- [ ] **Step 1: Add the Porcelain namespace**

In `omwhisper-native/UI/OmColors.swift`, add after the existing `extension Color { ... }` block (keep the existing dark tokens untouched):

```swift
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
```

`Color(hex:)` is the existing `private extension Color` initializer already in
this file (top of file) — no new helper needed.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/OmColors.swift
git commit -m "feat(design): add Porcelain color token namespace"
```

## Task 2: Pure palette-interpolation functions (TDD)

**Files:**
- Modify: `omwhisper-native/UI/OmOrbView.swift`
- Test: `omwhisper-nativeTests/OrbPaletteTests.swift`

**Interfaces:**
- Produces: `nonisolated func lerpRGB(_:_:_:) -> (r: Double, g: Double, b: Double)`,
  `nonisolated func darkBlobAlpha(amp:) -> Double`, `nonisolated func porcelainBlobAlpha(amp:) -> Double`,
  `nonisolated func darkRingAlpha(amp:) -> Double`, `nonisolated func porcelainRingAlpha(amp:) -> Double`
  — pure functions consumed by Task 3's `OrbPalette`.

These formulas come from two sources that must agree: the *dark* ones are
already implemented inline in `OmOrbView` today (`0.16 + amp·0.20` for blob
alpha, `0.10 + amp·0.30` for ring alpha) — Task 3 extracts them, it doesn't
change them. The *porcelain* ones are copied verbatim from `hub-concept.html`'s
`orbTheme` object: `blobA:(a)=>.10+a*.14` and `ring:(a)=>rgba(13,148,136,${.15+a*.3})`.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/OrbPaletteTests.swift`:

```swift
import Testing
@testable import OmWhisper

@Suite("Orb palette interpolation")
struct OrbPaletteTests {
    @Test("lerpRGB returns the low color at t=0")
    func lerpAtZero() {
        let result = lerpRGB((6, 95, 70), (12, 135, 105), 0)
        #expect(result.r == 6)
        #expect(result.g == 95)
        #expect(result.b == 70)
    }

    @Test("lerpRGB returns the high color at t=1")
    func lerpAtOne() {
        let result = lerpRGB((6, 95, 70), (12, 135, 105), 1)
        #expect(result.r == 12)
        #expect(result.g == 135)
        #expect(result.b == 105)
    }

    @Test("lerpRGB interpolates at the midpoint")
    func lerpAtHalf() {
        let result = lerpRGB((0, 0, 0), (10, 20, 40), 0.5)
        #expect(result.r == 5)
        #expect(result.g == 10)
        #expect(result.b == 20)
    }

    @Test("lerpRGB clamps t below 0")
    func lerpClampsLow() {
        let result = lerpRGB((6, 95, 70), (12, 135, 105), -1)
        #expect(result.r == 6)
    }

    @Test("lerpRGB clamps t above 1")
    func lerpClampsHigh() {
        let result = lerpRGB((6, 95, 70), (12, 135, 105), 2)
        #expect(result.r == 12)
    }

    @Test("dark blob alpha matches the existing HUD formula")
    func darkBlobAlphaFormula() {
        #expect(darkBlobAlpha(amp: 0) == 0.16)
        #expect(darkBlobAlpha(amp: 1) == 0.36)
    }

    @Test("porcelain blob alpha matches hub-concept.html's orbTheme.blobA")
    func porcelainBlobAlphaFormula() {
        #expect(porcelainBlobAlpha(amp: 0) == 0.10)
        #expect(abs(porcelainBlobAlpha(amp: 1) - 0.24) < 0.0001)
    }

    @Test("dark ring alpha matches the existing HUD formula")
    func darkRingAlphaFormula() {
        #expect(darkRingAlpha(amp: 0) == 0.10)
        #expect(abs(darkRingAlpha(amp: 1) - 0.40) < 0.0001)
    }

    @Test("porcelain ring alpha matches hub-concept.html's orbTheme.ring")
    func porcelainRingAlphaFormula() {
        #expect(abs(porcelainRingAlpha(amp: 0) - 0.15) < 0.0001)
        #expect(abs(porcelainRingAlpha(amp: 1) - 0.45) < 0.0001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/OrbPaletteTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — "Cannot find 'lerpRGB' in scope" (and the four alpha functions)

- [ ] **Step 3: Add the pure functions to `OmOrbView.swift`**

In `omwhisper-native/UI/OmOrbView.swift`, add these near the existing pure
functions at the top of the file (after `nextSmoothedValue`, before the
`OrbSignal` class):

```swift
// MARK: - Pure palette-interpolation functions (Task 2, D1)

/// Linear-interpolate an RGB triple; `t` is clamped to [0, 1].
nonisolated func lerpRGB(
    _ low: (r: Double, g: Double, b: Double),
    _ high: (r: Double, g: Double, b: Double),
    _ t: Double
) -> (r: Double, g: Double, b: Double) {
    let c = min(1, max(0, t))
    return (
        low.r + (high.r - low.r) * c,
        low.g + (high.g - low.g) * c,
        low.b + (high.b - low.b) * c
    )
}

/// Dark HUD blob alpha (§5.1): `0.16 + amp·0.20`.
nonisolated func darkBlobAlpha(amp: Double) -> Double { 0.16 + amp * 0.20 }

/// Porcelain orb blob alpha, copied from hub-concept.html's `orbTheme.blobA`.
nonisolated func porcelainBlobAlpha(amp: Double) -> Double { 0.10 + amp * 0.14 }

/// Dark HUD ring alpha (§5.2): `0.10 + amp·0.30`.
nonisolated func darkRingAlpha(amp: Double) -> Double { 0.10 + amp * 0.30 }

/// Porcelain orb ring alpha, copied from hub-concept.html's `orbTheme.ring`.
nonisolated func porcelainRingAlpha(amp: Double) -> Double { 0.15 + amp * 0.30 }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/OrbPaletteTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS (9/9)

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/OmOrbView.swift omwhisper-nativeTests/OrbPaletteTests.swift
git commit -m "feat(design): add pure orb palette interpolation functions"
```

## Task 3: `OrbPalette` + wire `OmOrbView` to accept it

**Files:**
- Modify: `omwhisper-native/UI/OmOrbView.swift`

**Interfaces:**
- Consumes: Task 1's `Color.Porcelain.*`, Task 2's `lerpRGB`/`darkBlobAlpha`/`porcelainBlobAlpha`/`darkRingAlpha`/`porcelainRingAlpha`.
- Produces: `struct OrbPalette` with static `.dark`/`.porcelain`; `OmOrbView.palette: OrbPalette` (default `.dark`) — consumed by Task 5's gallery and later by D2.

This task has no new unit tests — Canvas drawing isn't unit-testable (the
project's established position; see `OmOrbView`'s own file-header comment and
`AppleEngine`/`CloudEngine`'s equivalent "verified live" carve-outs elsewhere in
this codebase). It's verified by Task 5's visual gallery instead.

- [ ] **Step 1: Add the `OrbPalette` type**

In `omwhisper-native/UI/OmOrbView.swift`, add directly above `struct OmOrbView: View`:

```swift
/// Parameterizes OmOrbView's layer stack by ground color — dark HUD (additive
/// light on green-black) or Porcelain (watercolor washes on white). Two
/// palettes, one view: see docs/DESIGN_DIRECTION.md §4 ("parameterize the
/// existing layer stack by palette, do not fork the view").
struct OrbPalette {
    let blobColors: [Color]
    let blobAlpha: (Double) -> Double
    let blendMode: GraphicsContext.BlendMode
    let ringColor: Color
    let ringAlpha: (Double) -> Double
    /// Backing plate drawn behind the glyph before the glyph fill itself —
    /// dark under-copy on the HUD (keeps the glyph legible over a bright
    /// field), a soft white halo on Porcelain (hub-concept.html's `under`).
    let glyphUnderColor: Color
    let glyphLow: (r: Double, g: Double, b: Double)
    let glyphHigh: (r: Double, g: Double, b: Double)

    static let dark = OrbPalette(
        blobColors: [.omEmerald, .omTeal, .omMint],
        blobAlpha: darkBlobAlpha,
        blendMode: .plusLighter,
        ringColor: .omMint,
        ringAlpha: darkRingAlpha,
        glyphUnderColor: .omGlyphUnderCopy,
        glyphLow: (234, 255, 245),   // omGlyphCore
        glyphHigh: (255, 255, 255)   // omGlyphPeak
    )

    static let porcelain = OrbPalette(
        blobColors: [Color(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255),
                      Color(red: 0x0D / 255, green: 0x94 / 255, blue: 0x88 / 255),
                      Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x69 / 255)],
        blobAlpha: porcelainBlobAlpha,
        blendMode: .normal,
        ringColor: Color.Porcelain.mint,
        ringAlpha: porcelainRingAlpha,
        glyphUnderColor: .white,
        glyphLow: (6, 95, 70),
        glyphHigh: (12, 135, 105)
    )
}
```

`GraphicsContext.BlendMode.normal` is SwiftUI's plain alpha-compositing mode —
the direct equivalent of hub-concept.html's `comp:'source-over'`.

- [ ] **Step 2: Add the `palette` property and wire it through the draw functions**

In `omwhisper-native/UI/OmOrbView.swift`, add a stored property to `OmOrbView`
(default preserves every existing call site exactly):

```swift
struct OmOrbView: View {
    let appState: AppState
    var palette: OrbPalette = .dark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var signal = OrbSignal()
    @State private var phaseStartedAt = Date()
```

Replace the body of `drawField` (keep the signature and loop structure, change
only what reads from `palette` now):

```swift
    private func drawField(context: inout GraphicsContext, center: CGPoint, amp: Float, t: TimeInterval) {
        let rBase = 13.5, ak1 = 8.0, w1 = 1.5, k2 = 4.0, w2 = 1.0, k3 = 2.0
        context.blendMode = palette.blendMode
        for i in 0..<3 {
            let phi = Double(i) * 2.1
            let path = blobPath(center: center) { theta in
                rBase + ak1 * Double(amp)
                    + sin(3 * theta + t / 0.30 + phi) * (w1 + Double(amp) * k2)
                    + sin(5 * theta - t / 0.20 + phi) * (w2 + Double(amp) * k3)
            }
            let alpha = palette.blobAlpha(Double(amp))
            context.fill(path, with: .color(palette.blobColors[i].opacity(alpha)))
        }
    }
```

Remove the now-unused `private static let blobColors: [Color] = [...]` — it's
replaced by `palette.blobColors`.

Replace the body of `drawRing`:

```swift
    private func drawRing(context: inout GraphicsContext, center: CGPoint, amp: Float, t: TimeInterval, dictation: DictationState, elapsed: TimeInterval) {
        context.blendMode = palette.blendMode

        let restingRadius = 17 + Double(amp) * 10 + sin(t / 0.6) * 1
        let restingAlpha = palette.ringAlpha(Double(amp))
        context.stroke(ringPath(center: center, radius: restingRadius), with: .color(palette.ringColor.opacity(restingAlpha)), lineWidth: 0.75)

        guard dictation == .finalizing else { return }
        let waveProgress = min(1, elapsed / 0.42)
        let waveRadius = restingRadius + waveProgress * (30 - 17)
        let waveAlpha = restingAlpha * (1 - waveProgress)
        context.stroke(ringPath(center: center, radius: waveRadius), with: .color(palette.ringColor.opacity(waveAlpha)), lineWidth: 0.75)
    }
```

Replace the body of `drawGlyph` — same structure, `glyphUnderColor` and
`glyphLuminanceColor` now read from `palette`. **Do not** add an explicit
`context.blendMode` line here: the glyph is meant to inherit whatever
`drawField`/`drawRing` last set (this is already true today for the dark
palette — see the plan's Global Constraints — and the same inheritance makes
Porcelain's glyph render with plain `.normal` compositing correctly, since
`drawRing` runs immediately before `drawGlyph` in `body` and sets
`palette.blendMode` there too):

```swift
    private func drawGlyph(context: inout GraphicsContext, center: CGPoint, amp: Float, glow: Double, t: TimeInterval, dictation: DictationState, elapsed: TimeInterval) {
        let breath = 1 + 0.02 * sin(t / 0.9)
        let size: CGFloat = 20 * breath
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2 + 2, width: size, height: size)
        let lum = min(1, glow * 0.55 + Double(amp) * 0.5)
        let color = glyphLuminanceColor(lum)
        let underRect = rect.offsetBy(dx: 1.5, dy: 1.5)

        guard dictation == .starting else {
            context.fill(OmGlyph().path(in: underRect), with: .color(palette.glyphUnderColor.opacity(0.9)))
            context.fill(OmGlyph().path(in: rect), with: .color(color))
            return
        }

        let drawProgress = min(1, elapsed / 0.24)
        let eased = 1 - pow(1 - drawProgress, 2)
        if eased < 1 {
            let trimmed = OmGlyph().trim(from: 0, to: eased).path(in: rect)
            context.stroke(trimmed, with: .color(color), lineWidth: 2)
            return
        }
        let crossfade = min(1, (elapsed - 0.24) / 0.08)
        context.opacity = crossfade
        context.fill(OmGlyph().path(in: underRect), with: .color(palette.glyphUnderColor.opacity(0.9)))
        context.fill(OmGlyph().path(in: rect), with: .color(color))
        context.opacity = 1
    }

    private func glyphLuminanceColor(_ lum: Double) -> Color {
        let rgb = lerpRGB(palette.glyphLow, palette.glyphHigh, lum)
        return Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255)
    }
```

`drawReducedMotion` also switches its one hardcoded color to the palette, for
consistency (Reduced Motion must look right in both palettes too):

```swift
    private func drawReducedMotion(context: inout GraphicsContext, center: CGPoint, amp: Float, dictation: DictationState, elapsed: TimeInterval) {
        let radius = 13.5
        let alpha = palette.blobAlpha(Double(amp))
        context.blendMode = palette.blendMode
        context.fill(ringPath(center: center, radius: radius), with: .color(palette.blobColors[0].opacity(alpha)))

        let size: CGFloat = 44
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2 + 2, width: size, height: size)
        let fadeIn = dictation == .starting ? min(1, elapsed / 0.24) : 1
        context.opacity = fadeIn
        // glyphLuminanceColor(0) resolves to palette.glyphLow, which for .dark
        // is (234,255,245) == omGlyphCore exactly -- pixel-identical to what
        // this line hardcoded before the palette refactor.
        context.fill(OmGlyph().path(in: rect), with: .color(glyphLuminanceColor(0)))
        context.opacity = 1
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: all tests pass, including the existing overlay/orb-adjacent suites
(`OverlayExitPhaseTests`, `OmOrbSignalTests`) — neither tests pixel output, but
both exercise `AppState`/`OmOrbView`'s surrounding state machine and must stay
green, confirming the default-`.dark` call site in `OverlayView.swift` still
compiles and behaves identically.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/UI/OmOrbView.swift
git commit -m "feat(design): parameterize OmOrbView by OrbPalette (dark/Porcelain)"
```

## Task 4: `omCard`, `NavRow`, `SectionHeader` components

**Files:**
- Create: `omwhisper-native/UI/PorcelainComponents.swift`

**Interfaces:**
- Consumes: Task 1's `Color.Porcelain.*`.
- Produces: `View.omCard() -> some View`; `struct NavRow: View` (`icon: String, title: String, isSelected: Bool, badge: String? = nil`); `struct SectionHeader: View` (`eyebrow: String, title: String`) — consumed by Task 5's gallery and later by D2.

No unit tests — these are pure layout/styling with no logic branches worth
testing beyond "it compiles and looks right," verified visually in Task 5's
gallery, matching this project's established pattern for SwiftUI view code
(e.g. `TranscriptionSettingsView`, `MCPSettingsView` have no view-level tests
either — only their pure logic, where present, is tested).

- [ ] **Step 1: Write the component file**

Create `omwhisper-native/UI/PorcelainComponents.swift`:

```swift
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

import SwiftUI

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

// MARK: - NavRow

/// One sidebar navigation row. `isSelected` drives the accent-tint fill and
/// the leading gradient bar (hub-concept.html `.nav a.on`).
struct NavRow: View {
    let icon: String
    let title: String
    var isSelected: Bool = false
    var badge: String? = nil

    @State private var isHovering = false

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
                    .font(.system(size: 9.5))
                    .tracking(0.6)
                    .foregroundStyle(Color.Porcelain.dim)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1.5)
                    .overlay(Capsule().strokeBorder(Color.Porcelain.hair, lineWidth: 1))
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
            }
        }
        .onHover { isHovering = $0 }
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/PorcelainComponents.swift
git commit -m "feat(design): add omCard/NavRow/SectionHeader Porcelain components"
```

## Task 5: Debug component gallery window

**Files:**
- Create: `omwhisper-native/UI/DesignGalleryView.swift`
- Modify: `omwhisper-native/OmWhisperApp.swift`

**Interfaces:**
- Consumes: Task 1 (`Color.Porcelain`), Task 3 (`OmOrbView`, `OrbPalette`), Task 4 (`omCard`, `NavRow`, `SectionHeader`).
- Produces: a `#if DEBUG`-only `Window("Design Gallery", id: "design-gallery")` scene + menu item, mirroring the existing `Window("History", ...)`/`Window("Memory", ...)` and `#if DEBUG` self-test-menu-item patterns already in `OmWhisperApp.swift`.

- [ ] **Step 1: Write the gallery view**

Create `omwhisper-native/UI/DesignGalleryView.swift`:

```swift
//
//  DesignGalleryView.swift
//  OmWhisper
//
//  Debug-only: renders every D1 Porcelain foundation piece together so they
//  can be checked live before D2 wires them into real hub screens. Whole file
//  gated #if DEBUG, matching Meetings/MeetingSelfTest.swift's convention --
//  this view must not exist in release builds.
//

#if DEBUG
import SwiftUI

struct DesignGalleryView: View {
    @State private var selectedRow = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                SectionHeader(eyebrow: "D1 — Foundations", title: "Design Gallery")

                orbRow
                cardRow
                navRow
            }
            .padding(32)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color.Porcelain.bg)
    }

    private var orbRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Orb — dark HUD vs. Porcelain").font(.headline)
            HStack(spacing: 20) {
                ZStack {
                    Color.omBackground
                    OmOrbView(appState: AppState(), palette: .dark)
                        .frame(width: 64, height: 64)
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                ZStack {
                    Color.Porcelain.bg
                    OmOrbView(appState: AppState(), palette: .porcelain)
                        .frame(width: 64, height: 64)
                }
                .frame(width: 140, height: 140)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.Porcelain.hair))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var cardRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("omCard").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("WORDS TODAY").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.Porcelain.dim)
                Text("1,284").font(.system(size: 40, weight: .bold)).foregroundStyle(Color.Porcelain.numeralGradient)
            }
            .padding(20)
            .frame(width: 220, alignment: .leading)
            .omCard()
        }
    }

    private var navRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NavRow").font(.headline)
            VStack(spacing: 2) {
                NavRow(icon: "house", title: "Home", isSelected: selectedRow == 0)
                    .onTapGesture { selectedRow = 0 }
                NavRow(icon: "clock", title: "History", isSelected: selectedRow == 1)
                    .onTapGesture { selectedRow = 1 }
                NavRow(icon: "person.2", title: "Meetings", isSelected: selectedRow == 2, badge: "S3")
                    .onTapGesture { selectedRow = 2 }
            }
            .frame(width: 220)
            .padding(10)
            .omCard()
        }
    }
}

#Preview {
    DesignGalleryView()
}
#endif
```

- [ ] **Step 2: Wire the window scene and menu item**

In `omwhisper-native/OmWhisperApp.swift`, add to `makeScene()`'s `@SceneBuilder`
body, after the existing `Window("Memory", ...)` scene:

```swift
        #if DEBUG
        Window("Design Gallery", id: "design-gallery") {
            DesignGalleryView()
        }
        .defaultLaunchBehavior(.suppressed)
        #endif
```

And wire the opener the same way `openMemoryAction` is wired. First, add the
action-setting line alongside the existing two in the `let _ = { ... }()` block:

```swift
        let _ = {
            delegate.openSettingsAction = openSettings
            delegate.openHistoryAction = openWindow
            delegate.openMemoryAction = openWindow
            #if DEBUG
            delegate.openDesignGalleryAction = openWindow
            #endif
        }()
```

In `AppDelegate`, add the stored property alongside `openMemoryAction`:

```swift
    var openHistoryAction: OpenWindowAction?
    var openMemoryAction: OpenWindowAction?
    #if DEBUG
    var openDesignGalleryAction: OpenWindowAction?
    #endif
```

Add the menu item inside the existing `#if DEBUG` block in `menuNeedsUpdate`
(alongside the two self-test items):

```swift
        #if DEBUG
        menu.addItem(.separator())
        addItem(to: menu, title: "Meeting Self-Test…", action: #selector(runMeetingSelfTest))
        addItem(to: menu, title: "Memory Self-Test…", action: #selector(runMemorySelfTest))
        addItem(to: menu, title: "Design Gallery…", action: #selector(openDesignGallery))
        #endif
```

Add the action, alongside `openMemory()`:

```swift
    #if DEBUG
    @objc private func openDesignGallery() {
        NSApp.activate(ignoringOtherApps: true)
        openDesignGalleryAction?(id: "design-gallery")
    }
    #endif
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/DesignGalleryView.swift omwhisper-native/OmWhisperApp.swift
git commit -m "feat(design): add debug Design Gallery window (D1 exit criterion)"
```

## Task 6: Full verification pass

**Files:** None — verification only.

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED, all tests pass (existing 196 + 9 new `OrbPaletteTests` = 205)

- [ ] **Step 2: Note live-verification status honestly**

D1's exit criterion per `docs/DESIGN_DIRECTION.md` is "a component gallery
debug window renders all pieces" — the window and its content compile and are
reachable via the debug menu, but actually looking at it in a running app
(confirming the Porcelain orb reads as watercolor-on-white, the dark orb is
pixel-identical to the live overlay HUD today, card shadows look right, nav
row selection/hover states feel right) has **not been done** in this pass — no
Swift toolchain live-run in this environment. Flag this the same way M4.2's
CloudEngine flagged its own unverified live network path: real, but the one
step a user needs to close before D1 is fully done, not before D2 starts.

- [ ] **Step 3: Commit is already complete per-task** — no further action; this task is verification-only.
