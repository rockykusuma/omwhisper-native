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
    @State private var testing = false
    @State private var testResult: KeyTestResult?

    var body: some View {
        @Bindable var state = appState
        return PorcelainPage {
            PorcelainSection(eyebrow: "Engine") {
                Picker("Transcription engine", selection: $state.engineKind) {
                    Text("Apple (on-device, default)").tag(EngineKind.apple)
                    Text("Parakeet (local CoreML)").tag(EngineKind.parakeet)
                    Text("Cloud (AssemblyAI)").tag(EngineKind.cloud)
                }
                .pickerStyle(.radioGroup)
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
            }

            if state.engineKind == .parakeet {
                PorcelainSection(eyebrow: "Parakeet Model") {
                    if isReady {
                        Text("Ready.")
                            .foregroundStyle(Color.Porcelain.dim)
                    } else if let downloadProgress {
                        ProgressView(value: downloadProgress).tint(Color.Porcelain.emerald)
                        Text("Downloading… \(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
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
                PorcelainSection(eyebrow: "AssemblyAI API Key") {
                    Text("Streams your voice live to AssemblyAI (a third-party service) while dictating. Requires your own API key — get one at assemblyai.com.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)

                    if hasSavedKey {
                        Label("API key saved to your Keychain", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.Porcelain.emerald)
                    }

                    SecureField(hasSavedKey ? "Enter a new key to replace the saved one" : "Paste your API key",
                                text: $apiKeyInput)
                        .porcelainField()

                    HStack {
                        Button(hasSavedKey ? "Replace" : "Save", action: saveKey)
                            .disabled(apiKeyInput.isEmpty)
                        Button("Clear", action: clearKey)
                            .disabled(!hasSavedKey)
                        Button(testing ? "Testing…" : "Test Connection", action: testConnection)
                            .disabled(testing || !hasSavedKey)
                    }

                    if !hasSavedKey {
                        Text("No key saved yet.")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(testResult.ok ? Color.Porcelain.mint : .red)
                    }
                    if let keychainError {
                        Text(keychainError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
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
        testResult = nil   // the saved key changed — any prior test result is stale
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
        testResult = nil
        do {
            try Keychain.deleteAssemblyAIKey()
            hasSavedKey = false
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func testConnection() {
        guard let key = Keychain.loadAssemblyAIKey() else { return }
        testing = true
        testResult = nil
        Task {
            let error = await CloudEngine.testConnection(apiKey: key)
            await MainActor.run {
                testing = false
                testResult = error == nil
                    ? KeyTestResult(ok: true, message: "Connected — your key works.")
                    : KeyTestResult(ok: false, message: error!)
            }
        }
    }
}

private struct KeyTestResult {
    let ok: Bool
    let message: String
}

#Preview {
    TranscriptionSettingsView().environment(AppState())
}
