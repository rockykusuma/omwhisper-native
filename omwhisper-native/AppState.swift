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

enum DictationState: Equatable {
    case idle
    case starting     // toggle fired, awaiting permissions / capture start (claimed synchronously)
    case recording
    case finalizing   // stop pressed, waiting for final transcript / paste
}

@MainActor
@Observable
final class AppState {
    // MARK: Live session
    var dictation: DictationState = .idle
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

    /// Consumes the engine's event stream and applies it to `volatileTranscript`/
    /// `finalizedTranscript`. Awaited on stop so paste happens after the last
    /// final result, not before.
    private var transcriptionTask: Task<Void, Never>?

    var hasAccessibilityPermission: Bool {
        PasteService.hasAccessibilityPermission()
    }

    init() {
        log.info("AppState.init — accessibility=\(PasteService.hasAccessibilityPermission())")
        hotkey.start()
        log.info("AppState.init — hotkey monitors installed")
    }

    // MARK: Actions

    func toggleDictation() {
        log.info("toggleDictation — state=\(String(describing: self.dictation))")
        switch dictation {
        case .idle:
            // Claim the state synchronously (before any await) so a second fast
            // toggle can't pass startDictation's guard and double-start.
            dictation = .starting
            Task { await startDictation() }
        case .recording:
            Task { await stopDictation() }
        case .starting, .finalizing:
            log.info("toggleDictation — ignored (state=\(String(describing: self.dictation)))")
        }
    }

    func startDictation() async {
        log.info("startDictation — begin")
        // Caller (toggleDictation) claimed .starting synchronously; this guard
        // rejects direct calls made from any other state.
        guard dictation == .starting else {
            log.warning("startDictation — aborted (state=\(String(describing: self.dictation)))")
            return
        }
        errorMessage = nil

        log.info("startDictation — requesting mic permission")
        let micGranted = await requestMicrophonePermission()
        log.info("startDictation — mic granted=\(micGranted)")
        guard micGranted else {
            errorMessage = "OmWhisper needs microphone access. Enable it in System Settings > Privacy & Security > Microphone."
            dictation = .idle
            return
        }

        log.info("startDictation — requesting speech permission")
        let speechGranted = await requestSpeechPermission()
        log.info("startDictation — speech granted=\(speechGranted)")
        guard speechGranted else {
            errorMessage = "OmWhisper needs Speech Recognition access. Enable it in System Settings > Privacy & Security > Speech Recognition."
            dictation = .idle
            return
        }

        finalizedTranscript = ""
        volatileTranscript = ""

        do {
            log.info("startDictation — starting audio capture")
            let audioStream = try audioCapture.start()
            dictation = .recording
            log.info("startDictation — audio capture started, showing overlay")
            overlay.show(appState: self)

            log.info("startDictation — starting transcription engine")
            let events = engine.transcribe(audioStream)
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                log.info("transcriptionTask — draining events")
                do {
                    for try await event in events {
                        switch event {
                        case .partial(let text):
                            log.debug("transcript partial: \(text)")
                            self.volatileTranscript = text
                        case .final(let text):
                            log.info("transcript final: \(text)")
                            self.finalizedTranscript += text
                            self.volatileTranscript = ""
                        }
                    }
                    log.info("transcriptionTask — event stream ended normally")
                } catch {
                    log.error("transcriptionTask — engine error: \(error)")
                    self.errorMessage = error.localizedDescription
                }
            }
        } catch {
            log.error("startDictation — audio capture failed: \(error)")
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            dictation = .idle
            overlay.hide()
        }
    }

    func stopDictation() async {
        log.info("stopDictation — begin")
        guard dictation == .recording else {
            log.warning("stopDictation — aborted (state=\(String(describing: self.dictation)))")
            return
        }
        dictation = .finalizing

        audioCapture.stop()
        log.info("stopDictation — audio capture stopped, awaiting final transcript")
        await transcriptionTask?.value
        transcriptionTask = nil

        let text = (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        log.info("stopDictation — final text length=\(text.count), pasting=\(self.pasteAfterStop && !text.isEmpty)")
        if pasteAfterStop, !text.isEmpty {
            PasteService.paste(text)
        }

        overlay.hide()
        dictation = .idle
        log.info("stopDictation — done")
    }

    // MARK: Permissions

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
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
}
