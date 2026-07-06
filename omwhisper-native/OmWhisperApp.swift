//
//  OmWhisperApp.swift
//  OmWhisper
//
//  Menu-bar dictation app. See CLAUDE.md and docs/NATIVE_MIGRATION_PLAN.md.
//

import os
import SwiftUI

private let appLog = Logger(subsystem: "com.omwhisper.mac", category: "App")

@main
struct OmWhisperApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(appState)
        } label: {
            // TODO(M2): swap for the ॐ template icon from the Tauri repo's tray-icon.png
            Image(systemName: appState.dictation == .idle ? "mic" : "mic.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
