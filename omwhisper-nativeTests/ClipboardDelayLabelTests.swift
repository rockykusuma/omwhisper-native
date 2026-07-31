import Testing
@testable import OmWhisper

// Deliberately no test for the settings themselves: they're UserDefaults-backed
// and the test host IS the app, so writing them would mutate real settings —
// see the KeychainTests lesson.
@Suite("clipboard delay label")
struct ClipboardDelayLabelTests {
    @Test("zero reads as immediately, not 0s")
    func zero() {
        #expect(GeneralSettingsView.delayLabel(0) == "immediately")
    }

    @Test("whole seconds drop the decimal")
    func whole() {
        #expect(GeneralSettingsView.delayLabel(2000) == "2s")
    }

    @Test("quarter steps keep only the digits they need")
    func fractional() {
        #expect(GeneralSettingsView.delayLabel(2500) == "2.5s")
        #expect(GeneralSettingsView.delayLabel(250) == "0.25s")
    }
}
