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
import CoreAudio
import Foundation

nonisolated enum MeetingWatcherState: Equatable {
    case idle
    case micActive
    case prompting(appName: String)
    case recording(appName: String)
    case declined
}

nonisolated enum MeetingWatcherTiming {
    static let pollInterval: Duration = .seconds(2)
    static let startDebounce: Duration = .seconds(3)
    static let endDebounce: Duration = .seconds(8)
    static let consentTimeout: Duration = .seconds(10)
}

@MainActor
final class MeetingWatcher {
    private(set) var state: MeetingWatcherState = .idle
    private var pollTimer: Timer?
    private var activeSince: ContinuousClock.Instant?
    /// The pid of the app whose call we're recording — for the AX window auto-stop.
    private var recordingPID: pid_t?
    /// pid captured at prompt time, promoted to recordingPID if consent is accepted.
    private var pendingCallPID: pid_t?
    /// True once we've observed the recorded call's window during this recording.
    private var sawCallWindow = false
    /// When the recorded call window first went missing after having been seen.
    private var callGoneSince: ContinuousClock.Instant?

    /// Injected so this can be constructed and unit-exercised without the real
    /// recorder/panel (Tasks 3-4) -- Task 5 wires these to MeetingRecorder/
    /// MeetingConsentPanel. Both default to no-ops so this file compiles standalone.
    var onStartRecording: (String) -> Void = { _ in }
    var onStopRecording: () -> Void = {}
    var onShowConsentPanel: (String, @escaping (Bool) -> Void) -> Void = { _, respond in respond(false) }

    /// True while `AppState.dictation != .idle` -- suppresses the whole watcher
    /// so our own dictation never triggers a false consent prompt.
    var isSuppressed: () -> Bool = { false }

    /// Pure decision: given the current state and freshly-measured mic/call
    /// signals, what's the next state? Side effects (starting the recorder,
    /// showing the consent panel) happen in the caller when it observes a
    /// state *change*, not inside this function.
    nonisolated static func nextState(
        current: MeetingWatcherState,
        micActive: Bool,
        activeDuration: Duration,
        detectedCall: String?,
        recordingCallGone: Bool,
        callGoneDuration: Duration
    ) -> MeetingWatcherState {
        switch current {
        case .idle:
            return micActive ? .micActive : .idle
        case .micActive:
            guard micActive else { return .idle }
            guard activeDuration >= MeetingWatcherTiming.startDebounce else { return .micActive }
            if let detectedCall { return .prompting(appName: detectedCall) }
            return .declined
        case .prompting:
            return micActive ? current : .idle
        case .recording:
            // Stop path uses ONLY the recorded call's window going away — never
            // the mic, which our own recorder holds open the whole time.
            // `recordingCallGone` is true only once we've actually seen the call
            // window and it then disappeared, so an app that never exposes a
            // call-like title simply never auto-stops (manual Stop still works)
            // rather than false-stopping mid-call.
            return (recordingCallGone && callGoneDuration >= MeetingWatcherTiming.endDebounce) ? .idle : current
        case .declined:
            return micActive ? current : .idle
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
    /// re-prompt, and still auto-stops it 8s after the mic goes idle (backup to
    /// the explicit Stop button). Paired with AppState.beginRecording.
    func enterRecording(appName: String) {
        recordingPID = CallDetection.activeCall()?.pid
        sawCallWindow = false
        callGoneSince = nil
        state = .recording(appName: appName)
    }

    /// Manual stop: mark declined so the poll won't immediately re-prompt while
    /// the same call's mic is still live. Resets to .idle on its own once the
    /// mic idles (see nextState's .declined case).
    func markDeclined() {
        state = .declined
    }

    private func tick() {
        guard !isSuppressed() else { return }
        let micActive = Self.microphoneInUse()
        let now = ContinuousClock.now
        if micActive { if activeSince == nil { activeSince = now } } else { activeSince = nil }
        let activeDuration = activeSince.map { now - $0 } ?? .zero

        // Frontmost-independent call detection for the start path.
        let detected = micActive ? CallDetection.activeCall() : nil

        // Recorded-call window tracking for the stop path.
        var recordingCallGone = false
        var callGoneDuration: Duration = .zero
        if case .recording = state, let pid = recordingPID {
            let hasWindow = CallDetection.hasActiveCallWindow(pid: pid)
            if hasWindow {
                sawCallWindow = true
                callGoneSince = nil
            } else if sawCallWindow, callGoneSince == nil {
                callGoneSince = now
            }
            recordingCallGone = sawCallWindow && !hasWindow
            callGoneDuration = callGoneSince.map { now - $0 } ?? .zero
        }

        let previous = state
        state = Self.nextState(current: previous, micActive: micActive, activeDuration: activeDuration,
                               detectedCall: detected?.name, recordingCallGone: recordingCallGone, callGoneDuration: callGoneDuration)

        guard state != previous else { return }
        switch state {
        case .prompting(let appName):
            pendingCallPID = detected?.pid
            onShowConsentPanel(appName) { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.recordingPID = self.pendingCallPID
                    self.sawCallWindow = false
                    self.callGoneSince = nil
                    self.state = .recording(appName: appName)
                    self.onStartRecording(appName)
                } else {
                    self.state = .declined
                }
            }
        case .idle where previous.isRecording:
            recordingPID = nil
            onStopRecording()
        default:
            break
        }
    }

    /// kAudioDevicePropertyDeviceIsRunningSomewhere on the default input device --
    /// true if *any* client in any process currently has an IO stream running,
    /// not which app specifically. Two trivial property reads, no allocation.
    nonisolated static func microphoneInUse() -> Bool {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID)
        guard deviceStatus == noErr else { return false }

        var isRunning: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let runningStatus = AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &isRunningSize, &isRunning)
        guard runningStatus == noErr else { return false }
        return isRunning != 0
    }
}

private extension MeetingWatcherState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
