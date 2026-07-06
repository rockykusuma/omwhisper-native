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
import Speech

enum DictationState: Equatable {
    case idle
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

    init() {
        hotkey.start()
    }

    // MARK: Actions

    func toggleDictation() {
        switch dictation {
        case .idle:
            Task { await startDictation() }
        case .recording:
            Task { await stopDictation() }
        case .finalizing:
            break // already stopping; ignore repeat presses
        }
    }

    func startDictation() async {
        guard dictation == .idle else { return }
        errorMessage = nil

        guard await requestMicrophonePermission() else {
            errorMessage = "OmWhisper needs microphone access. Enable it in System Settings > Privacy & Security > Microphone."
            return
        }
        guard await requestSpeechPermission() else {
            errorMessage = "OmWhisper needs Speech Recognition access. Enable it in System Settings > Privacy & Security > Speech Recognition."
            return
        }

        finalizedTranscript = ""
        volatileTranscript = ""

        do {
            let audioStream = try audioCapture.start()
            dictation = .recording
            overlay.show(appState: self)

            let events = engine.transcribe(audioStream)
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await event in events {
                        switch event {
                        case .partial(let text):
                            self.volatileTranscript = text
                        case .final(let text):
                            self.finalizedTranscript += text
                            self.volatileTranscript = ""
                        }
                    }
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            dictation = .idle
            overlay.hide()
        }
    }

    func stopDictation() async {
        guard dictation == .recording else { return }
        dictation = .finalizing

        // Ends AudioCapture's AsyncStream, which lets the engine flush its last
        // result and finish its own stream; transcriptionTask's loop then ends.
        audioCapture.stop()
        await transcriptionTask?.value
        transcriptionTask = nil

        let text = (finalizedTranscript + volatileTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if pasteAfterStop, !text.isEmpty {
            await PasteService.paste(text)
        }

        overlay.hide()
        dictation = .idle
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
