import Testing
@testable import OmWhisper

@Suite("SingleInstance")
struct SingleInstanceTests {
    // The one that matters: our own process always appears in the bundle-ID
    // lookup, so counting it would make the app refuse to ever launch.
    @Test("ignores our own process")
    func ignoresSelf() {
        #expect(SingleInstance.otherInstancePID(among: [42], myPID: 42) == nil)
    }

    @Test("finds another instance")
    func findsOther() {
        #expect(SingleInstance.otherInstancePID(among: [42, 99], myPID: 42) == 99)
    }

    @Test("nothing running")
    func noneRunning() {
        #expect(SingleInstance.otherInstancePID(among: [], myPID: 42) == nil)
    }
}
