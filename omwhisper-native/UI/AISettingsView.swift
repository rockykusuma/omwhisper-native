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

    var body: some View {
        @Bindable var state = appState
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("BACKEND").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
                    Picker("Polish backend", selection: $state.polishBackend) {
                        Text("Disabled").tag(PolishBackendKind.disabled)
                        Text("System (Apple Intelligence)").tag(PolishBackendKind.system)
                    }
                    .pickerStyle(.radioGroup)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                }
                .padding(16)
                .omCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("SMART DICTATION & POLISH SELECTED TEXT").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
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
                .padding(16)
                .omCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("BUILT-IN STYLES").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
                    ForEach(PolishStyles.builtIns) { style in
                        Text(style.name).foregroundStyle(Color.Porcelain.ink)
                    }
                }
                .padding(16)
                .omCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("CUSTOM STYLES").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
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
                    VStack(alignment: .leading) {
                        TextField("Style name", text: $newStyleName).textFieldStyle(.roundedBorder)
                        TextField("Prompt", text: $newStylePrompt, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                        Button("Add Style", action: addStyle)
                            .disabled(trimmed(newStyleName).isEmpty || trimmed(newStylePrompt).isEmpty)
                    }
                }
                .padding(16)
                .omCard()
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Porcelain.bg)
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
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
