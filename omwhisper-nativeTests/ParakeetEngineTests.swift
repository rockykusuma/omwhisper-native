import Testing
@testable import OmWhisper

@Suite("ParakeetEngine")
struct ParakeetEngineTests {
    @Test("a confirmed update maps to .final")
    func confirmedMapsToFinal() {
        #expect(ParakeetEngine.mapUpdate(isConfirmed: true, text: "hello world") == .final("hello world"))
    }

    @Test("a volatile (unconfirmed) update maps to .partial")
    func unconfirmedMapsToPartial() {
        #expect(ParakeetEngine.mapUpdate(isConfirmed: false, text: "hello wor") == .partial("hello wor"))
    }
}
