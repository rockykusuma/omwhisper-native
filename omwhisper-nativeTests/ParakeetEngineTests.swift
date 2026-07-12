import Testing
@testable import OmWhisper

@Suite("ParakeetEngine")
struct ParakeetEngineTests {
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
