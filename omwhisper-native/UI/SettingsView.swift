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
    /// Transcription moved out to its own hub section (see HubSection): it's a
    /// feature area, not app-wide chrome, and as a tab here the app's
    /// most-changed setting sat two levels down. What's left is genuinely
    /// app-wide, matching D2b's split.
    enum Tab: String, CaseIterable, Identifiable {
        case general, audio, mcp, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .audio: "Audio"
            case .mcp: "MCP"
            case .about: "About"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .audio: "waveform"
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
