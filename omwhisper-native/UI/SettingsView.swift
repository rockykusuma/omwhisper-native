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
            Tab("Transcription", systemImage: "waveform.badge.mic") {
                TranscriptionSettingsView()
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
        // 10 tabs now (added Transcription) -- S5.2 already had to widen
        // this once for a 9th tab overflowing into a ">>" menu; bump ahead
        // of that recurring per-tab pattern instead of waiting to hit it again.
        .frame(width: 720, height: 440)
    }
}

#Preview {
    SettingsView().environment(AppState())
}
