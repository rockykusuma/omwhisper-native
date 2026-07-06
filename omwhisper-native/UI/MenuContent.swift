//
//  MenuContent.swift
//  OmWhisper
//

import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(appState.dictation == .idle ? "Start Dictation" : "Stop Dictation") {
            appState.toggleDictation()
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])

        if let error = appState.errorMessage {
            Divider()
            Text(error)
        }

        Divider()

        if !appState.hasAccessibilityPermission {
            Button("Grant Accessibility Access…") {
                PasteService.openAccessibilitySettings()
            }
        }

        Button("Settings…") { openSettings() }
        Button("Quit OmWhisper") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
