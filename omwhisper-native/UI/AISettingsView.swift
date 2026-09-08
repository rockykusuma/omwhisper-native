//
//  AISettingsView.swift
//  OmWhisper
//
//  The "AI Models" hub section: which backend each feature uses, the config
//  for Ollama and Cloud, and the polish styles. Started life as AI-polish-only
//  settings (docs/superpowers/specs/2026-07-07-m3-core-ai-polish-design.md);
//  since per-feature routing landed it also decides what leaves this Mac, which
//  is why the section stopped being called "AI Polish" on 2026-08-16.
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
    @State private var ollamaState: OllamaState?
    @State private var ollamaChecking = false
    /// Derived, not stored: the per-feature backend menu below also lists these,
    /// and one source of truth means the menu cannot disagree with the section.
    private var ollamaModels: [String] {
        if case .ready(let models) = ollamaState { return models }
        return []
    }
    @State private var cloudKeyInput = ""
    @State private var cloudHasSavedKey = false
    @State private var cloudTesting = false
    @State private var cloudTestResult: String?

    var body: some View {
        @Bindable var state = appState
        return PorcelainPage {
            PorcelainSection(eyebrow: "Backend") {
                Toggle("AI polish for dictation and selected text", isOn: $state.dictationPolishEnabled)
                    .toggleStyle(.switch)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                Text("Off by default. Governs Smart Dictation, Polish Selected Text and Re-polish — with it off, those commands paste your text unchanged. Meetings, Reply Assist and Memory have their own switches.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)

                // Polish fails SAFE -- any failure pastes the original text --
                // which means an unusable on-device model is indistinguishable
                // from polish deciding nothing needed changing. On a Mac whose
                // locale Foundation Models doesn't support that made Smart
                // Dictation a silent no-op for months. This screen is the one
                // place someone would think to look, so it has to say so.
                if let reason = SystemLLM.unavailableReason() {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.Porcelain.mint)
                        Text("\(reason) Polish will paste your text unchanged while System is selected — pick Ollama or Cloud instead.")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Answers "is polish actually running?" without waiting for a
                // streak to escalate — the question that had no answer for
                // months while Apple Intelligence silently did nothing.
                let polishState = Degradation.state(.polish)
                if polishState.streak > 0 {
                    Text("Polish has fallen back to your raw text \(polishState.streak) time\(polishState.streak == 1 ? "" : "s") in a row. \(polishState.reason ?? "")")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Always shown. Test Connection here is the ONLY thing that populates
            // the model list the rows choose from, so revealing this section only
            // once something already uses Ollama made Ollama unselectable — and
            // hid the base URL and model that long-form work still uses.
            PorcelainSection(eyebrow: "Ollama") {
                TextField("Base URL", text: $state.ollamaBaseURL).porcelainField()
                HStack {
                    Button(ollamaChecking ? "Checking…" : "Test Connection") { testOllama(state.ollamaBaseURL) }
                        .disabled(ollamaChecking)
                    // One sentence per state. This used to print "Couldn't
                    // reach Ollama. Is it running?" for all three failures,
                    // including to people who had never installed it.
                    switch ollamaState {
                    case nil:
                        EmptyView()
                    case .ready(let models):
                        Text("Connected — \(models.count) model\(models.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    case .runningNoModels:
                        Text("Connected — no models installed yet")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    case .installedNotRunning:
                        Text("Ollama is installed but not running.")
                            .font(.caption).foregroundStyle(.red)
                    case .notInstalled:
                        Text("Ollama isn't installed on this Mac.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                if !ollamaModels.isEmpty {
                    Picker("Model", selection: $state.ollamaModel) {
                        Text("Select a model").tag("")
                        ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                    }
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                } else if ollamaState == .runningNoModels || ollamaState == .notInstalled {
                    HStack(spacing: 8) {
                        Text(OllamaPresence.pullCommand)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.Porcelain.ink)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(OllamaPresence.pullCommand, forType: .string)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.emerald)
                    }
                    Text("\(OllamaPresence.recommendedModelSize) download · needs at least 16 GB of memory")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                } else if !state.ollamaModel.isEmpty {
                    Text("Model: \(state.ollamaModel)")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                }
                Text("Runs entirely on your Mac via Ollama. Nothing leaves this device.")
                    .font(.caption).foregroundStyle(Color.Porcelain.dim)
            }

            if usesCloudAnywhere || cloudHasSavedKey {
                PorcelainSection(eyebrow: "Cloud") {
                    Text("Whatever you route here is sent to this provider — dictated text, and if you choose it for them, meeting transcripts, chronicles built from captured screen text, or reply drafts. Secrets and PII (emails, keys, cards) are redacted before it leaves your Mac. Requires your own API key.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    Menu {
                        ForEach(CloudProviderPreset.all) { preset in
                            Button(preset.name) {
                                state.cloudAPIURL = preset.apiURL
                                state.cloudModel = preset.model
                            }
                        }
                    } label: {
                        Label("Fill from provider…", systemImage: "wand.and.stars")
                    }
                    .menuStyle(.button)
                    .tint(Color.Porcelain.emerald)
                    .fixedSize()
                    Text("Any OpenAI-compatible provider works (Groq, OpenRouter, Anthropic, local, …). A preset fills the URL & model — then paste that provider's key below.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    TextField("API URL", text: $state.cloudAPIURL).porcelainField()
                    TextField("Model", text: $state.cloudModel).porcelainField()
                    if cloudHasSavedKey {
                        Label("API key saved to your Keychain", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.Porcelain.emerald)
                    }
                    SecureField(cloudHasSavedKey ? "Enter a new key to replace the saved one" : "API key", text: $cloudKeyInput)
                        .porcelainField()
                    HStack {
                        Button(cloudHasSavedKey ? "Replace" : "Save", action: saveCloudKey).disabled(cloudKeyInput.isEmpty)
                        Button("Clear", action: clearCloudKey).disabled(!cloudHasSavedKey)
                        Button(cloudTesting ? "Testing…" : "Test Connection", action: testCloud)
                            .disabled(cloudTesting || !cloudHasSavedKey)
                    }
                    if !cloudHasSavedKey {
                        Text("No key saved yet.")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    }
                    if let cloudTestResult {
                        Text(cloudTestResult)
                            .font(.caption)
                            .foregroundStyle(cloudTestResult == "Connected." ? Color.Porcelain.dim : .red)
                    }
                }
            }

            PorcelainSection(eyebrow: "Which backend each feature uses") {
                backendRow(title: "Default", choice: state.defaultBackend,
                           includeDefaultOption: false) { state.defaultBackend = $0 }
                Divider().overlay(Color.Porcelain.hair)
                ForEach(AIFeature.allCases, id: \.self) { feature in
                    backendRow(title: feature.displayName,
                               choice: state.backend(for: feature),
                               includeDefaultOption: true) { state.setBackend($0, for: feature) }
                }
                Text(egressSentence)
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
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
                // Read from the live bindings — a combo written down by hand is a
                // combo that goes stale the moment anyone rebinds it.
                Text("\(appState.smartDictationShortcut?.display ?? "Smart Dictation (no shortcut)") always polishes what you just said. \(appState.polishSelectedShortcut?.display ?? "Polish Selected Text (no shortcut)") polishes whatever's selected in the frontmost app.")
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
            ollamaState = await OllamaPresence.detect(baseURL: baseURL)
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

    /// One feature's row. `.menuStyle(.button)` + `.tint` + `.fixedSize()` is
    /// required rather than cosmetic: a bare `Menu` inside a Porcelain card
    /// renders as BLANK SPACE, with no chrome and no visible label — found by
    /// screenshot during the Memory exclusions work, where it left the Apps
    /// section with no way to add anything.
    @ViewBuilder
    private func backendRow(title: String, choice: FeatureBackend,
                            includeDefaultOption: Bool,
                            set: @escaping (FeatureBackend) -> Void) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.Porcelain.ink)
            Spacer()
            Menu(label(for: choice)) {
                if includeDefaultOption {
                    Button("Default") { set(.useDefault) }
                    Divider()
                }
                // Grouped by WHERE THE DATA GOES, not by vendor. The design
                // system's rule is to state the mechanism rather than shout the
                // slogan, and this means cloud cannot be picked without reading
                // which side of the line it sits on.
                Section("On this Mac") {
                    Button("Apple Intelligence") { set(.system) }
                    ForEach(selectableOllamaModels, id: \.self) { model in
                        Button("Ollama · \(model)") { set(.ollama(model: model)) }
                    }
                }
                Section("Leaves this Mac") {
                    Button("Cloud · \(appState.cloudModel)") { set(.cloud) }
                }
            }
            .menuStyle(.button)
            .tint(Color.Porcelain.emerald)
            .fixedSize()
        }
    }

    private func label(for choice: FeatureBackend) -> String {
        switch choice {
        case .useDefault:        return "Default"
        case .system:            return "Apple Intelligence"
        case .ollama(let model): return "Ollama · \(model)"
        case .cloud:             return "Cloud · \(appState.cloudModel)"
        }
    }

    /// What the per-feature menu can offer. `ollamaModels` is transient @State
    /// reset every time the view is recreated (hub navigation does that), so on
    /// its own a row already reading `Ollama · qwen3.5:latest` could not be
    /// re-selected without clicking Test Connection again. The saved model is
    /// always offered.
    private var selectableOllamaModels: [String] {
        let saved = appState.ollamaModel
        guard !saved.isEmpty, !ollamaModels.contains(saved) else { return ollamaModels }
        return [saved] + ollamaModels
    }

    /// Resolved, not raw — and the SAME answer AppState gives the sidebar, so
    /// the two cannot disagree about the same configuration.
    private var cloudFeatures: [AIFeature] { appState.cloudFeatures }
    private var usesCloudAnywhere: Bool { !cloudFeatures.isEmpty }

    /// One factual line naming the real host — not a banner, and not repeated
    /// on every row.
    private var egressSentence: String {
        guard !cloudFeatures.isEmpty else { return "Everything stays on this Mac." }
        let names = cloudFeatures.map(\.displayName).joined(separator: ", ")
        let host = URL(string: appState.cloudAPIURL)?.host ?? appState.cloudAPIURL
        let verb = cloudFeatures.count == 1 ? "is" : "are"
        return "\(names) \(verb) sent to \(host). Everything else stays on this Mac."
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

/// Starter presets for the Cloud (OpenAI-compatible) backend. Each fills the
/// API URL + model; the user still supplies their own key. All are editable
/// afterward — presets are a convenience, not a fixed list.
private struct CloudProviderPreset: Identifiable {
    let name: String
    let apiURL: String
    let model: String
    var id: String { name }

    static let all: [CloudProviderPreset] = [
        CloudProviderPreset(name: "OpenAI", apiURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        CloudProviderPreset(name: "Anthropic (Claude)", apiURL: "https://api.anthropic.com/v1", model: "claude-3-5-sonnet-latest"),
        CloudProviderPreset(name: "Groq", apiURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
        CloudProviderPreset(name: "OpenRouter", apiURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-3.5-sonnet"),
        CloudProviderPreset(name: "Together", apiURL: "https://api.together.xyz/v1", model: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
        CloudProviderPreset(name: "Local (LM Studio)", apiURL: "http://localhost:1234/v1", model: "local-model"),
    ]
}

#Preview {
    AISettingsView().environment(AppState())
}
