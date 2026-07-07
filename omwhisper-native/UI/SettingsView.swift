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
            Tab("About", systemImage: "info.circle") {
                AboutSettingsView()
            }
        }
        .frame(width: 520, height: 440)
    }
}

#Preview {
    SettingsView().environment(AppState())
}
