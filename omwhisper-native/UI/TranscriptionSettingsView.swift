//
//  TranscriptionSettingsView.swift
//  OmWhisper
//
//  Engine picker (Apple / Parakeet -- Cloud arrives in M4.2) + Parakeet's
//  model download flow. Apple stays the default; downloadProgress/
//  downloadError are local @State (not AppState-observed) because
//  ParakeetEngine is a plain class, same pattern HistoryView/MemoryView
//  already use for their own non-Observable stores.
//

import SwiftUI
import FluidAudio

struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var downloadProgress: Double?
    @State private var downloadError: String?
    @State private var isReady = false

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Engine") {
                Picker("Transcription engine", selection: $state.engineKind) {
                    Text("Apple (on-device, default)").tag(EngineKind.apple)
                    Text("Parakeet (local CoreML)").tag(EngineKind.parakeet)
                }
                .pickerStyle(.radioGroup)
                Text("Cloud streaming — coming in a future update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.engineKind == .parakeet {
                Section("Parakeet Model") {
                    if isReady {
                        Text("Ready.")
                            .foregroundStyle(.secondary)
                    } else if let downloadProgress {
                        ProgressView(value: downloadProgress)
                        Text("Downloading… \(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Download Parakeet Model", action: downloadModel)
                        if let downloadError {
                            Text(downloadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { isReady = appState.parakeetEngine.isReady }
    }

    private func downloadModel() {
        downloadError = nil
        downloadProgress = 0
        Task {
            do {
                try await appState.parakeetEngine.ensureModelsLoaded { progress in
                    Task { @MainActor in
                        downloadProgress = progress.fractionCompleted
                    }
                }
                await MainActor.run {
                    downloadProgress = nil
                    isReady = true
                }
            } catch {
                await MainActor.run {
                    downloadProgress = nil
                    downloadError = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    TranscriptionSettingsView().environment(AppState())
}
