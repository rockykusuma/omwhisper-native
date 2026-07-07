//
//  GeneralSettingsView.swift
//  OmWhisper
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("General") {
                Toggle("Paste into the active app when dictation stops", isOn: $state.pasteAfterStop)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
            }
            Section {
                Text("OmWhisper 2.0 — native rewrite in progress. See NATIVE_MIGRATION_PLAN.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    GeneralSettingsView().environment(AppState())
}
