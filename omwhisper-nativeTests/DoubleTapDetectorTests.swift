import Testing
@testable import OmWhisper

@Suite("DoubleTapDetector")
struct DoubleTapDetectorTests {
    @Test("two taps within the window fire a double-tap")
    func withinWindow() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        #expect(detector.tapDetected(at: 0.2) == true)
    }

    @Test("two taps beyond the window do not fire")
    func beyondWindow() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        #expect(detector.tapDetected(at: 0.5) == false)
    }

    @Test("a third tap right after a fired pair starts a fresh pending single, not a re-fire")
    func tripleTapFiresOnceThenRestarts() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        #expect(detector.tapDetected(at: 0.1) == true)   // fires once
        #expect(detector.tapDetected(at: 0.2) == false)  // starts a new pending single
        #expect(detector.tapDetected(at: 0.35) == true)  // pairs with the tap at 0.2
    }

    @Test("interrupt clears a pending single so the next tap starts fresh")
    func interruptClearsPending() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        detector.interrupt()
        #expect(detector.tapDetected(at: 0.1) == false)  // would have fired without interrupt()
    }

    @Test("a tap exactly at the window boundary still fires")
    func exactBoundaryFires() {
        var detector = DoubleTapDetector(window: 0.45)
        #expect(detector.tapDetected(at: 0.0) == false)
        #expect(detector.tapDetected(at: 0.45) == true)
    }
}
