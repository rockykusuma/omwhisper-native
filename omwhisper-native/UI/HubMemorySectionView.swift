//
//  HubMemorySectionView.swift
//  OmWhisper
//
//  Merges MemorySettingsView's toggle/pause/retention controls with
//  MemoryView's Snapshots/Chronicles browse UI into one hub sidebar section,
//  per docs/DESIGN_DIRECTION.md §2. MemorySettingsView.swift itself is
//  untouched -- it still backs the old Settings tab's Memory row (D2a is
//  purely additive, nothing existing is removed).
//

import SwiftUI

struct HubMemorySectionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            settingsBar
            Divider()
            if state.memoryEnabled {
                MemoryView()
            } else {
                disabledEmptyState
            }
        }
    }

    private var settingsBar: some View {
        @Bindable var state = appState
        return HStack {
            Toggle("Remember what's on screen", isOn: $state.memoryEnabled)
            Spacer()
            if state.memoryEnabled {
                Menu {
                    Toggle("Pause capture", isOn: $state.memoryPaused)
                    Stepper("Keep for \(state.memoryRetentionDays) days", value: $state.memoryRetentionDays, in: 1...365)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .accessibilityLabel("Memory settings")
            }
        }
        .padding(10)
    }

    private var disabledEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("🧠").font(.system(size: 40))
            Text("Periodically captures the frontmost window's visible text into a private, local, searchable memory — never leaves this Mac. Password managers and private/incognito browsing are always excluded.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    HubMemorySectionView().environment(AppState())
}
