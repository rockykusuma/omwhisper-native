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
import WhisperKit

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
    @State private var whisperDownloadProgress: Double?
    @State private var whisperDownloadError: String?
    @State private var whisperReady = false

    var body: some View {
        @Bindable var state = appState
        return PorcelainPage {
            PorcelainSection(eyebrow: "Engine") {
                Picker("Transcription engine", selection: $state.engineKind) {
                    Text("Apple (on-device, default)").tag(EngineKind.apple)
                    Text("Parakeet (local CoreML)").tag(EngineKind.parakeet)
                    Text("Cloud (AssemblyAI)").tag(EngineKind.cloud)
                    Text("Whisper (local CoreML)").tag(EngineKind.whisper)
                }
                .pickerStyle(.radioGroup)
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
            }

            if state.engineKind == .parakeet {
                PorcelainSection(eyebrow: "Parakeet Model") {
                    Picker("Model", selection: $state.parakeetModel) {
                        ForEach(ParakeetModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)

                    Text(state.parakeetModel.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)

                    if isReady {
                        Text("Ready.")
                            .foregroundStyle(Color.Porcelain.dim)
                    } else if let downloadProgress {
                        ProgressView(value: downloadProgress).tint(Color.Porcelain.emerald)
                        Text("Downloading… \(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                    } else {
                        Button("Download \(state.parakeetModel.displayName) Model", action: downloadModel)
                        if let downloadError {
                            Text(downloadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if state.engineKind == .whisper {
                PorcelainSection(eyebrow: "Whisper Model") {
                    Picker("Model", selection: $state.whisperModel) {
                        ForEach(WhisperModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)

                    Text(state.whisperModel.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)

                    Picker("Language", selection: $state.whisperLanguage) {
                        Text("Auto-detect").tag("auto")
                        ForEach(whisperLanguageOptions, id: \.code) { opt in
                            Text(opt.name).tag(opt.code)
                        }
                    }
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)

                    if whisperReady {
                        Text("Ready.")
                            .foregroundStyle(Color.Porcelain.dim)
                    } else if let whisperDownloadProgress {
                        ProgressView(value: whisperDownloadProgress).tint(Color.Porcelain.emerald)
                        Text("Downloading… \(Int(whisperDownloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                    } else {
                        Button("Download \(state.whisperModel.displayName) Model", action: downloadWhisperModel)
                        if let whisperDownloadError {
                            Text(whisperDownloadError)
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
            whisperReady = appState.whisperEngine.isReady
            hasSavedKey = Keychain.loadAssemblyAIKey() != nil
        }
        .onChange(of: appState.parakeetModel) {
            // Switching variant means the new one may not be loaded yet — re-read
            // readiness and clear any prior download progress/error for this section.
            isReady = appState.parakeetEngine.isReady
            downloadProgress = nil
            downloadError = nil
        }
        .onChange(of: appState.whisperModel) {
            whisperReady = appState.whisperEngine.isReady
            whisperDownloadProgress = nil
            whisperDownloadError = nil
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

    /// WhisperKit's language list ([name: code]) sorted by display name.
    private var whisperLanguageOptions: [(name: String, code: String)] {
        Constants.languages
            .map { (name: $0.key.capitalized, code: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func downloadWhisperModel() {
        whisperDownloadError = nil
        whisperDownloadProgress = 0
        Task {
            do {
                try await appState.whisperEngine.ensureModelLoaded { progress in
                    Task { @MainActor in
                        whisperDownloadProgress = progress.fractionCompleted
                    }
                }
                await MainActor.run {
                    whisperDownloadProgress = nil
                    whisperReady = true
                }
            } catch {
                await MainActor.run {
                    whisperDownloadProgress = nil
                    whisperDownloadError = error.localizedDescription
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
