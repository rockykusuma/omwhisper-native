//
//  GeneralSettingsView.swift
//  OmWhisper
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GENERAL").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
                    Toggle("Paste into the active app when dictation stops", isOn: $state.pasteAfterStop)
                        .tint(Color.Porcelain.emerald)
                        .foregroundStyle(Color.Porcelain.ink)
                    Toggle("Launch at login", isOn: $state.launchAtLogin)
                        .tint(Color.Porcelain.emerald)
                        .foregroundStyle(Color.Porcelain.ink)
                }
                .padding(16)
                .omCard()

                Text("OmWhisper 2.0 — native rewrite in progress. See NATIVE_MIGRATION_PLAN.md.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Porcelain.bg)
    }
}

#Preview {
    GeneralSettingsView().environment(AppState())
}
