//
//  GeneralSettingsView.swift
//  OmWhisper
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        return PorcelainPage {
            PorcelainSection(eyebrow: "Appearance") {
                Picker("Theme", selection: $state.appearancePreference) {
                    ForEach(AppearancePreference.allCases) { pref in
                        Text(pref.title).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Color.Porcelain.emerald)
                Text("Light or dark, or follow your Mac's system setting.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }

            PorcelainSection(eyebrow: "General") {
                Toggle("Paste into the active app when dictation stops", isOn: $state.pasteAfterStop)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
            }

            Text("OmWhisper 2.0 — native rewrite in progress. See NATIVE_MIGRATION_PLAN.md.")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
        }
    }
}

#Preview {
    GeneralSettingsView().environment(AppState())
}
