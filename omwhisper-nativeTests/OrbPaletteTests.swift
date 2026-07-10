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
