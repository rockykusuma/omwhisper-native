//
//  SettingsView.swift
//  OmWhisper
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
            Tab("Vocabulary", systemImage: "textformat.abc") {
                VocabularySettingsView()
            }
            Tab("AI", systemImage: "sparkles") {
                AISettingsView()
            }
            Tab("Meetings", systemImage: "person.2.wave.2") {
                MeetingsSettingsView()
            }
            Tab("Reply Assist", systemImage: "text.bubble") {
                ReplyAssistSettingsView()
            }
            Tab("Memory", systemImage: "brain") {
                MemorySettingsView()
            }
            Tab("MCP", systemImage: "point.3.connected.trianglepath.dotted") {
                MCPSettingsView()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettingsView()
            }
        }
        // 9 tabs (General/Audio/Vocabulary/AI/Meetings/Reply Assist/Memory/
        // MCP/About) no longer fit an icon-and-label tab bar at 520pt --
        // macOS collapses the overflow into a ">>" menu, which live testing
        // caught hiding the MCP tab. Widened to fit all 9 without overflow.
        .frame(width: 660, height: 440)
    }
}

#Preview {
    SettingsView().environment(AppState())
}
