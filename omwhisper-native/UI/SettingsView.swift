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
    private enum Tab: String, CaseIterable, Identifiable {
        case general, audio, transcription, mcp, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .audio: "Audio"
            case .transcription: "Transcription"
            case .mcp: "MCP"
            case .about: "About"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .audio: "waveform"
            case .transcription: "waveform.badge.mic"
            case .mcp: "point.3.connected.trianglepath.dotted"
            case .about: "info.circle"
            }
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.title, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.Porcelain.emerald)
            .padding(12)
            Divider()
            switch tab {
            case .general: GeneralSettingsView()
            case .audio: AudioSettingsView()
            case .transcription: TranscriptionSettingsView()
            case .mcp: MCPSettingsView()
            case .about: AboutSettingsView()
            }
        }
        .background(Color.Porcelain.bg)
    }
}

#Preview {
    SettingsView().environment(AppState())
}
