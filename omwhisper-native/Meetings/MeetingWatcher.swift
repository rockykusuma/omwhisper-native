//
//  MeetingWatcher.swift
//  OmWhisper
//
//  Mic-open detection + consent state machine, ported from smriti's
//  MeetingWatcher.swift (github.com/rockykusuma/smriti, same author, MIT).
//  Polls kAudioDevicePropertyDeviceIsRunningSomewhere every 2s -- cheap
//  property reads, no audio tap while idle. Timing values (3s start-debounce,
//  8s end-debounce, 10s consent countdown) are carried over from smriti's
//  implementation, already proven against real calls.
//

import AppKit
import Foundation

nonisolated enum MeetingWatcherState: Equatable {
    case idle
    /// A recognised call app is capturing microphone input, waiting out the
    /// start debounce before prompting.
    case detecting
    case prompting(appName: String)
    case recording(appName: String)
    /// The user said no. Holds for the rest of this call.
    case declined
    /// The prompt timed out unanswered. Asked once more after retryCooldown --
    /// "I never saw it" is not "no".
    case awaitingRetry(appName: String)
}

nonisolated enum MeetingWatcherTiming {
    static let pollInterval: Duration = .seconds(2)
    static let startDebounce: Duration = .seconds(3)
    static let endDebounce: Duration = .seconds(8)
    static let consentTimeout: Duration = .seconds(10)
    /// How long after an unanswered prompt before asking once more. Teams opens
    /// the mic on its pre-join audio screen, so the first prompt often lands
    /// while the user is still choosing a device.
    static let retryCooldown: Duration = .seconds(60)
}

@MainActor
final class MeetingWatcher {
    private(set) var state: MeetingWatcherState = .idle
    private var pollTimer: Timer?
    /// When the current call was first detected, for the start debounce.
    private var detectedSince: ContinuousClock.Instant?
    /// When the recorded call stopped capturing input, for the end debounce.
    private var goneSince: ContinuousClock.Instant?
    /// When the prompt timed out, for the retry cooldown.
    private var retrySince: ContinuousClock.Instant?
    /// True once a call has actually been detected during this recording. A
    /// manual recording over an unrecognised app never sets it and therefore
    /// never auto-stops -- Stop is the only way out, as today.
    private var sawCall = false
    /// One retry per call. A second timeout goes quiet.
    private var hasRetried = false
    /// The pid of the app whose call we're recording.
    /// private(set): AppState reads it at record start to capture the window title.
    private(set) var recordingPID: pid_t?
    /// pid captured at prompt time, promoted to recordingPID if consent is accepted.
    private var pendingCallPID: pid_t?
    /// The detection sweep is handed off MainActor, so a tick arriving while
    /// one is still running would stack concurrent AX walks. Skipped instead.
    private(set) var isDetecting = false

    nonisolated struct DetectedCall: Equatable, Sendable {
        let name: String
        let pid: pid_t
    }

    /// Injected so the tick loop can be exercised without audio hardware or a
    /// real call. Defaults to the real detectors.
    nonisolated(unsafe) var performDetection: @Sendable () -> DetectedCall? = {
        CallDetection.activeCall().map { DetectedCall(name: $0.name, pid: $0.pid) }
    }

    /// The stop path asks whether THIS call is still capturing, not whether any
    /// call is detected -- see CallDetection.isCallStillActive for why.
    nonisolated(unsafe) var performRecordingCheck: @Sendable (pid_t) -> Bool = { pid in
        CallDetection.isCallStillActive(pid: pid)
    }

    /// Injected so this can be constructed and unit-exercised without the real
    /// recorder/panel. All default to no-ops so this file compiles standalone.
    var onStartRecording: (String) -> Void = { _ in }
    var onStopRecording: () -> Void = {}
    var onShowConsentPanel: (String, @escaping (Bool) -> Void) -> Void = { _, respond in respond(false) }

    /// True while `AppState.dictation != .idle` -- suppresses the whole watcher
    /// so our own dictation never triggers a false consent prompt.
    var isSuppressed: () -> Bool = { false }

    /// Pure decision: given the current state and a freshly-measured detection
    /// signal, what's the next state? Side effects (starting the recorder,
    /// showing the consent panel) happen in the caller when it observes a
    /// state *change*, not inside this function.
    ///
    /// Keyed on `detected` rather than on the microphone: our own recorder
    /// holds the mic open for the entire meeting, which is why the old stop
    /// path had to fall back to window titles.
    nonisolated static func nextState(
        current: MeetingWatcherState,
        detected: String?,
        detectedDuration: Duration,
        callGone: Bool,
        goneDuration: Duration,
        retryWait: Duration
    ) -> MeetingWatcherState {
        switch current {
        case .idle:
            return detected == nil ? .idle : .detecting
        case .detecting:
            // No .declined branch here. Reaching the debounce without a
            // recognised call means we failed to detect one, not that the user
            // refused -- conflating those is what latched a missed Teams call
            // for its whole duration on 2026-08-03.
            guard let detected else { return .idle }
            return detectedDuration >= MeetingWatcherTiming.startDebounce
                ? .prompting(appName: detected) : .detecting
        case .prompting:
            return detected == nil ? .idle : current
        case .recording:
            // callGone is true only once a call was actually detected during
            // this recording and has since stopped capturing, so a manual
            // recording of an unrecognised app never auto-stops.
            return (callGone && goneDuration >= MeetingWatcherTiming.endDebounce) ? .idle : current
        case .declined:
            return detected == nil ? .idle : current
        case .awaitingRetry(let appName):
            guard detected != nil else { return .idle }
            return retryWait >= MeetingWatcherTiming.retryCooldown
                ? .prompting(appName: appName) : current
        }
    }

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: MeetingWatcherTiming.pollInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Called by the caller's onStartRecording closure if MeetingRecorder.start()
    /// throws -- without this, a failed recorder start would leave `state` stuck
    /// showing `.recording` (set optimistically before the async start call)
    /// while no audio is actually being captured, only self-correcting whenever
    /// the mic eventually goes idle on its own (up to the 8s end-debounce later).
    func failedToStartRecording() {
        state = .idle
    }

    /// Manual start: treat as an ongoing recording so the auto-detect poll won't
    /// re-prompt. Auto-stop arms only if a recognised call is detected now --
    /// recording an unrecognised app is stopped by the user, not by us.
    func enterRecording(appName: String) {
        let call = CallDetection.activeCall()
        recordingPID = call?.pid
        sawCall = call != nil
        goneSince = nil
        state = .recording(appName: appName)
    }

    /// Manual stop: mark declined so the poll won't immediately re-prompt while
    /// the same call is still live. Resets to .idle once the call ends
    /// (see nextState's .declined case).
    func markDeclined() {
        state = .declined
    }

    /// Runs one tick synchronously. Tests only -- the real driver is the poll
    /// timer, whose 2s interval makes a test either slow or flaky.
    func startForTesting() { tick() }

    private func tick() {
        guard !isSuppressed(), !isDetecting else { return }
        isDetecting = true
        // While recording, ask whether THIS call is still going rather than
        // re-running detection; the name comes from the state so no placeholder
        // is invented for a value nextState does not read.
        let ongoing: (name: String, pid: pid_t)?
        if case .recording(let appName) = state, let pid = recordingPID {
            ongoing = (appName, pid)
        } else {
            ongoing = nil
        }
        let detectNew = performDetection
        let checkOngoing = performRecordingCheck
        Task.detached(priority: .utility) { [weak self] in
            let detected: DetectedCall?
            if let ongoing {
                detected = checkOngoing(ongoing.pid)
                    ? DetectedCall(name: ongoing.name, pid: ongoing.pid) : nil
            } else {
                detected = detectNew()
            }
            await MainActor.run {
                guard let self else { return }
                // Cleared FIRST and unconditionally: clearing only on the happy
                // path would stop detection forever after one failure, silently.
                self.isDetecting = false
                self.apply(detected)
            }
        }
    }

    private func apply(_ detected: DetectedCall?) {
        let now = ContinuousClock.now
        if detected != nil {
            if detectedSince == nil { detectedSince = now }
        } else {
            detectedSince = nil
        }
        let detectedDuration = detectedSince.map { now - $0 } ?? .zero

        var callGone = false
        var goneDuration: Duration = .zero
        if case .recording = state {
            if detected != nil {
                sawCall = true
                goneSince = nil
            } else if sawCall, goneSince == nil {
                goneSince = now
            }
            callGone = sawCall && detected == nil
            goneDuration = goneSince.map { now - $0 } ?? .zero
        }
        let retryWait = retrySince.map { now - $0 } ?? .zero

        let previous = state
        state = Self.nextState(current: previous, detected: detected?.name,
                               detectedDuration: detectedDuration, callGone: callGone,
                               goneDuration: goneDuration, retryWait: retryWait)

        guard state != previous else { return }
        switch state {
        case .prompting(let appName):
            pendingCallPID = detected?.pid
            retrySince = nil
            onShowConsentPanel(appName) { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.recordingPID = self.pendingCallPID
                    self.sawCall = false
                    self.goneSince = nil
                    self.state = .recording(appName: appName)
                    self.onStartRecording(appName)
                } else {
                    self.state = .declined
                }
            }
        case .idle:
            // Reset the per-call bookkeeping whenever we fall back to idle, so
            // the next call starts from a clean slate rather than inheriting a
            // spent retry.
            retrySince = nil
            hasRetried = false
            if previous.isRecording {
                recordingPID = nil
                sawCall = false
                onStopRecording()
            }
        default:
            break
        }
    }

}

private extension MeetingWatcherState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
