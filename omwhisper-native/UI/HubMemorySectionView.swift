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
import UniformTypeIdentifiers

struct HubMemorySectionView: View {
    @Environment(AppState.self) private var appState
    @State private var showExclusions = false

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
        .sheet(isPresented: $showExclusions) {
            ExclusionsEditor()
                .environment(appState)
        }
    }

    /// Labeled inline controls, matching HubMeetingsSectionView's bar -- the
    /// hub's other capture feature already reads this way, down to the plain
    /// text button ("Templates…" there, "Exclusions…" here).
    ///
    /// These used to live behind a bare `ellipsis.circle` glyph. Two reasons
    /// that was wrong: Exclusions is a privacy control and was undiscoverable
    /// (nothing hinted it existed), and a Stepper inside an NSMenu is a clumsy
    /// control to operate.
    private var settingsBar: some View {
        @Bindable var state = appState
        return HStack(spacing: 14) {
            Toggle("Remember what's on screen", isOn: $state.memoryEnabled)
                .tint(Color.Porcelain.emerald)
                .foregroundStyle(Color.Porcelain.ink)
            if state.memoryEnabled {
                Toggle("Pause", isOn: $state.memoryPaused)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                Button("Exclusions…") { showExclusions = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Porcelain.mint)
                // ~1 minute of ticks. Below that it's ordinary window switching,
                // not a signal. A missing Accessibility grant produces no error
                // at all — just nils — so nothing else ever says capture stopped.
                if Degradation.state(.memoryCapture).streak >= 12 {
                    Text("Capturing nothing")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .help(Degradation.state(.memoryCapture).reason ?? "")
                }
                Spacer()
                Stepper("Keep for \(state.memoryRetentionDays) days",
                        value: $state.memoryRetentionDays, in: 1...365)
                    .foregroundStyle(Color.Porcelain.dim)
                    .font(.system(size: 12))
                    .fixedSize()
            } else {
                Spacer()
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

/// Sheet editor for everything the user has chosen never to capture: apps,
/// sites and window-title keywords. Add/remove rows, same idiom as
/// VocabularySettingsView's word list.
///
/// The hardcoded floor (password managers, private browsing, .env) is
/// deliberately NOT listed here -- those are a safety floor, not a preference,
/// and must not be switchable off by mistake.
private struct ExclusionsEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var newDomain = ""
    @State private var newKeyword = ""

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            HStack {
                Text("Exclusions")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    appsSection(state: state)
                    sitesSection(state: state)
                    keywordsSection(state: state)
                    Text("Adding an exclusion stops future capture. Anything already saved stays until you clear memory or it ages out after \(state.memoryRetentionDays) days.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    // MARK: - Apps

    private func appsSection(state: AppState) -> some View {
        PorcelainSection(eyebrow: "Apps") {
            Text("Windows belonging to these apps are never captured. Password managers are always excluded and aren't listed here.")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
            ForEach(state.memoryExcludedApps, id: \.self) { bundleID in
                HStack {
                    Text(Self.displayName(for: bundleID))
                        .foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    Button { removeApp(bundleID) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop excluding \(Self.displayName(for: bundleID))")
                }
            }
            if state.memoryExcludedApps.isEmpty {
                Text("No apps excluded yet.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            // .menuStyle(.button) + tint + fixedSize, matching AISettingsView's
            // "Fill from provider…" menu. A bare Menu inside a Porcelain card
            // draws no chrome and no visible label -- it renders as blank space,
            // which is exactly how this shipped the first time.
            Menu {
                // Running apps are the quick path -- usually you're excluding
                // something you can see. Anything else comes from the real
                // Applications folder, so an app you don't happen to have open
                // (Messages, a banking app) doesn't have to be launched first.
                ForEach(addableApps, id: \.bundleID) { app in
                    Button(app.name) { addApp(app.bundleID) }
                }
                if !addableApps.isEmpty { Divider() }
                Button("Choose from Applications…") { chooseApp() }
            } label: {
                Label("Add app…", systemImage: "plus.circle")
            }
            .menuStyle(.button)
            .tint(Color.Porcelain.emerald)
            .fixedSize()
        }
    }

    /// Running apps the user could pick, minus those already excluded.
    /// `.regular` only, so background agents and daemons never show up --
    /// OmWhisper itself is `.accessory` and so is excluded from the list too.
    private var addableApps: [(bundleID: String, name: String)] {
        let already = Set(appState.memoryExcludedApps)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let id = app.bundleIdentifier, !already.contains(id) else { return nil }
                return (bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Pick any installed app, not just a running one. NSOpenPanel scoped to
    /// applications IS the Mac's own app list -- browsing /Applications by hand
    /// or enumerating it into a 200-item menu would both be worse.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        panel.message = "Choose an app whose windows should never be captured."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        addApp(bundleID)
    }

    /// Name for an excluded app. Falls back through running app -> installed app
    /// on disk -> the raw bundle ID, so an app you excluded but don't have open
    /// still reads as "Messages" rather than "com.apple.MobileSMS", and a rule
    /// for an uninstalled app stays visible and removable instead of vanishing.
    static func displayName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private func addApp(_ bundleID: String) {
        guard !appState.memoryExcludedApps.contains(bundleID) else { return }
        appState.memoryExcludedApps.append(bundleID)
    }

    private func removeApp(_ bundleID: String) {
        appState.memoryExcludedApps.removeAll { $0 == bundleID }
    }

    // MARK: - Sites

    private func sitesSection(state: AppState) -> some View {
        PorcelainSection(eyebrow: "Sites") {
            Text("Pages on these sites are never saved to memory. Subdomains are covered too — excluding example.com also excludes docs.example.com. Only browser windows are matched.")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
            ForEach(state.memoryExcludedDomains, id: \.self) { domain in
                HStack {
                    Text(domain).foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    Button { removeDomain(domain) } label: {
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
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .disabled(Self.normalizedDomain(newDomain).isEmpty)
            }
        }
    }

    private func addDomain() {
        let domain = Self.normalizedDomain(newDomain)
        guard !domain.isEmpty, !appState.memoryExcludedDomains.contains(domain) else { return }
        appState.memoryExcludedDomains.append(domain)
        newDomain = ""
    }

    private func removeDomain(_ domain: String) {
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

    // MARK: - Window title keywords

    private func keywordsSection(state: AppState) -> some View {
        PorcelainSection(eyebrow: "Window Title Contains") {
            Text("A window whose title contains any of these is never captured. Matching is case-insensitive, and it checks the window TITLE only — not what's on the page.")
                .font(.caption)
                .foregroundStyle(Color.Porcelain.dim)
            ForEach(state.memoryExcludedTitleKeywords, id: \.self) { keyword in
                HStack {
                    Text(keyword).foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    Button { removeKeyword(keyword) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop excluding \(keyword)")
                }
            }
            if state.memoryExcludedTitleKeywords.isEmpty {
                Text("No keywords yet.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }
            HStack {
                TextField("Salary", text: $newKeyword)
                    .porcelainField()
                    .onSubmit(addKeyword)
                Button("Add", action: addKeyword)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addKeyword() {
        let keyword = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !appState.memoryExcludedTitleKeywords.contains(keyword) else { return }
        appState.memoryExcludedTitleKeywords.append(keyword)
        newKeyword = ""
    }

    private func removeKeyword(_ keyword: String) {
        appState.memoryExcludedTitleKeywords.removeAll { $0 == keyword }
    }
}

#Preview {
    HubMemorySectionView().environment(AppState())
}
