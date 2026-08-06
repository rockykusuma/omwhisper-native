import Foundation
import Testing
import os
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

@Suite("Manual recording naming")
@MainActor
struct MeetingWatcherRecordingNameTests {
    @Test("a manual recording started during a call is named after the call")
    func takesTheDetectedCallName() {
        // Record lives in the hub window, so the frontmost app is OmWhisper
        // itself -- a real Teams call on 2026-08-03 was filed as
        // "OmWhisper-Dev" for exactly this reason.
        let watcher = MeetingWatcher()
        watcher.performDetection = { MeetingWatcher.DetectedCall(name: "Teams", pid: 2221) }

        let name = watcher.enterRecording(fallbackAppName: "OmWhisper-Dev")

        #expect(name == "Teams")
        #expect(watcher.state == .recording(appName: "Teams"))
        // The pid must be the call's too, or callWindowTitle reads the wrong
        // app's windows and the meeting gets no real title.
        #expect(watcher.recordingPID == 2221)
    }

    @Test("a manual recording with no call keeps the fallback name")
    func keepsFallbackWithoutACall() {
        let watcher = MeetingWatcher()
        watcher.performDetection = { nil }

        let name = watcher.enterRecording(fallbackAppName: "TextEdit")

        #expect(name == "TextEdit")
        #expect(watcher.state == .recording(appName: "TextEdit"))
        // No detection means no auto-stop arming -- this recording ends when
        // the user says so.
        #expect(watcher.recordingPID == nil)
    }
}

@Suite("Meeting pre-roll lifecycle")
@MainActor
struct MeetingPreRollTests {
    /// A settable call, so one test can turn a call on and then off without
    /// audio hardware.
    final class Box: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: MeetingWatcher.DetectedCall?.none)
        var call: MeetingWatcher.DetectedCall? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
        init(_ call: MeetingWatcher.DetectedCall?) { self.call = call }
    }

    private func makeWatcher(_ box: Box) -> MeetingWatcher {
        let watcher = MeetingWatcher()
        watcher.performDetection = { box.call }
        watcher.performRecordingCheck = { _ in box.call != nil }
        watcher.onShowConsentPanel = { _, _ in }   // unanswered unless overridden
        return watcher
    }

    /// Polls until `condition` holds. Same idiom and same reason as
    /// MeetingWatcherConcurrencyTests.waitUntil: tick() hands detection to a
    /// detached task, so every effect is asynchronous and a fixed sleep is a
    /// timing guess.
    private func waitUntil(timeout: Duration = .seconds(5),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Drives real ticks until `condition` holds, because the start debounce is
    /// measured in wall time and no amount of calling tick() shortens it.
    private func tickUntil(_ watcher: MeetingWatcher, timeout: Duration = .seconds(8),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            watcher.startForTesting()
            try? await Task.sleep(for: .milliseconds(150))
        }
        return condition()
    }

    @Test("the recorder starts on first detection, before any prompt")
    func preRollStartsAtDetection() async {
        let watcher = makeWatcher(Box(.init(name: "Teams", pid: 2221)))
        let began = OSAllocatedUnfairLock(initialState: [(String, pid_t)]())
        watcher.onBeginPreRoll = { name, pid in began.withLock { $0.append((name, pid)) } }

        watcher.startForTesting()

        #expect(await waitUntil { began.withLock { $0.count } == 1 },
                "pre-roll never started")
        let first = began.withLock { $0.first }
        #expect(first?.0 == "Teams")
        // The OWNING app's pid, not the helper that holds the mic -- otherwise
        // callWindowTitle finds no windows and the meeting gets no title.
        #expect(first?.1 == 2221)
        #expect(watcher.isPreRolling)
        // The whole point: capture is running while the state is still
        // .detecting, i.e. before the debounce has even been cleared.
        #expect(watcher.state == .detecting)
    }

    @Test("a call that ends before anyone answers discards")
    func callEndingDuringPreRollDiscards() async {
        let box = Box(.init(name: "Teams", pid: 2221))
        let watcher = makeWatcher(box)
        let discards = OSAllocatedUnfairLock(initialState: 0)
        watcher.onDiscardPreRoll = { discards.withLock { $0 += 1 } }

        watcher.startForTesting()
        #expect(await waitUntil { watcher.isPreRolling }, "pre-roll never started")

        box.call = nil
        watcher.startForTesting()

        #expect(await waitUntil { discards.withLock { $0 } == 1 }, "never discarded")
        #expect(!watcher.isPreRolling)
    }

    @Test("saying yes elsewhere promotes the pre-roll instead of starting a second one")
    func acceptPreRollPromotes() async {
        let watcher = makeWatcher(Box(.init(name: "Teams", pid: 2221)))
        let starts = OSAllocatedUnfairLock(initialState: 0)
        watcher.onBeginPreRoll = { _, _ in starts.withLock { $0 += 1 } }

        watcher.startForTesting()
        #expect(await waitUntil { watcher.isPreRolling }, "pre-roll never started")

        #expect(watcher.acceptPreRoll(appName: "Teams"))
        #expect(watcher.state == .recording(appName: "Teams"))
        #expect(!watcher.isPreRolling)
        #expect(starts.withLock { $0 } == 1, "a second recorder was started over a live one")
        #expect(!watcher.acceptPreRoll(appName: "Teams"), "promoting twice should be a no-op")
    }

    @Test("declining discards exactly once, even after the call ends", .timeLimit(.minutes(1)))
    func declineDiscards() async {
        let box = Box(.init(name: "Teams", pid: 2221))
        let watcher = makeWatcher(box)
        let discards = OSAllocatedUnfairLock(initialState: 0)
        watcher.onDiscardPreRoll = { discards.withLock { $0 += 1 } }
        watcher.onShowConsentPanel = { _, respond in respond(.declined) }

        #expect(await tickUntil(watcher) { discards.withLock { $0 } > 0 },
                "the prompt never fired or never discarded")
        #expect(watcher.state == .declined)
        #expect(!watcher.isPreRolling)

        // Keep going past the decline. `.declined -> .idle` takes the same
        // non-recording branch as the discard, so without the isPreRolling
        // guard this fires a SECOND delete. Stopping at the first discard --
        // as an earlier version of this test did -- makes the guard
        // unfalsifiable: removing it changed nothing and the test still passed.
        box.call = nil
        watcher.startForTesting()
        #expect(await waitUntil { watcher.state == .idle }, "never returned to idle")

        #expect(discards.withLock { $0 } == 1, "discarded twice for one call")
    }

    @Test("stopping a manual recording never deletes it")
    func manualStopDoesNotDiscard() async {
        // markDeclined() is the manual-Stop path, and it lands in .declined
        // just like a refusal does. If the discard were not guarded, the
        // .declined -> .idle transition would delete a meeting the user had
        // just recorded on purpose and the app had already saved.
        let box = Box(.init(name: "Teams", pid: 2221))
        let watcher = makeWatcher(box)
        let discards = OSAllocatedUnfairLock(initialState: 0)
        watcher.onDiscardPreRoll = { discards.withLock { $0 += 1 } }

        _ = watcher.enterRecording(fallbackAppName: "Teams")
        watcher.markDeclined()
        box.call = nil
        watcher.startForTesting()

        #expect(await waitUntil { watcher.state == .idle }, "never returned to idle")
        #expect(discards.withLock { $0 } == 0, "a manual recording was discarded")
    }

    @Test("an unanswered prompt keeps the recording", .timeLimit(.minutes(1)))
    func firstTimeoutKeepsThePreRoll() async {
        // R's decision, 2026-08-06: an unseen prompt is not a refusal. Deleting
        // here would make the retry 60s later start from nothing, which is past
        // the opening this whole change exists to save.
        let watcher = makeWatcher(Box(.init(name: "Teams", pid: 2221)))
        let discards = OSAllocatedUnfairLock(initialState: 0)
        watcher.onDiscardPreRoll = { discards.withLock { $0 += 1 } }
        watcher.onShowConsentPanel = { _, respond in respond(.timedOut) }

        #expect(await tickUntil(watcher) {
            if case .awaitingRetry = watcher.state { return true }
            return false
        }, "never reached awaitingRetry")

        #expect(discards.withLock { $0 } == 0, "an unanswered prompt threw the recording away")
        #expect(watcher.isPreRolling, "the pre-roll must survive the first timeout")
    }
}
