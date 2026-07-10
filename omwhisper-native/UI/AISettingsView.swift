//
//  AISettingsView.swift
//  OmWhisper
//
//  AI polish backend + style settings (M3 sub-project 1: System/Foundation
//  Models only — Ollama/Cloud are a separate sub-project). See
//  docs/superpowers/specs/2026-07-07-m3-core-ai-polish-design.md.
//

import SwiftUI

private let translateLanguages = [
    "English", "Spanish", "French", "German", "Japanese", "Chinese",
    "Hindi", "Portuguese", "Korean", "Arabic", "Russian",
]

struct AISettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newStyleName = ""
    @State private var newStylePrompt = ""
    @State private var ollamaReachable: Bool?
    @State private var ollamaModels: [String] = []
    @State private var ollamaChecking = false
    @State private var cloudKeyInput = ""
    @State private var cloudHasSavedKey = false
    @State private var cloudTesting = false
    @State private var cloudTestResult: String?

    var body: some View {
        @Bindable var state = appState
        return PorcelainPage {
            PorcelainSection(eyebrow: "Backend") {
                Picker("Polish backend", selection: $state.polishBackend) {
                    Text("Disabled").tag(PolishBackendKind.disabled)
                    Text("System (Apple Intelligence)").tag(PolishBackendKind.system)
                    Text("Ollama (local)").tag(PolishBackendKind.ollama)
                    Text("Cloud (OpenAI-compatible)").tag(PolishBackendKind.cloud)
                }
                .pickerStyle(.radioGroup)
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
            }

            if state.polishBackend == .ollama {
                PorcelainSection(eyebrow: "Ollama") {
                    TextField("Base URL", text: $state.ollamaBaseURL).porcelainField()
                    HStack {
                        Button(ollamaChecking ? "Checking…" : "Test Connection") { testOllama(state.ollamaBaseURL) }
                            .disabled(ollamaChecking)
                        if let ollamaReachable {
                            Text(ollamaReachable
                                 ? "Connected — \(ollamaModels.count) model\(ollamaModels.count == 1 ? "" : "s")"
                                 : "Couldn't reach Ollama. Is it running?")
                                .font(.caption)
                                .foregroundStyle(ollamaReachable ? Color.Porcelain.dim : .red)
                        }
                    }
                    if !ollamaModels.isEmpty {
                        Picker("Model", selection: $state.ollamaModel) {
                            Text("Select a model").tag("")
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .tint(Color.Porcelain.emerald)
                        .foregroundStyle(Color.Porcelain.ink)
                    } else if ollamaReachable == true {
                        Text("No models installed — run `ollama pull <model>` in Terminal.")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    } else if !state.ollamaModel.isEmpty {
                        Text("Model: \(state.ollamaModel)")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    }
                    Text("Runs entirely on your Mac via Ollama. Nothing leaves this device.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                }
            }

            if state.polishBackend == .cloud {
                PorcelainSection(eyebrow: "Cloud") {
                    Text("Your dictated text is sent to this provider while polishing. Secrets and PII (emails, keys, cards) are redacted before it leaves your Mac. Requires your own API key.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    TextField("API URL", text: $state.cloudAPIURL).porcelainField()
                    TextField("Model", text: $state.cloudModel).porcelainField()
                    SecureField("API key", text: $cloudKeyInput).porcelainField()
                    HStack {
                        Button("Save", action: saveCloudKey).disabled(cloudKeyInput.isEmpty)
                        Button("Clear", action: clearCloudKey).disabled(!cloudHasSavedKey)
                        Button(cloudTesting ? "Testing…" : "Test Connection", action: testCloud)
                            .disabled(cloudTesting || !cloudHasSavedKey)
                    }
                    Text(cloudHasSavedKey ? "Key saved." : "No key saved yet.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    if let cloudTestResult {
                        Text(cloudTestResult)
                            .font(.caption)
                            .foregroundStyle(cloudTestResult == "Connected." ? Color.Porcelain.dim : .red)
                    }
                }
            }

            PorcelainSection(eyebrow: "Smart Dictation & Polish Selected Text") {
                Picker("Default style", selection: $state.activePolishStyleID) {
                    ForEach(PolishStyles.all(customStyles: state.customPolishStyles)) { style in
                        Text(style.name).tag(style.id)
                    }
                }
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
                if appState.activePolishStyle?.requiresTargetLanguage == true {
                    Picker("Target language", selection: $state.translateTargetLanguage) {
                        ForEach(translateLanguages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                }
                Text("Cmd+Shift+B always polishes what you just said. Cmd+Shift+P polishes whatever's selected in the frontmost app.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }

            PorcelainSection(eyebrow: "Built-in Styles") {
                ForEach(PolishStyles.builtIns) { style in
                    Text(style.name).foregroundStyle(Color.Porcelain.ink)
                }
            }

            PorcelainSection(eyebrow: "Custom Styles") {
                ForEach(state.customPolishStyles) { style in
                    HStack {
                        Text(style.name).foregroundStyle(Color.Porcelain.ink)
                        Spacer()
                        Button {
                            removeStyle(style)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.Porcelain.dim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(style.name)")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Style name", text: $newStyleName).porcelainField()
                    TextField("Prompt", text: $newStylePrompt, axis: .vertical)
                        .porcelainField()
                        .lineLimit(2...4)
                    Button("Add Style", action: addStyle)
                        .disabled(trimmed(newStyleName).isEmpty || trimmed(newStylePrompt).isEmpty)
                }
            }
        }
        .task { cloudHasSavedKey = Keychain.loadCloudLLMKey() != nil }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func testOllama(_ baseURL: String) {
        ollamaChecking = true
        Task {
            let reachable = await Ollama.checkStatus(baseURL: baseURL)
            ollamaModels = reachable ? await Ollama.listModels(baseURL: baseURL) : []
            ollamaReachable = reachable
            ollamaChecking = false
        }
    }

    private func saveCloudKey() {
        do {
            try Keychain.saveCloudLLMKey(cloudKeyInput)
            cloudKeyInput = ""
            cloudHasSavedKey = true
            cloudTestResult = nil
        } catch {
            cloudTestResult = error.localizedDescription
        }
    }

    private func clearCloudKey() {
        try? Keychain.deleteCloudLLMKey()
        cloudHasSavedKey = false
        cloudTestResult = nil
    }

    private func testCloud() {
        cloudTesting = true
        cloudTestResult = nil
        Task {
            let key = Keychain.loadCloudLLMKey() ?? ""
            let err = await CloudLLM.testConnection(apiURL: appState.cloudAPIURL, model: appState.cloudModel, apiKey: key)
            cloudTestResult = err ?? "Connected."
            cloudTesting = false
        }
    }

    private func addStyle() {
        let name = trimmed(newStyleName)
        let prompt = trimmed(newStylePrompt)
        guard !name.isEmpty, !prompt.isEmpty else { return }
        appState.customPolishStyles.append(PolishStyle(id: UUID(), name: name, prompt: prompt, isBuiltIn: false))
        newStyleName = ""
        newStylePrompt = ""
    }

    private func removeStyle(_ style: PolishStyle) {
        appState.customPolishStyles.removeAll { $0.id == style.id }
        // Falling back to Smart Correct if the just-removed style was active —
        // activePolishStyleID would otherwise point at a style that no longer exists.
        if appState.activePolishStyleID == style.id {
            appState.activePolishStyleID = PolishStyles.builtIns[6].id
        }
    }
}

#Preview {
    AISettingsView().environment(AppState())
}
