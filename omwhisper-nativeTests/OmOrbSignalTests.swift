//
//  OmOrbSignalTests.swift
//  omwhisper-nativeTests
//
//  Covers the pure amplitude-shaping/smoothing math behind OmOrbView's
//  Canvas rendering (docs/OVERLAY_SPEC.md §6) — the only non-visual logic in
//  the orb, extracted as free functions specifically so it's testable without
//  a TimelineView/Canvas/render loop.
//

import Testing
@testable import OmWhisper

struct OmOrbSignalTests {
    @Test func shapedAmplitudeOfSilenceIsZero() {
        #expect(shapedAmplitude(rms: 0) == 0)
    }

    @Test func shapedAmplitudeClampsToOne() {
        #expect(shapedAmplitude(rms: 10) == 1)
    }

    @Test func shapedAmplitudeIsMonotonic() {
        // Below the ~1/6 rms saturation point (gained = rms*6 hits 1 there);
        // values at/above that clamp to exactly 1 and aren't strictly greater
        // (covered separately by shapedAmplitudeClampsToOne).
        let low = shapedAmplitude(rms: 0.02)
        let mid = shapedAmplitude(rms: 0.08)
        let high = shapedAmplitude(rms: 0.15)
        #expect(low < mid)
        #expect(mid < high)
        #expect(high < 1)
    }

    @Test func negativeRmsClampsToZeroInput() {
        // Defensive: rms should never be negative in practice, but the gain
        // stage must not produce NaN/negative output if it ever were.
        #expect(shapedAmplitude(rms: -1) == 0)
    }

    @Test func smootherAttackIsFasterThanDecayForTheSameDelta() {
        let attackStep = nextSmoothedValue(current: 0, target: 1, attackRate: 0.30, decayRate: 0.08)
        let decayStep = nextSmoothedValue(current: 1, target: 0, attackRate: 0.30, decayRate: 0.08)
        // Rising toward a higher target moves further in one step than falling
        // toward a lower one — fast attack, slow decay (§6).
        #expect(attackStep > (1 - decayStep))
    }

    @Test func smootherConvergesToTarget() {
        var value: Float = 0
        for _ in 0..<200 {
            value = nextSmoothedValue(current: value, target: 1)
        }
        #expect(abs(value - 1) < 0.001)
    }

    @Test func smootherAtTargetStaysPut() {
        #expect(nextSmoothedValue(current: 0.5, target: 0.5) == 0.5)
    }
}
