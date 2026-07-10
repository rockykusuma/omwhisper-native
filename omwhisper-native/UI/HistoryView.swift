//
//  HistoryView.swift
//  OmWhisper
//
//  Browse/search/export/delete dictation history — parity with the old
//  Tauri app's TranscriptionHistory.tsx (see docs/superpowers/specs/
//  2026-07-07-history-importer-design.md). Talks to AppState.historyStore
//  directly rather than proxying every HistoryStore method through AppState.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @Environment(AppState.self) private var appState

    @State private var entries: [TranscriptionEntry] = []
    @State private var searchText = ""
    @State private var offset = 0
    @State private var canLoadMore = true
    @State private var storageInfo: (count: Int, bytes: Int64)?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<Int64> = []
    @State private var expandedID: Int64?
    @State private var errorMessage: String?
    @State private var showClearConfirmation = false

    private let pageSize = 30
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 520)
        .searchable(text: $searchText, prompt: "Search transcriptions")
        .toolbar { toolbarContent }
        .task(id: searchText) { await reload() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Clear all history? This can't be undone.", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { clearAll() }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(entries) { entry in
                    HistoryRow(
                        entry: entry,
                        isSelecting: isSelecting,
                        isSelected: entry.id.map { selectedIDs.contains($0) } ?? false,
                        isExpanded: expandedID == entry.id,
                        onToggleSelect: { toggleSelect(entry) },
                        onToggleExpand: { toggleExpand(entry) },
                        onCopy: { copy(entry) },
                        onDelete: { delete(entry) }
                    )
                    .onAppear { loadNextPageIfNeeded(current: entry) }
                }
            }
            .padding(16)
        }
        .background(Color.Porcelain.bg)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("🕐").font(.system(size: 40))
            Text("No transcriptions yet").foregroundStyle(Color.Porcelain.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.Porcelain.bg)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if isSelecting, !selectedIDs.isEmpty {
                Button("Delete (\(selectedIDs.count))", role: .destructive, action: deleteSelected)
            }
            Button(isSelecting ? "Done" : "Select") {
                isSelecting.toggle()
                if !isSelecting { selectedIDs.removeAll() }
            }
            Menu("Export") {
                Button("Text (.txt)") { export(format: .text, ext: "txt") }
                Button("Markdown (.md)") { export(format: .markdown, ext: "md") }
                Button("JSON (.json)") { export(format: .json, ext: "json") }
            }
            Button("Clear All", role: .destructive) { showClearConfirmation = true }
        }
    }

    private var footer: some View {
        @Bindable var state = appState
        return HStack {
            if let storageInfo {
                Text("\(storageInfo.count) transcription\(storageInfo.count == 1 ? "" : "s") · \(formatBytes(storageInfo.bytes))")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            Spacer()
            Picker("Auto-Delete After", selection: autoDeleteBinding) {
                Text("Off").tag(0)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .frame(width: 220)
        }
        .padding(8)
        .background(Color.Porcelain.bg)
    }

    private var autoDeleteBinding: Binding<Int> {
        Binding(
            get: { appState.autoDeleteAfterDays ?? 0 },
            set: { appState.autoDeleteAfterDays = $0 == 0 ? nil : $0 }
        )
    }

    // MARK: Data

    private func reload() async {
        if isSearching {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            search()
        } else {
            loadFirstPage()
        }
    }

    private func loadFirstPage() {
        guard let store = appState.historyStore else { return }
        do {
            entries = try store.fetchPage(offset: 0, limit: pageSize)
            offset = entries.count
            canLoadMore = entries.count == pageSize
            storageInfo = try store.storageInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadNextPageIfNeeded(current: TranscriptionEntry) {
        guard !isSearching, canLoadMore, current.id == entries.last?.id, let store = appState.historyStore else { return }
        do {
            let next = try store.fetchPage(offset: offset, limit: pageSize)
            entries.append(contentsOf: next)
            offset += next.count
            canLoadMore = next.count == pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func search() {
        guard let store = appState.historyStore else { return }
        do {
            entries = try store.search(searchText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Actions

    private func toggleSelect(_ entry: TranscriptionEntry) {
        guard let id = entry.id else { return }
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func toggleExpand(_ entry: TranscriptionEntry) {
        expandedID = expandedID == entry.id ? nil : entry.id
    }

    private func copy(_ entry: TranscriptionEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    private func delete(_ entry: TranscriptionEntry) {
        guard let id = entry.id, let store = appState.historyStore else { return }
        do {
            try store.delete(id: id)
            entries.removeAll { $0.id == id }
            storageInfo = try store.storageInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() {
        guard let store = appState.historyStore else { return }
        for id in selectedIDs {
            try? store.delete(id: id)
        }
        entries.removeAll { $0.id.map { selectedIDs.contains($0) } ?? false }
        selectedIDs.removeAll()
        isSelecting = false
        storageInfo = try? store.storageInfo()
    }

    private func clearAll() {
        guard let store = appState.historyStore else { return }
        do {
            try store.deleteAll()
            loadFirstPage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(format: ExportFormat, ext: String) {
        guard let store = appState.historyStore else { return }
        do {
            let content = try store.exportAll(format: format)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "omwhisper-history.\(ext)"
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Tap-to-expand row: collapsed shows a 2-line preview; expanded shows full
/// text with Copy/Delete. In select mode, tapping toggles selection instead.
private struct HistoryRow: View {
    let entry: TranscriptionEntry
    let isSelecting: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            isSelecting ? onToggleSelect() : onToggleExpand()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.Porcelain.emerald : Color.Porcelain.dim)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .lineLimit(isExpanded ? nil : 2)
                        .foregroundStyle(Color.Porcelain.ink)
                    Text("\(entry.createdAt) · \(entry.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    if isExpanded, !isSelecting {
                        HStack {
                            Button("Copy", action: onCopy)
                            Button("Delete", role: .destructive, action: onDelete)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .omRowCard()
        .accessibilityLabel("\(entry.text), \(entry.createdAt), \(entry.wordCount) words")
    }
}

#Preview {
    HistoryView().environment(AppState())
}
