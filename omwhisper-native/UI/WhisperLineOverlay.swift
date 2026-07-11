//
//  WhisperLineOverlay.swift
//  OmWhisper
//
//  The ultra-minimal overlay style (OVERLAY_SPEC §3): a small lozenge with a
//  vector micro-ॐ + 5 amplitude bars. No status label, no transcript.
//

import SwiftUI

/// Height (pt) of whisper-line bar `index` at animation `phase` (seconds), for
/// amplitude 0…1. A per-index phase offset makes the bars ripple; a small floor
/// keeps them alive when there's no live audio (the settings-card preview). Pure.
nonisolated func barHeight(amplitude: Float, index: Int, phase: Double) -> CGFloat {
    let minH: CGFloat = 5, maxH: CGFloat = 20
    let floor: CGFloat = 0.15   // never fully dead — matches the overlay's listening floor
    let amp = max(floor, min(1, CGFloat(amplitude)))
    let ripple = 0.6 + 0.4 * sin(phase * 7 + Double(index) * 1.1)   // 0.2…1.0
    let h = minH + (maxH - minH) * amp * CGFloat(ripple)
    return max(minH, min(maxH, h))
}

struct WhisperBars: View {
    let appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Static soft state (spec §11): fixed gentle bars, no animation.
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    Capsule().fill(Color.omMint.opacity(0.6)).frame(width: 3, height: 10)
                }
            }
        } else {
            TimelineView(.animation) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule()
                            .fill(Color.omMint)
                            .frame(width: 3, height: barHeight(amplitude: appState.audioLevel, index: i, phase: phase))
                    }
                }
            }
        }
    }
}

struct WhisperLineOverlay: View {
    let appState: AppState
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 7) {
            OmGlyph()
                .fill(Color.omEmerald)
                .frame(width: 16, height: 16)
                .shadow(color: Color.omEmerald.opacity(0.6), radius: 4)
            if isVisible {
                WhisperBars(appState: appState)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 132, height: 38)
        .background(Color.omBackground.opacity(0.92), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
    }
}
