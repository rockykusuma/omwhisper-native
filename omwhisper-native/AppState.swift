//
//  AppState.swift
//  OmWhisper
//
//  Single source of truth for app state (fixes the Tauri app's settings-sync debt:
//  never do per-view read-modify-write of settings).
//

import Foundation
import Observation

enum DictationState: Equatable {
    case idle
    case recording
    case finalizing   // stop pressed, waiting for final transcript / paste
}

@Observable
final class AppState {
    // MARK: Live session
    var dictation: DictationState = .idle
    /// Streaming transcript: volatile (dimmed in UI) + finalized portions.
    var volatileTranscript: String = ""
    var finalizedTranscript: String = ""

    // MARK: Settings (persisted; keep keys stable — see SettingsKeys)
    var pasteAfterStop: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.pasteAfterStop) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.pasteAfterStop) }
    }
    var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.soundEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.soundEnabled) }
    }

    // MARK: Actions (wired in M1)
    func toggleDictation() {
        // TODO(M1): start AudioCapture → TranscriptionEngine → overlay partials → paste on stop.
        switch dictation {
        case .idle: dictation = .recording
        case .recording, .finalizing: dictation = .idle
        }
    }
}

enum SettingsKeys {
    static let pasteAfterStop = "pasteAfterStop"
    static let soundEnabled = "soundEnabled"
}
