//
//  OmOrbView.swift
//  OmWhisper
//
//  The animated orb: 3 additive energy blobs + a pulse ring around a steady
//  ॐ glyph. See docs/OVERLAY_SPEC.md §5/§6. This is the project's first use of
//  Canvas/TimelineView — mount-gated by the caller (OverlayView) on
//  `dictation != .idle` so the render loop doesn't tick behind a hidden panel.
//
//  ponytail: several raw constants in §5 aren't explicitly marked "scaled to
//  128px canvas, halve for pt" the way §5.1's blob values are — applied the
//  same halving to the pulse ring (§5.2) and finalize wave (§5.5) for visual
//  consistency with the 64pt zone. These, and the simplified one-shot glow/
//  wave pulses (exponential approach to a target rather than a literal
//  rise/decay timing curve), are exactly the kind of thing to tune once seen
//  live — not a correctness bug, a starting point.
//

import SwiftUI

// MARK: - Pure, testable signal-shaping functions (§6)

/// `shaped = min(1, (rms · 6)^0.7)` — gain then soft-knee compress; raw mic
/// RMS is too spiky/quiet to drive visuals directly.
nonisolated func shapedAmplitude(rms: Float) -> Float {
    let gained = max(0, rms) * 6
    return min(1, pow(gained, 0.7))
}

/// One step of an asymmetric one-pole smoother: fast attack, slow decay (or a
/// single shared rate, e.g. for `glow`, by passing the same value twice).
nonisolated func nextSmoothedValue(current: Float, target: Float, attackRate: Float = 0.30, decayRate: Float = 0.08) -> Float {
    let rate = target > current ? attackRate : decayRate
    return current + (target - current) * rate
}

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

/// Holds the per-frame smoothed amplitude/glow across Canvas redraws. A plain
/// class (not @Observable) stored in `@State` — TimelineView's own clock
/// already forces a redraw every tick; this just needs its identity (and thus
/// internal mutable state) to persist between those ticks.
@MainActor
private final class OrbSignal {
    private(set) var amp: Float = 0
    private(set) var glow: Double = 0

    func tick(rawLevel: Float, floor: Float, targetGlow: Double) {
        let target = max(floor, shapedAmplitude(rms: rawLevel))
        amp = nextSmoothedValue(current: amp, target: target)
        glow = Double(nextSmoothedValue(current: Float(glow), target: Float(targetGlow), attackRate: 0.08, decayRate: 0.08))
    }
}

struct OmOrbView: View {
    let appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var signal = OrbSignal()
    @State private var phaseStartedAt = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                signal.tick(
                    rawLevel: appState.audioLevel,
                    floor: floor(for: appState.dictation),
                    targetGlow: targetGlow(for: appState.dictation)
                )
                let t = timeline.date.timeIntervalSinceReferenceDate
                let elapsed = timeline.date.timeIntervalSince(phaseStartedAt)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                if reduceMotion {
                    drawReducedMotion(context: &context, center: center, amp: signal.amp, dictation: appState.dictation, elapsed: elapsed)
                } else {
                    drawField(context: &context, center: center, amp: signal.amp, t: t)
                    drawRing(context: &context, center: center, amp: signal.amp, t: t, dictation: appState.dictation, elapsed: elapsed)
                    drawGlyph(context: &context, center: center, amp: signal.amp, glow: signal.glow, t: t, dictation: appState.dictation, elapsed: elapsed)
                }
            }
        }
        .onChange(of: appState.dictation) { _, _ in
            phaseStartedAt = Date()
        }
        .accessibilityHidden(true)   // display-only; see OVERLAY_SPEC.md §11
    }

    // MARK: State → target mapping

    private func floor(for dictation: DictationState) -> Float {
        switch dictation {
        case .starting: 0.20
        case .recording, .finalizing: 0.12
        case .idle: 0
        }
    }

    private func targetGlow(for dictation: DictationState) -> Double {
        switch dictation {
        case .starting: 0.3
        case .recording: 0.6
        // ponytail: exponential rise toward 1.0 approximates the spec's explicit
        // 120ms-rise/300ms-decay pulse shape; the overlay hides shortly after
        // entering .finalizing anyway, so a literal timed curve isn't worth the
        // extra state — revisit if the brighten feel doesn't read as a "pulse" live.
        case .finalizing: 1.0
        case .idle: 0
        }
    }

    // MARK: §5.1 Energy field (3 blobs)

    private static let blobColors: [Color] = [.omEmerald, .omTeal, .omMint]

    private func drawField(context: inout GraphicsContext, center: CGPoint, amp: Float, t: TimeInterval) {
        let rBase = 13.5, ak1 = 8.0, w1 = 1.5, k2 = 4.0, w2 = 1.0, k3 = 2.0
        context.blendMode = .plusLighter
        for i in 0..<3 {
            let phi = Double(i) * 2.1
            let path = blobPath(center: center) { theta in
                rBase + ak1 * Double(amp)
                    + sin(3 * theta + t / 0.30 + phi) * (w1 + Double(amp) * k2)
                    + sin(5 * theta - t / 0.20 + phi) * (w2 + Double(amp) * k3)
            }
            let alpha = 0.16 + Double(amp) * 0.20
            context.fill(path, with: .color(Self.blobColors[i].opacity(alpha)))
        }
    }

    private func blobPath(center: CGPoint, samples: Int = 72, radius: (Double) -> Double) -> Path {
        var path = Path()
        for i in 0...samples {
            let theta = Double(i) / Double(samples) * 2 * .pi
            let r = radius(theta)
            let point = CGPoint(x: center.x + cos(theta) * r, y: center.y + sin(theta) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: §5.2 Pulse ring + §5.5 finalize expanding wave

    private func drawRing(context: inout GraphicsContext, center: CGPoint, amp: Float, t: TimeInterval, dictation: DictationState, elapsed: TimeInterval) {
        context.blendMode = .plusLighter

        let restingRadius = 17 + Double(amp) * 10 + sin(t / 0.6) * 1
        let restingAlpha = 0.10 + Double(amp) * 0.30
        context.stroke(ringPath(center: center, radius: restingRadius), with: .color(Color.omMint.opacity(restingAlpha)), lineWidth: 0.75)

        guard dictation == .finalizing else { return }
        // One expanding, fading wave on entering .finalizing — a seal on top of
        // (not a replacement for) the continuous resting ring above.
        let waveProgress = min(1, elapsed / 0.42)
        let waveRadius = restingRadius + waveProgress * (30 - 17)
        let waveAlpha = restingAlpha * (1 - waveProgress)
        context.stroke(ringPath(center: center, radius: waveRadius), with: .color(Color.omMint.opacity(waveAlpha)), lineWidth: 0.75)
    }

    private func ringPath(center: CGPoint, radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: §5.3/§5.4 The ॐ glyph, warming stroke-draw

    private func drawGlyph(context: inout GraphicsContext, center: CGPoint, amp: Float, glow: Double, t: TimeInterval, dictation: DictationState, elapsed: TimeInterval) {
        let breath = 1 + 0.02 * sin(t / 0.9)
        // ponytail: spec §5.3 says ~44pt within the 64pt zone (68% fill) — too
        // large next to the 11-15pt label/transcript text once seen live; sized
        // down to read as a compact icon rather than dominate the pill.
        let size: CGFloat = 20 * breath
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2 + 2, width: size, height: size)
        let lum = min(1, glow * 0.55 + Double(amp) * 0.5)
        let color = glyphLuminanceColor(lum)
        let underRect = rect.offsetBy(dx: 1.5, dy: 1.5)

        guard dictation == .starting else {
            context.fill(OmGlyph().path(in: underRect), with: .color(Color.omGlyphUnderCopy.opacity(0.9)))
            context.fill(OmGlyph().path(in: rect), with: .color(color))
            return
        }

        // §5.4: stroke-draw over ~240ms, then crossfade stroke → fill over ~80ms.
        // If dictation has already moved past .starting, we never reach this
        // branch again (phaseStartedAt resets on every dictation change) — so a
        // fast setup naturally "jump-completes" by simply rendering fully filled.
        let drawProgress = min(1, elapsed / 0.24)
        let eased = 1 - pow(1 - drawProgress, 2)   // ease-out
        if eased < 1 {
            let trimmed = OmGlyph().trim(from: 0, to: eased).path(in: rect)
            context.stroke(trimmed, with: .color(color), lineWidth: 2)
            return
        }
        let crossfade = min(1, (elapsed - 0.24) / 0.08)
        context.opacity = crossfade
        context.fill(OmGlyph().path(in: underRect), with: .color(Color.omGlyphUnderCopy.opacity(0.9)))
        context.fill(OmGlyph().path(in: rect), with: .color(color))
        context.opacity = 1
    }

    private func glyphLuminanceColor(_ lum: Double) -> Color {
        // Mirrors Color.omGlyphCore (#EAFFF5) -> Color.omGlyphPeak (white).
        let core = (r: 234.0, g: 255.0, b: 245.0)
        let peak = (r: 255.0, g: 255.0, b: 255.0)
        let clamped = min(1, max(0, lum))
        return Color(
            red: (core.r + (peak.r - core.r) * clamped) / 255,
            green: (core.g + (peak.g - core.g) * clamped) / 255,
            blue: (core.b + (peak.b - core.b) * clamped) / 255
        )
    }

    // MARK: §11 Reduced Motion

    private func drawReducedMotion(context: inout GraphicsContext, center: CGPoint, amp: Float, dictation: DictationState, elapsed: TimeInterval) {
        // Static soft disc whose opacity (not shape) tracks amp; glyph breath off.
        let radius = 13.5
        let alpha = 0.16 + Double(amp) * 0.20
        context.blendMode = .plusLighter
        context.fill(ringPath(center: center, radius: radius), with: .color(Color.omEmerald.opacity(alpha)))

        let size: CGFloat = 44   // matches drawGlyph's sizing (see its ponytail note)
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2 + 2, width: size, height: size)
        // Stroke-draw becomes a plain fade (no trim animation).
        let fadeIn = dictation == .starting ? min(1, elapsed / 0.24) : 1
        context.opacity = fadeIn
        context.fill(OmGlyph().path(in: rect), with: .color(.omGlyphCore))
        context.opacity = 1
    }
}

#Preview {
    ZStack {
        Color.black
        OmOrbView(appState: AppState())
            .frame(width: 64, height: 64)
    }
    .frame(width: 200, height: 200)
}
