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

        Divider()

        Button("Settings…") { openSettings() }
        Button("Quit OmWhisper") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
