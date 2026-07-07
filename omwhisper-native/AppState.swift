//
//  AppState.swift
//  OmWhisper
//
//  Single source of truth for app state (fixes the Tauri app's settings-sync debt:
//  never do per-view read-modify-write of settings). Also owns the M1 core loop:
//  hotkey -> AudioCapture -> TranscriptionEngine -> overlay partials -> paste on stop.
//

import AppKit
import AVFoundation
import Foundation
import Observation
import os
import Speech

let log = Logger(subsystem: "com.omwhisper.mac", category: "AppState")
private let latencyLog = Logger(subsystem: "com.omwhisper.mac", category: "Latency")

// nonisolated: plain data, no MainActor affinity — without this, the project's
// MainActor-by-default setting also pins the synthesized Equatable conformance,
// which then can't be used from a nonisolated context (e.g. exitPhase's tests).
nonisolated enum DictationState: Equatable {
    case idle
    case starting     // toggle fired, awaiting permissions / capture start (claimed synchronously)
    case recording
    case finalizing   // stop pressed, waiting for final transcript / paste
}

/// Transient overlay-only flourish, layered on top of `.finalizing` — NOT a
/// second dictation state machine. `dictation` stays authoritative; this only
/// decorates how the overlay renders the tail end of a session, and is reset
/// to `.none` the instant `dictation` returns to `.idle`. See OVERLAY_SPEC.md §4.
nonisolated enum OverlayPhase: Equatable {
    case none
    case pasting
    case error(label: String)   // "NOTHING HEARD" | "SOMETHING BROKE — TEXT COPIED"
    case cancelled
}

@MainActor
@Observable
final class AppState {
    // MARK: Live session
    var dictation: DictationState = .idle
    /// Overlay-only exit flourish (pasting/error/cancelled) — see `OverlayPhase`.
    var overlayPhase: OverlayPhase = .none
    /// Streaming transcript: volatile (dimmed in UI) + finalized portions.
    var volatileTranscript: String = ""
    var finalizedTranscript: String = ""
    /// Set on permission failure or engine error; cleared at the start of the next attempt.
    var errorMessage: String?

    // MARK: Settings (persisted; keep keys stable — see SettingsKeys)
    var pasteAfterStop: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.pasteAfterStop) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.pasteAfterStop) }
    }
    var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.soundEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.soundEnabled) }
    }
    var customVocabulary: [String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.customVocabulary) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.customVocabulary) }
    }
    var wordReplacements: [ReplacementRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.wordReplacements) else { return [] }
            return (try? JSONDecoder().decode([ReplacementRule].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.wordReplacements) }
    }
    var fuzzyVocabCorrection: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.fuzzyVocabCorrection) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.fuzzyVocabCorrection) }
    }

    // MARK: Core loop collaborators
    private let audioCapture = AudioCapture()
    private let engine: TranscriptionEngine = AppleEngine()
    private let overlay = OverlayPanel()
    // @ObservationIgnored: hotkey is a collaborator, not observable UI state, and
    // @Observable can't instrument a `lazy` stored property (it rewrites stored
    // vars into computed ones). lazy is needed because the initializer captures self.
    @ObservationIgnored private lazy var hotkey = GlobalHotkey(
        keyCode: GlobalHotkey.vKeyCode,
        modifiers: [.command, .shift]
    ) { [weak self] in
        self?.toggleDictation()
    }
    @ObservationIgnored private lazy var pushToTalk = PushToTalkMonitor(
        onStart: { [weak self] in self?.beginPushToTalk() },
        onEnd: { [weak self] in self?.endPushToTalk() }
    )

    /// Consumes the engine's event stream and applies it to `volatileTranscript`/
    /// `finalizedTranscript`. Awaited on stop so paste happens after the last
    /// final result, not before.
    private var transcriptionTask: Task<Void, Never>?

    /// Set when Fn is released while still in .starting (permissions/capture setup in
    /// flight) — startDictation() checks this the instant it reaches .recording and
    /// immediately stops, so a quick tap-and-release doesn't get stuck recording.
    private var stopRequestedWhilePTTStarting = false

    /// PTT keydown time — set only by beginPushToTalk(), cleared on toggle-start
    /// (toggle has no "hold" concept) and after each session ends. Used to compute
    /// hold duration for the short-hold-cancel check in `exitPhase`.
    private var pttPressedAt: ContinuousClock.Instant?

    var hasAccessibilityPermission: Bool {
        PasteService.hasAccessibilityPermission()
    }

    /// Mic input level (0–1), for the overlay's voice-reactive orb. Safe to read
    /// every render-loop tick — AudioCapture isn't @Observable, so this registers
    /// no Observation dependency and can't trigger invalidation storms.
    var audioLevel: Float {
        audioCapture.level
    }

    init() {
        hotkey.start()
        pushToTalk.start()
        if !PasteService.hasAccessibilityPermission() {
            PasteService.requestAccessibilityPrompt()
        }
    }

    // MARK: Actions

    func toggleDictation() {
        switch dictation {
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            pttPressedAt = nil   // toggle has no "hold" concept — never inherit a stale PTT timestamp
            dictation = .starting
            overlay.show(appState: self)   // instant — warming look, before any permission/capture work
            Task { await startDictation() }
        case .recording:
            Task { await stopDictation() }
        case .starting, .finalizing:
            break   // ignore toggles while a transition is in flight
        }
    }

    // MARK: Push-to-talk

    func beginPushToTalk() {
        // Ignore if already toggled-on via Cmd+Shift+V, or mid-transition — same
        // one-attempt-in-flight discipline as toggleDictation's .idle case.
        guard dictation == .idle else { return }
        stopRequestedWhilePTTStarting = false
        pttPressedAt = .now
        dictation = .starting
        overlay.show(appState: self)   // instant — warming look, before any permission/capture work
        Task { await startDictation() }
    }

    func endPushToTalk() {
        switch dictation {
        case .starting:
            stopRequestedWhilePTTStarting = true
        case .recording:
            Task { await stopDictation() }
        case .idle, .finalizing:
            break   // stray release with no matching press (e.g. focus changed mid-hold) — no-op
        }
    }

    func startDictation() async {
        // Caller (toggleDictation) claimed .starting synchronously; this guard
        // rejects direct calls made from any other state.
        guard dictation == .starting else {
            log.warning("startDictation — aborted (state=\(String(describing: self.dictation)))")
            return
        }
        errorMessage = nil

        guard await requestMicrophonePermission() else {
            errorMessage = "OmWhisper needs microphone access. Enable it in System Settings > Privacy & Security > Microphone."
            overlay.hide()   // early-show already put a warming pill on screen — must tear it down too
            dictation = .idle
            return
        }

        guard await requestSpeechPermission() else {
            errorMessage = "OmWhisper needs Speech Recognition access. Enable it in System Settings > Privacy & Security > Speech Recognition."
            overlay.hide()
            dictation = .idle
            return
        }

        finalizedTranscript = ""
        volatileTranscript = ""

        do {
            let audioStream = try audioCapture.start()
            dictation = .recording
            if soundEnabled { SoundPlayer.play(.start) }
            // overlay already shown in toggleDictation()/beginPushToTalk() (early-show,
            // before permissions/capture even start) — nothing to do here.

            let recordingStartedAt = ContinuousClock.now
            var loggedFirstPartial = false

            // Snapshot once per session — read fresh at the moment this specific
            // dictation starts, not re-read per streamed partial.
            let vocabSnapshot = customVocabulary
            let replacementsSnapshot = wordReplacements
            let fuzzySnapshot = fuzzyVocabCorrection

            let events = engine.transcribe(audioStream, vocabulary: vocabSnapshot)
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                func postProcess(_ text: String) -> String {
                    var result = applyReplacements(text, rules: replacementsSnapshot)
                    if fuzzySnapshot {
                        result = fuzzyCorrect(result, dictionary: vocabSnapshot)
                    }
                    return result
                }
                do {
                    for try await event in events {
                        switch event {
                        case .partial(let text):
                            if !loggedFirstPartial {
                                loggedFirstPartial = true
                                latencyLog.info("start-to-first-partial: \(recordingStartedAt.duration(to: .now))")
                            }
                            self.volatileTranscript = postProcess(text)
                        case .final(let text):
                            self.finalizedTranscript += postProcess(text)
                            self.volatileTranscript = ""
                        }
                    }
                } catch {
                    log.error("transcriptionTask — engine error: \(error)")
                    self.errorMessage = error.localizedDescription
                }
            }

            if stopRequestedWhilePTTStarting {
                stopRequestedWhilePTTStarting = false
                Task { await stopDictation() }
            }
        } catch {
            log.error("startDictation — audio capture failed: \(error)")
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            dictation = .idle
            overlay.hide()
        }
    }

    func stopDictation() async {
        guard dictation == .recording else {
            log.warning("stopDictation — aborted (state=\(String(describing: self.dictation)))")
            return
        }
        let heldFor: Duration? = pttPressedAt.map { $0.duration(to: .now) }
        let stopRequestedAt = ContinuousClock.now
        // Stay .finalizing through the whole exit flourish (see finishOverlayExit) —
        // the overlay is mount-gated on `dictation != .idle`, so flipping to .idle
        // instantly would unmount the orb with nothing left to animate.
        dictation = .finalizing

        audioCapture.stop()
        await transcriptionTask?.value
        transcriptionTask = nil

        let text = (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // errorMessage is nil'd at the top of every startDictation() and only the
        // transcriptionTask's catch block sets it during a session — so non-nil
        // here means the engine genuinely threw, not just "recording was silent."
        let hadEngineError = errorMessage != nil
        let phase = Self.exitPhase(heldFor: heldFor, text: text, hadPartial: hadEngineError)
        overlayPhase = phase

        if phase != .cancelled, soundEnabled {
            SoundPlayer.play(.stop)
        }

        if phase == .pasting, pasteAfterStop {
            if PasteService.hasAccessibilityPermission() {
                PasteService.paste(text)
                latencyLog.info("stop-to-paste: \(stopRequestedAt.duration(to: .now))")
            } else {
                // paste() is what normally puts text on the pasteboard; since we're
                // skipping it here (no Accessibility to post Cmd+V), copy directly
                // so "Text copied" in the message below is actually true.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                errorMessage = "Text copied — grant Accessibility to auto-paste."
            }
        }

        pttPressedAt = nil
        await finishOverlayExit(exitDuration(for: phase))
    }

    /// Pure decision: what the overlay's exit flourish should be. Evaluated
    /// *after* the transcript drains (not at key-release), so a quick-but-real
    /// utterance isn't wrongly cancelled. `heldFor` is nil for a toggle-stop
    /// (no hold concept — cancel is PTT-only, see OVERLAY_SPEC.md §9).
    nonisolated static func exitPhase(heldFor: Duration?, text: String, hadPartial: Bool) -> OverlayPhase {
        if let heldFor, heldFor < .milliseconds(500), text.isEmpty {
            return .cancelled
        }
        if text.isEmpty {
            return .error(label: hadPartial ? "SOMETHING BROKE — TEXT COPIED" : "NOTHING HEARD")
        }
        return .pasting
    }

    /// ponytail: fixed per-phase durations, not user-configurable — these are
    /// brand-motion timings from OVERLAY_SPEC.md §4, tune by eye if they ever
    /// feel off, no need for a settings knob.
    private func exitDuration(for phase: OverlayPhase) -> Duration {
        switch phase {
        case .pasting: .milliseconds(420)   // sized to contain the finalize pulse (§5.5); slide (§4) runs alongside
        case .error: .milliseconds(800)
        case .cancelled: .milliseconds(120)
        case .none: .zero
        }
    }

    /// Keeps `dictation == .finalizing` (and the orb mounted) for the exit
    /// flourish's duration, then tears everything down together. Paste already
    /// fired above, before this call — animation never delays it.
    private func finishOverlayExit(_ duration: Duration) async {
        if duration > .zero {
            try? await Task.sleep(for: duration)
        }
        overlay.hide()
        dictation = .idle
        overlayPhase = .none
    }

    // MARK: Permissions

    // nonisolated: these completion handlers can fire on an arbitrary background
    // queue (SFSpeechRecognizer's does, via a TCC XPC callback thread) rather than
    // MainActor — assuming MainActor here trips Swift 6's runtime isolation check
    // and crashes (see AppState.swift concurrency note in CLAUDE.md).
    nonisolated private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

enum SettingsKeys {
    static let pasteAfterStop = "pasteAfterStop"
    static let soundEnabled = "soundEnabled"
    static let customVocabulary = "customVocabulary"
    static let wordReplacements = "wordReplacements"
    static let fuzzyVocabCorrection = "fuzzyVocabCorrection"
}
