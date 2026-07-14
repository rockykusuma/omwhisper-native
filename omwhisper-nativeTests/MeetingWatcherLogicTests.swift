import Testing
@testable import OmWhisper

struct MeetingWatcherLogicTests {
    let start = MeetingWatcherTiming.startDebounce
    let end = MeetingWatcherTiming.endDebounce

    @Test func idleToMicActiveOnMic() {
        #expect(MeetingWatcher.nextState(current: .idle, micActive: true, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: .zero) == .micActive)
    }

    @Test func idleStaysIdleWithoutMic() {
        #expect(MeetingWatcher.nextState(current: .idle, micActive: false, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: .zero) == .idle)
    }

    @Test func micActivePromptsOnCallAfterDebounce() {
        #expect(MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: start,
            detectedCall: "Teams", recordingCallGone: false, callGoneDuration: .zero) == .prompting(appName: "Teams"))
    }

    @Test func micActiveWaitsForDebounce() {
        #expect(MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: .seconds(1),
            detectedCall: "Teams", recordingCallGone: false, callGoneDuration: .zero) == .micActive)
    }

    @Test func micActiveDeclinesWhenNoCall() {
        #expect(MeetingWatcher.nextState(current: .micActive, micActive: true, activeDuration: start,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: .zero) == .declined)
    }

    @Test func micActiveGoesIdleIfMicOffBeforeDebounce() {
        #expect(MeetingWatcher.nextState(current: .micActive, micActive: false, activeDuration: .seconds(1),
            detectedCall: nil, recordingCallGone: false, callGoneDuration: .zero) == .idle)
    }

    @Test func recordingStaysWhileCallWindowPresent() {
        // Window never gone → keeps recording even though the mic (held by us) reads active.
        #expect(MeetingWatcher.nextState(current: .recording(appName: "Teams"), micActive: true, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: end) == .recording(appName: "Teams"))
    }

    @Test func recordingStopsWhenCallWindowGonePastDebounce() {
        #expect(MeetingWatcher.nextState(current: .recording(appName: "Teams"), micActive: true, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: true, callGoneDuration: end) == .idle)
    }

    @Test func recordingHoldsBeforeDebounce() {
        #expect(MeetingWatcher.nextState(current: .recording(appName: "Teams"), micActive: true, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: true, callGoneDuration: .seconds(1)) == .recording(appName: "Teams"))
    }

    @Test func promptingCancelsWhenMicStops() {
        #expect(MeetingWatcher.nextState(current: .prompting(appName: "Teams"), micActive: false, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: .zero) == .idle)
    }

    @Test func declinedRearmsWhenMicGoesIdle() {
        #expect(MeetingWatcher.nextState(current: .declined, micActive: false, activeDuration: .zero,
            detectedCall: nil, recordingCallGone: false, callGoneDuration: .zero) == .idle)
    }
}
