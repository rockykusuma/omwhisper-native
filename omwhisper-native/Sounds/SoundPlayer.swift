//
//  SoundPlayer.swift
//  OmWhisper
//
//  Start/stop audio cues for dictation. Uses macOS's built-in system sounds
//  (~/System/Library/Sounds) rather than bundling custom audio assets.
//  Gating on the `soundEnabled` setting is the caller's responsibility (AppState).
//

import AppKit

enum AppSound {
    case start
    case stop
}

enum SoundPlayer {
    static func play(_ sound: AppSound) {
        let name: NSSound.Name = switch sound {
        case .start: "Tink"
        case .stop: "Pop"
        }
        NSSound(named: name)?.play()
    }
}
