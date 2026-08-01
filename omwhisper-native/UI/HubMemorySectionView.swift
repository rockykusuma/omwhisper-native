//
//  HubMemorySectionView.swift
//  OmWhisper
//
//  Merges MemorySettingsView's toggle/pause/retention controls with
//  MemoryView's Snapshots/Chronicles browse UI into one hub sidebar section,
//  per docs/DESIGN_DIRECTION.md §2. MemorySettingsView.swift itself is
//  untouched -- it still backs the old Settings tab's Memory row (D2a is
//  purely additive, nothing existing is removed).
//

import SwiftUI

struct HubMemorySectionView: View {
    @Environment(AppState.self) private var appState
    @State private var showExcludedSites = false

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            settingsBar
            Divider()
            if state.memoryEnabled {
                if !state.hasAccessibilityPermission {
                    accessibilityBanner
                    Divider()
                }
                MemoryView()
            } else {
                disabledEmptyState
            }
        }
        .sheet(isPresented: $showExcludedSites) {
            ExcludedDomainsEditor()
                .environment(appState)
        }
    }

    private var settingsBar: some View {
        @Bindable var state = appState
        return HStack {
            Toggle("Remember what's on screen", isOn: $state.memoryEnabled)
            Spacer()
            if state.memoryEnabled {
                Menu {
                    Toggle("Pause capture", isOn: $state.memoryPaused)
                    Stepper("Keep for \(state.memoryRetentionDays) days", value: $state.memoryRetentionDays, in: 1...365)
                    Divider()
                    Button("Excluded sites…") { showExcludedSites = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .accessibilityLabel("Memory settings")
            }
        }
        .padding(10)
    }

    // Memory capture reads the frontmost window via Accessibility; without the
    // grant, captureFrontmost() silently returns nil and nothing is ever stored
    // (the exact "nothing was captured" failure). Surface it -- the app can't
    // prompt for Accessibility, only point the user to Settings.
    private var accessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color.Porcelain.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility needed to capture")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.Porcelain.ink)
                Text("Memory reads the frontmost window's text via Accessibility. Until it's granted, nothing new is captured. Grant it, then relaunch OmWhisper.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            Spacer()
            Button("Open Settings") { PasteService.openAccessibilitySettings() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Porcelain.mint)
        }
        .padding(10)
        .background(Color.Porcelain.panel2)
    }

    private var disabledEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("🧠").font(.system(size: 40))
            Text("Periodically captures visible windows' text — the one you're working in, plus the frontmost window on each other display — into a private, local, searchable memory. Never leaves this Mac. Password managers and private/incognito browsing are always excluded.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sheet editor for the domains never captured into memory. Add/remove rows,
/// same idiom as VocabularySettingsView's word list. Input is normalized to a
/// bare host (scheme/path/www stripped) via BrowserURL.domain, so pasting a
/// full URL works.
private struct ExcludedDomainsEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var newDomain = ""

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            HStack {
                Text("Excluded sites")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            PorcelainPage {
                PorcelainSection(eyebrow: "Never Captured") {
                    Text("Pages on these sites are never saved to memory. Subdomains are covered too — excluding example.com also excludes docs.example.com. Only browser windows are matched.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    ForEach(state.memoryExcludedDomains, id: \.self) { domain in
                        HStack {
                            Text(domain).foregroundStyle(Color.Porcelain.ink)
                            Spacer()
                            Button { remove(domain) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.Porcelain.dim)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Stop excluding \(domain)")
                        }
                    }
                    if state.memoryExcludedDomains.isEmpty {
                        Text("No sites excluded yet.")
                            .font(.caption)
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    HStack {
                        TextField("example.com", text: $newDomain)
                            .porcelainField()
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(Self.normalizedDomain(newDomain).isEmpty)
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 340)
    }

    private func add() {
        let domain = Self.normalizedDomain(newDomain)
        guard !domain.isEmpty, !appState.memoryExcludedDomains.contains(domain) else { return }
        appState.memoryExcludedDomains.append(domain)
        newDomain = ""
    }

    private func remove(_ domain: String) {
        appState.memoryExcludedDomains.removeAll { $0 == domain }
    }

    /// Bare lowercased host from freeform input ("https://www.example.com/x",
    /// "www.example.com", "example.com" all -> "example.com"). Reuses
    /// BrowserURL.domain(of:), which strips scheme/path and a leading "www.".
    static func normalizedDomain(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }
        let withScheme = s.contains("://") ? s : "https://" + s
        if let host = BrowserURL.domain(of: withScheme) { return host }
        // Fallback for inputs URL(string:) can't parse: take the first path
        // segment and drop a leading www.
        var host = s.split(separator: "/").first.map(String.init) ?? s
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }
}

#Preview {
    HubMemorySectionView().environment(AppState())
}
