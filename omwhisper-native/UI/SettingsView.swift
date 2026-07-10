//
//  SettingsView.swift
//  OmWhisper
//
//  App-wide configuration only -- Vocabulary/AI/Meetings/Reply Assist/Memory
//  moved to their own hub sidebar sections in D2a (docs/superpowers/plans/
//  2026-07-10-d2a-hub-shell-migrations.md). This is now embedded as the
//  hub's Settings section content (HubShellView), not a standalone window --
//  the fixed frame that made sense for a standalone Settings window is gone;
//  it flows within the hub's own content area now.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Audio", systemImage: "waveform") {
                AudioSettingsView()
            }
            Tab("Transcription", systemImage: "waveform.badge.mic") {
                TranscriptionSettingsView()
            }
            Tab("MCP", systemImage: "point.3.connected.trianglepath.dotted") {
                MCPSettingsView()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettingsView()
            }
        }
    }
}

#Preview {
    SettingsView().environment(AppState())
}
