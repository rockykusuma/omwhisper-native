//
//  VocabularySettingsView.swift
//  OmWhisper
//
//  Custom vocabulary (biases AppleEngine via AnalysisContext.contextualStrings)
//  + word replacements + fuzzy-match toggle. See VocabularyProcessing.swift for
//  the actual matching/correction algorithms.
//

import SwiftUI

struct VocabularySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        @Bindable var state = appState
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CUSTOM WORDS").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
                    ForEach(state.customVocabulary, id: \.self) { word in
                        VocabularyWordRow(
                            word: word,
                            onSave: { updated in replaceWord(word, with: updated) },
                            onDelete: { removeWord(word) }
                        )
                    }
                    HStack {
                        TextField("Add a word or phrase", text: $newWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addWord)
                        Button("Add", action: addWord)
                            .disabled(trimmed(newWord).isEmpty)
                    }
                }
                .padding(16)
                .omCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("AUTO-REPLACEMENTS").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Color.Porcelain.dim)
                    ForEach(state.wordReplacements, id: \.from) { rule in
                        ReplacementRuleRow(
                            rule: rule,
                            onSave: { updated in saveReplacement(updated) },
                            onDelete: { removeReplacement(rule) }
                        )
                    }
                    HStack {
                        TextField("Replace…", text: $newFrom).textFieldStyle(.roundedBorder)
                        Text("→").foregroundStyle(Color.Porcelain.dim)
                        TextField("With…", text: $newTo)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addReplacement)
                        Button("Add", action: addReplacement)
                            .disabled(trimmed(newFrom).isEmpty)
                    }
                }
                .padding(16)
                .omCard()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Fuzzy-match near-miss words", isOn: $state.fuzzyVocabCorrection)
                        .tint(Color.Porcelain.emerald)
                        .foregroundStyle(Color.Porcelain.ink)
                    Text("Auto-correct near-misses to your terms. Off by default.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    Text("Examples: \"okay\" → \"OK\" · \"gonna\" → \"going to\" · \"OmWhisper\" as a custom word")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    Divider().padding(.vertical, 4)
                    Toggle("Use On-Screen Context", isOn: $state.contextAwareDictationEnabled)
                        .tint(Color.Porcelain.emerald)
                        .foregroundStyle(Color.Porcelain.ink)
                    Text("Reads the frontmost window's visible text when dictation starts, to bias recognition toward names and terms already on screen. Nothing is stored. Off by default.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
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

    // MARK: Custom words

    private func addWord() {
        let word = trimmed(newWord)
        guard !word.isEmpty, !appState.customVocabulary.contains(word) else { return }
        appState.customVocabulary.append(word)
        newWord = ""
    }

    private func removeWord(_ word: String) {
        appState.customVocabulary.removeAll { $0 == word }
    }

    private func replaceWord(_ old: String, with new: String) {
        guard let index = appState.customVocabulary.firstIndex(of: old) else { return }
        // ForEach(id: \.self) needs unique elements — skip if the new value would
        // collide with a different existing entry.
        guard new == old || !appState.customVocabulary.contains(new) else { return }
        appState.customVocabulary[index] = new
    }

    // MARK: Replacements

    private func addReplacement() {
        let from = trimmed(newFrom)
        guard !from.isEmpty else { return }
        saveReplacement(ReplacementRule(from: from, to: trimmed(newTo)))
        newFrom = ""
        newTo = ""
    }

    private func removeReplacement(_ rule: ReplacementRule) {
        appState.wordReplacements.removeAll { $0.from == rule.from }
    }

    /// Case-sensitive exact match on `from` — overwrites in place (mirrors the
    /// old app's HashMap-insert semantics); appends if no existing rule matches.
    private func saveReplacement(_ rule: ReplacementRule) {
        var rules = appState.wordReplacements
        if let index = rules.firstIndex(where: { $0.from == rule.from }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        appState.wordReplacements = rules
    }
}

/// Tap-to-edit row for a single vocabulary word. Uses local draft state rather
/// than binding the TextField directly to the array element — a direct binding
/// would change `id: \.self`'s identity on every keystroke.
private struct VocabularyWordRow: View {
    let word: String
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack {
            if isEditing {
                TextField("Word", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
            } else {
                Text(word)
                    .foregroundStyle(Color.Porcelain.ink)
                    .onTapGesture { draft = word; isEditing = true }
            }
            Spacer()
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.Porcelain.dim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(word)")
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onSave(trimmed) }
        isEditing = false
    }
}

/// Tap-to-edit row for a replacement rule — same local-draft-state discipline
/// as `VocabularyWordRow`.
private struct ReplacementRuleRow: View {
    let rule: ReplacementRule
    let onSave: (ReplacementRule) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var draftFrom = ""
    @State private var draftTo = ""

    var body: some View {
        HStack {
            if isEditing {
                TextField("From", text: $draftFrom)
                    .textFieldStyle(.roundedBorder)
                Text("→").foregroundStyle(Color.Porcelain.dim)
                TextField("To", text: $draftTo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
            } else {
                Text(rule.from).foregroundStyle(Color.Porcelain.ink)
                Text("→").foregroundStyle(Color.Porcelain.dim)
                Text(rule.to)
                    .foregroundStyle(Color.Porcelain.ink)
                    .onTapGesture {
                        draftFrom = rule.from
                        draftTo = rule.to
                        isEditing = true
                    }
            }
            Spacer()
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.Porcelain.dim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete replacement for \(rule.from)")
        }
    }

    private func commit() {
        let from = draftFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty else { isEditing = false; return }
        onSave(ReplacementRule(from: from, to: draftTo.trimmingCharacters(in: .whitespacesAndNewlines)))
        isEditing = false
    }
}

#Preview {
    VocabularySettingsView().environment(AppState())
}
