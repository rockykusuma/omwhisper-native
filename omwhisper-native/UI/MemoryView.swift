//
//  MemoryView.swift
//  OmWhisper
//
//  Browse/search captured memory snapshots + daily chronicles. Snapshots tab
//  structurally mirrors HistoryView.swift's proven shape (searchable List,
//  debounced reload, tap-to-expand rows, pagination) -- deliberately no
//  Export menu (captured screen text isn't meant to leave the device
//  casually) and no multi-select bulk delete (single delete + Clear All
//  covers it; add bulk-select if it turns out to matter).
//

import SwiftUI

struct MemoryView: View {
    private enum Tab { case snapshots, chronicles }
    @State private var tab: Tab = .snapshots

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Snapshots").tag(Tab.snapshots)
                Text("Chronicles").tag(Tab.chronicles)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .snapshots: MemorySnapshotsView()
            case .chronicles: MemoryChroniclesView()
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

private struct MemorySnapshotsView: View {
    @Environment(AppState.self) private var appState

    @State private var entries: [MemorySnapshot] = []
    @State private var searchText = ""
    @State private var offset = 0
    @State private var canLoadMore = true
    @State private var storageInfo: (count: Int, bytes: Int64)?
    @State private var expandedID: Int64?
    @State private var errorMessage: String?
    /// snapshot id -> the passage that matched, when the hit was semantic.
    @State private var matchedPassages: [Int64: String] = [:]
    @State private var showClearConfirmation = false

    private let pageSize = 30
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            PorcelainSearchField(text: $searchText, prompt: "Search captured memory")
                .padding(11)
            if entries.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .background(Color.Porcelain.bg)
        .task(id: searchText) { await reload() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Clear all captured memory? This can't be undone.", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { clearAll() }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(entries) { entry in
                    MemorySnapshotRow(
                        entry: entry,
                        matchedPassage: entry.id.flatMap { matchedPassages[$0] },
                        isExpanded: expandedID == entry.id,
                        onToggleExpand: { expandedID = expandedID == entry.id ? nil : entry.id },
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
            Text("🧠").font(.system(size: 40))
            Text("Nothing captured yet").foregroundStyle(Color.Porcelain.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.Porcelain.bg)
    }

    /// Clear All sits here, next to the count it wipes — it was a `.toolbar` item,
    /// which put a destructive Memory-only action in the hub's *window* toolbar,
    /// where it read as global and stayed visible with the section's data offscreen.
    private var footer: some View {
        HStack {
            if let storageInfo {
                Text("\(storageInfo.count) snapshot\(storageInfo.count == 1 ? "" : "s") · \(formatBytes(storageInfo.bytes))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Porcelain.dim)
            }
            Spacer()
            if !entries.isEmpty {
                Button("Clear All", role: .destructive) { showClearConfirmation = true }
                    .font(.system(size: 11.5))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.Porcelain.bg)
    }

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
        guard let store = appState.memoryStore else { return }
        do {
            entries = try store.fetchPage(offset: 0, limit: pageSize)
            offset = entries.count
            canLoadMore = entries.count == pageSize
            storageInfo = try store.storageInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadNextPageIfNeeded(current: MemorySnapshot) {
        guard !isSearching, canLoadMore, current.id == entries.last?.id, let store = appState.memoryStore else { return }
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
        guard let store = appState.memoryStore else { return }
        do {
            // Hybrid: keyword + semantic, fused. With no embedder available
            // this returns exactly what store.search() returns.
            let hits = try store.hybridSearch(searchText, embedder: appState.memoryEmbedder, limit: 100)
            entries = SemanticIndexing.diversified(hits.map(\.snapshot), appName: { $0.appName })
            matchedPassages = Dictionary(
                hits.compactMap { h in h.snapshot.id.flatMap { id in h.matchedPassage.map { (id, $0) } } },
                uniquingKeysWith: { a, _ in a })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copy(_ entry: MemorySnapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.content, forType: .string)
    }

    private func delete(_ entry: MemorySnapshot) {
        guard let id = entry.id, let store = appState.memoryStore else { return }
        do {
            try store.delete(id: id)
            entries.removeAll { $0.id == id }
            storageInfo = try? store.storageInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAll() {
        guard let store = appState.memoryStore else { return }
        do {
            try store.deleteAll()
            loadFirstPage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Tap-to-expand row: collapsed shows app/window/2-line content preview;
/// expanded shows full content with Copy/Delete.
private struct MemorySnapshotRow: View {
    let entry: MemorySnapshot
    /// When a semantic hit, the passage that actually matched — far more useful
    /// than the first two lines of a page, which for a browser snapshot are
    /// usually sidebar chrome.
    let matchedPassage: String?
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onToggleExpand) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.appName).fontWeight(.medium).foregroundStyle(Color.Porcelain.ink)
                    Text(entry.windowTitle).foregroundStyle(Color.Porcelain.dim)
                }
                .font(.callout)
                Text(isExpanded ? entry.content : (matchedPassage ?? entry.content))
                    .lineLimit(isExpanded ? nil : 2)
                    .font(.body)
                    .foregroundStyle(Color.Porcelain.ink)
                HStack(spacing: 4) {
                    Text(entry.lastSeenAt)
                    if !entry.url.isEmpty {
                        Text("· \(entry.url)")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
                if isExpanded {
                    HStack {
                        Button("Copy", action: onCopy)
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .omRowCard()
        .accessibilityLabel("\(entry.appName), \(entry.windowTitle), \(entry.lastSeenAt)")
    }
}

#Preview {
    MemoryView().environment(AppState())
}
