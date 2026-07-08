//
//  MemorySettingsView.swift
//  OmWhisper
//
//  No search/browse UI here -- that's S5's job entirely. Just the toggle,
//  pause, and retention controls this sub-project's scope covers.
//

import SwiftUI

struct MemorySettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Toggle("Remember what's on screen", isOn: $state.memoryEnabled)
            if state.memoryEnabled {
                Toggle("Pause capture", isOn: $state.memoryPaused)
                Stepper("Keep for \(state.memoryRetentionDays) days", value: $state.memoryRetentionDays, in: 1...365)
            }
            Text("Periodically captures the frontmost window's visible text into a private, local, searchable memory — never leaves this Mac, off by default. Password managers and private/incognito browsing are always excluded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    MemorySettingsView().environment(AppState())
}
