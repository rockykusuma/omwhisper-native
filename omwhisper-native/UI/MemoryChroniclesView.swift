//
//  MemoryChroniclesView.swift
//  OmWhisper
//
//  Day list (left) + chronicle detail (right). SwiftUI-native replacement
//  for smriti's raw AppKit ChronicleTimelineSection -- that file is layout
//  reference only, per this project's established "UI sections: rebuild,
//  smriti is wireframe reference" convention (see S1's port map).
//

import SwiftUI

struct MemoryChroniclesView: View {
    @Environment(AppState.self) private var appState

    @State private var chronicles: [MemoryChronicle] = []
    @State private var selectedDay: String?
    @State private var isRegenerating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(chronicles, selection: $selectedDay) { chronicle in
                VStack(alignment: .leading) {
                    Text(chronicle.day).fontWeight(.medium)
                    Text("\(chronicle.snapshotCount) snapshot\(chronicle.snapshotCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            detail
        }
        // Always visible (not just when a chronicle is selected) -- with
        // zero chronicles generated yet (the normal first-run state), this
        // is the only way to ever produce the first one. Also doubles as
        // "regenerate today" since Chronicler.generate always overwrites.
        // ponytail: only regenerates today, not an arbitrary past day --
        // add a per-day action if users need to fix an older chronicle.
        .toolbar {
            ToolbarItem {
                Button {
                    generateTodaysChronicle()
                } label: {
                    if isRegenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Generate Today's Chronicle")
                    }
                }
                .disabled(isRegenerating)
            }
        }
        .task { load() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if chronicles.isEmpty {
            emptyState
        } else if let selectedDay, let chronicle = chronicles.first(where: { $0.day == selectedDay }) {
            ScrollView {
                Text(.init(chronicle.summary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            Text("Select a day").foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("📅").font(.system(size: 40))
            Text("Chronicles appear here once a day, generated automatically. Use \"Generate Today's Chronicle\" above to create the first one now.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        guard let store = appState.memoryStore else { return }
        do {
            chronicles = try store.listChronicles(limit: 60)
            if selectedDay == nil { selectedDay = chronicles.first?.day }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateTodaysChronicle() {
        isRegenerating = true
        Task {
            defer { isRegenerating = false }
            do {
                let result = try await appState.regenerateChronicle(day: Chronicler.dayString())
                load()
                selectedDay = result.day
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    MemoryChroniclesView().environment(AppState())
}
