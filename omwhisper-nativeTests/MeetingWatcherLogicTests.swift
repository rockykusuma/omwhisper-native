import Testing
@testable import OmWhisper

struct MeetingWatcherLogicTests {
    @Test func idleStaysIdleWithoutMic() {
        let next = MeetingWatcher.nextState(current: .idle, micActive: false, activeDuration: .zero, idleDuration: .zero, detectedCall: nil)
        #expect(next == .idle)
    }

    @Test func idleTransitionsToMicActiveWhenMicTurnsOn() {
        let next = MeetingWatcher.nextState(current: .idle, micActive: true, activeDuration: .zero, idleDuration: .zero, detectedCall: nil)
        #expect(next == .micActive)
    }

    @Test func micActiveStaysUntilThreeSecondDebounce() {
        let next = MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: .seconds(1), idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .micActive)
    }

    @Test func micActivePromptsAfterDebounceWithRecognizedCall() {
        let next = MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: .seconds(3), idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .prompting(appName: "Zoom"))
    }

    @Test func micActiveDeclinesAfterDebounceWithNoRecognizedCall() {
        // Own dictation or an unrelated app -- never prompt.
        let next = MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: .seconds(3), idleDuration: .zero, detectedCall: nil)
        #expect(next == .declined)
    }

    @Test func micActiveGoesIdleIfMicTurnsOffBeforeDebounce() {
        let next = MeetingWatcher.nextState(current: .micActive, micActive: false, activeDuration: .seconds(1), idleDuration: .zero, detectedCall: nil)
        #expect(next == .idle)
    }

    @Test func promptingResetsToIdleIfMicGoesOff() {
        let next = MeetingWatcher.nextState(current: .prompting(appName: "Zoom"), micActive: false, activeDuration: .zero, idleDuration: .zero, detectedCall: nil)
        #expect(next == .idle)
    }

    @Test func promptingStaysUntilExternalConsentDecision() {
        // The consent panel's own accept/decline/timeout drives the real
        // transition out of .prompting -- this function alone just holds while
        // the mic is still active.
        let next = MeetingWatcher.nextState(current: .prompting(appName: "Zoom"), micActive: true, activeDuration: .zero, idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .prompting(appName: "Zoom"))
    }

    @Test func recordingStaysWhileMicActive() {
        let next = MeetingWatcher.nextState(current: .recording(appName: "Zoom"), micActive: true, activeDuration: .zero, idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .recording(appName: "Zoom"))
    }

    @Test func recordingStaysUntilEightSecondIdleDebounce() {
        let next = MeetingWatcher.nextState(current: .recording(appName: "Zoom"), micActive: false, activeDuration: .zero, idleDuration: .seconds(3), detectedCall: nil)
        #expect(next == .recording(appName: "Zoom"))
    }

    @Test func recordingFinalizesAfterEightSecondIdleDebounce() {
        let next = MeetingWatcher.nextState(current: .recording(appName: "Zoom"), micActive: false, activeDuration: .zero, idleDuration: .seconds(8), detectedCall: nil)
        #expect(next == .idle)
    }

    @Test func declinedStaysUntilMicGoesIdle() {
        let next = MeetingWatcher.nextState(current: .declined, micActive: true, activeDuration: .zero, idleDuration: .zero, detectedCall: "Zoom")
        #expect(next == .declined)
    }

    @Test func declinedRearmsWhenMicGoesIdle() {
        let next = MeetingWatcher.nextState(current: .declined, micActive: false, activeDuration: .zero, idleDuration: .zero, detectedCall: nil)
        #expect(next == .idle)
    }
}
