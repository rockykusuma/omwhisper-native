//
//  OmWhisperApp.swift
//  OmWhisper
//
//  Menu-bar dictation app. See CLAUDE.md and docs/NATIVE_MIGRATION_PLAN.md.
//

import SwiftUI

@main
struct OmWhisperApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(appState)
        } label: {
            // TODO(M2): swap for the ॐ template icon from the Tauri repo's tray-icon.png
            Image(systemName: appState.dictation == .idle ? "waveform" : "waveform.badge.mic")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
