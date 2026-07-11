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

    // Guards the UserDefaults persistence contract: rawValues are stored, so a
    // renamed case would silently break restore of a saved preference.
    @Test("ParakeetModel rawValues round-trip and cover both variants")
    func parakeetModelRawValues() {
        #expect(ParakeetModel(rawValue: "v3") == .v3)
        #expect(ParakeetModel(rawValue: "v2") == .v2)
        #expect(ParakeetModel.allCases == [.v3, .v2])
        #expect(ParakeetModel(rawValue: "bogus") == nil)
    }
}
