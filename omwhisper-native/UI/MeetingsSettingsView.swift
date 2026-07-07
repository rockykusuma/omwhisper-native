//
//  MeetingsSettingsView.swift
//  OmWhisper
//
//  Meeting detection/consent/recording settings (S3 sub-project 1). See
//  docs/superpowers/specs/2026-07-07-s3-meeting-detection-consent-recording-design.md.
//

import SwiftUI

struct MeetingsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section {
                Toggle("Detect and record meetings", isOn: $state.meetingsEnabled)
                Text("When a recognized call app is active, you'll be asked for consent before anything is recorded — a 10-second countdown, and no response means nothing is recorded. Recordings stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    MeetingsSettingsView().environment(AppState())
}
