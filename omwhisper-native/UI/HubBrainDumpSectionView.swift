//
//  HubBrainDumpSectionView.swift
//  OmWhisper
//
//  The hub's Brain-dump section (F5). Its own top-level sidebar slot rather than
//  a buried AI-Polish subsection — brain-dump is a dictation MODE, not a polish
//  style. Holds a "how to start" hint, the default-shape picker, and custom-shape
//  CRUD (reusing the PolishStyle editor pattern).
//

import SwiftUI

struct HubBrainDumpSectionView: View {
    @Environment(AppState.self) private var appState
    @State private var newShapeName = ""
    @State private var newShapePrompt = ""

    var body: some View {
        @Bindable var state = appState
        return PorcelainPage {
            PorcelainSection(eyebrow: "How it works") {
                Text("Ramble for as long as you like — thinking out loud, backtracking, whatever. On stop, it's restructured into your chosen shape and pasted into the app you're writing in.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Porcelain.dim)
                HStack(spacing: 6) {
                    Text("Start with").font(.system(size: 12)).foregroundStyle(Color.Porcelain.dim)
                    Text("⌘⇧D").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.Porcelain.ink)
                    Text("or the menu-bar panel.").font(.system(size: 12)).foregroundStyle(Color.Porcelain.dim)
                }
            }

            PorcelainSection(eyebrow: "Shape") {
                Picker("Default shape", selection: $state.activeBrainDumpShapeID) {
                    ForEach(BrainDumpShapes.all(customShapes: state.brainDumpShapes)) { shape in
                        Text(shape.name).tag(shape.id)
                    }
                }
                .tint(Color.Porcelain.emerald)
            }

            PorcelainSection(eyebrow: "Built-in Shapes") {
                ForEach(BrainDumpShapes.builtIns) { shape in
                    Text(shape.name).foregroundStyle(Color.Porcelain.ink)
                }
            }

            PorcelainSection(eyebrow: "Custom Shapes") {
                ForEach(state.brainDumpShapes) { shape in
                    HStack {
                        Text(shape.name).foregroundStyle(Color.Porcelain.ink)
                        Spacer()
                        Button { removeShape(shape) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.Porcelain.dim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(shape.name)")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Shape name", text: $newShapeName).porcelainField()
                    TextField("Prompt", text: $newShapePrompt, axis: .vertical)
                        .porcelainField()
                        .lineLimit(2...4)
                    Button("Add Shape", action: addShape)
                        .disabled(trimmed(newShapeName).isEmpty || trimmed(newShapePrompt).isEmpty)
                }
            }
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addShape() {
        let name = trimmed(newShapeName)
        let prompt = trimmed(newShapePrompt)
        guard !name.isEmpty, !prompt.isEmpty else { return }
        appState.brainDumpShapes.append(PolishStyle(id: UUID(), name: name, prompt: prompt, isBuiltIn: false))
        newShapeName = ""
        newShapePrompt = ""
    }

    private func removeShape(_ shape: PolishStyle) {
        appState.brainDumpShapes.removeAll { $0.id == shape.id }
        // Fall back to the first built-in if the removed shape was active.
        if appState.activeBrainDumpShapeID == shape.id {
            appState.activeBrainDumpShapeID = BrainDumpShapes.builtIns[0].id
        }
    }
}

#Preview {
    HubBrainDumpSectionView().environment(AppState())
}
