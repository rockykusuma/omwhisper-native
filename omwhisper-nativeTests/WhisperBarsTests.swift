import Testing
import CoreGraphics
@testable import OmWhisper

struct WhisperBarsTests {
    @Test func staysWithinBounds() {
        for amp: Float in [-1, 0, 0.3, 1, 5] {
            for i in 0..<5 {
                let h = barHeight(amplitude: amp, index: i, phase: 0.3)
                #expect(h >= 5 && h <= 20)
            }
        }
    }

    @Test func risesWithAmplitude() {
        // Same index + phase → higher amplitude yields a taller bar.
        #expect(barHeight(amplitude: 0.9, index: 2, phase: 1.0) > barHeight(amplitude: 0.2, index: 2, phase: 1.0))
    }

    @Test func differsPerIndex() {
        // The per-index phase offset makes bars ripple independently.
        #expect(barHeight(amplitude: 1.0, index: 0, phase: 0.0) != barHeight(amplitude: 1.0, index: 3, phase: 0.0))
    }

    @Test func neverFullyDead() {
        // A floor keeps the bars alive at zero amplitude (the settings-card preview
        // has no live audio) — still >= the 5pt minimum.
        #expect(barHeight(amplitude: 0, index: 1, phase: 0.5) >= 5)
    }
}
