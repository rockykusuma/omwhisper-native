//
//  SoundPlayer.swift
//  OmWhisper
//
//  Start/stop audio cues for dictation. Custom cues bundled as
//  start.wav/stop.wav (Copy Bundle Resources via the file-system-synchronized
//  Sounds/ group) rather than macOS's built-in system sounds.
//  Gating on the `soundEnabled` setting is the caller's responsibility (AppState).
//

import AppKit

enum AppSound {
    case start
    case stop
}

enum SoundPlayer {
    static func play(_ sound: AppSound, volume: Float) {
        let name = switch sound {
        case .start: "start"
        case .stop: "stop"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return }
        let player = NSSound(contentsOf: url, byReference: true)
        player?.volume = volume
        player?.play()
    }
}
