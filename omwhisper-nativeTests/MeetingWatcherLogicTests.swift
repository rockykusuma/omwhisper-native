import Testing
@testable import OmWhisper

struct MeetingWatcherLogicTests {
    let start = MeetingWatcherTiming.startDebounce
    let end = MeetingWatcherTiming.endDebounce
    let cooldown = MeetingWatcherTiming.retryCooldown

    private func next(
        _ current: MeetingWatcherState,
        detected: String? = nil,
        detectedDuration: Duration = .zero,
        callGone: Bool = false,
        goneDuration: Duration = .zero,
        retryWait: Duration = .zero
    ) -> MeetingWatcherState {
        MeetingWatcher.nextState(current: current, detected: detected,
                                 detectedDuration: detectedDuration, callGone: callGone,
                                 goneDuration: goneDuration, retryWait: retryWait)
    }

    @Test("a detected call moves out of idle")
    func idleToDetecting() {
        #expect(next(.idle, detected: "Teams") == .detecting)
        #expect(next(.idle) == .idle)
    }

    @Test("prompting waits for the start debounce")
    func detectingPromptsAfterDebounce() {
        #expect(next(.detecting, detected: "Teams", detectedDuration: .seconds(1)) == .detecting)
        #expect(next(.detecting, detected: "Teams", detectedDuration: start) == .prompting(appName: "Teams"))
    }

    @Test("a call that goes away before the debounce prompts for nothing")
    func detectingGoesIdleWhenCallEnds() {
        #expect(next(.detecting, detectedDuration: .seconds(1)) == .idle)
    }

    @Test("a call that is never recognized does NOT latch to declined")
    func undetectedCallDoesNotLatch() {
        // The 2026-08-03 bug: reaching the debounce with no recognized call
        // used to latch .declined for the whole mic session, so a detection
        // MISS was recorded as the user refusing. There is nothing to decline
        // if nothing was ever detected -- it simply returns to idle and keeps
        // watching.
        #expect(next(.detecting, detected: nil, detectedDuration: start) == .idle)
    }

    @Test("recording continues while the call still holds the mic")
    func recordingHoldsWhileCallActive() {
        #expect(next(.recording(appName: "Teams"), detected: "Teams", goneDuration: end)
                == .recording(appName: "Teams"))
    }

    @Test("recording stops once the call releases the mic past the debounce")
    func recordingStopsWhenCallGone() {
        // This has never worked for Teams: the old stop path required a
        // call-like window title to have been seen first, and
        // "D-WHAS | Microsoft Teams" has no call word in it.
        #expect(next(.recording(appName: "Teams"), callGone: true, goneDuration: end) == .idle)
        #expect(next(.recording(appName: "Teams"), callGone: true, goneDuration: .seconds(1))
                == .recording(appName: "Teams"))
    }

    @Test("a manual recording with no call detected never auto-stops")
    func manualRecordingDoesNotAutoStop() {
        // Recording an app that is not a recognized call -- which is exactly
        // what happened on 2026-08-03 -- has no detection to lose. Without
        // callGone gating this, detected == nil on the first tick would stop
        // the recording after 8 seconds.
        #expect(next(.recording(appName: "Recording"), callGone: false, goneDuration: .seconds(600))
                == .recording(appName: "Recording"))
    }

    @Test("a prompt is abandoned if the call ends first")
    func promptingCancelsWhenCallEnds() {
        #expect(next(.prompting(appName: "Teams")) == .idle)
        #expect(next(.prompting(appName: "Teams"), detected: "Teams") == .prompting(appName: "Teams"))
    }

    @Test("an explicit decline holds for the rest of the call")
    func declinedLatchesWhileCallContinues() {
        #expect(next(.declined, detected: "Teams", detectedDuration: .seconds(300)) == .declined)
        #expect(next(.declined) == .idle)
    }

    @Test("a timed-out prompt is asked again after the cooldown")
    func awaitingRetryPromptsAgain() {
        #expect(next(.awaitingRetry(appName: "Teams"), detected: "Teams", retryWait: .seconds(5))
                == .awaitingRetry(appName: "Teams"))
        #expect(next(.awaitingRetry(appName: "Teams"), detected: "Teams", retryWait: cooldown)
                == .prompting(appName: "Teams"))
    }

    @Test("a retry waiting on a call that ended goes quiet")
    func awaitingRetryGoesIdleWhenCallEnds() {
        #expect(next(.awaitingRetry(appName: "Teams"), retryWait: cooldown) == .idle)
    }
}
