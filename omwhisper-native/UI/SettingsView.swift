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
            Tab("Vocabulary", systemImage: "textformat.abc") {
                VocabularySettingsView()
            }
        }
        .frame(width: 520, height: 440)
    }
}

#Preview {
    SettingsView().environment(AppState())
}
