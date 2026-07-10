//
//  TranscriptionSettingsView.swift
//  OmWhisper
//
//  Engine picker (Apple / Parakeet / Cloud) + Parakeet's model download flow
//  + Cloud's AssemblyAI API key management. downloadProgress/downloadError/
//  apiKeyInput/hasSavedKey/keychainError are local @State (not AppState-
//  observed) -- ParakeetEngine and Keychain are plain, non-Observable types,
//  same pattern HistoryView/MemoryView already use for their own stores.
//

import SwiftUI
import FluidAudio

struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var downloadProgress: Double?
    @State private var downloadError: String?
    @State private var isReady = false
    @State private var apiKeyInput = ""
    @State private var hasSavedKey = false
    @State private var keychainError: String?

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Engine") {
                Picker("Transcription engine", selection: $state.engineKind) {
                    Text("Apple (on-device, default)").tag(EngineKind.apple)
                    Text("Parakeet (local CoreML)").tag(EngineKind.parakeet)
                    Text("Cloud (AssemblyAI)").tag(EngineKind.cloud)
                }
                .pickerStyle(.radioGroup)
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

            if state.engineKind == .cloud {
                Section("AssemblyAI API Key") {
                    Text("Streams your voice live to AssemblyAI (a third-party service) while dictating. Requires your own API key — see assemblyai.com for pricing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("API key", text: $apiKeyInput)
                    HStack {
                        Button("Save", action: saveKey)
                            .disabled(apiKeyInput.isEmpty)
                        Button("Clear", action: clearKey)
                            .disabled(!hasSavedKey)
                    }
                    Text(hasSavedKey ? "Key saved." : "No key saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let keychainError {
                        Text(keychainError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            isReady = appState.parakeetEngine.isReady
            hasSavedKey = Keychain.loadAssemblyAIKey() != nil
        }
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

    private func saveKey() {
        keychainError = nil
        do {
            try Keychain.saveAssemblyAIKey(apiKeyInput)
            apiKeyInput = ""
            hasSavedKey = true
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func clearKey() {
        keychainError = nil
        do {
            try Keychain.deleteAssemblyAIKey()
            hasSavedKey = false
        } catch {
            keychainError = error.localizedDescription
        }
    }
}

#Preview {
    TranscriptionSettingsView().environment(AppState())
}
