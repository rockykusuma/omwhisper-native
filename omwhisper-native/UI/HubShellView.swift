//
//  HubShellView.swift
//  OmWhisper
//
//  The hub window: a Porcelain NavigationSplitView shell around seven content
//  sections. D2a only -- purely additive, reached via a new "Hub (Preview)…"
//  menu item alongside the existing Settings/History/Memory windows, which
//  this does not touch. See docs/DESIGN_DIRECTION.md §2 for the approved IA
//  and docs/superpowers/plans/2026-07-10-d2a-hub-shell-migrations.md's Global
//  Constraints for the three gaps this plan resolved (Reply Assist, Memory's
//  nav presence, Home-is-a-placeholder).
//

import SwiftUI

/// Lets a nested section jump the hub elsewhere -- e.g. a chronicle that can't
/// be written offering "Open AI settings" rather than telling the user to go
/// find it. An environment value rather than state on AppState: this is view
/// navigation, it persists nothing, and AppState is already the app's largest
/// type. Defaults to a no-op, so a view hosted outside the hub (previews, the
/// mini-panel) still compiles and simply does nothing.
private struct HubNavigateKey: EnvironmentKey {
    static let defaultValue: (HubSection) -> Void = { _ in }
}

extension EnvironmentValues {
    var hubNavigate: (HubSection) -> Void {
        get { self[HubNavigateKey.self] }
        set { self[HubNavigateKey.self] = newValue }
    }
}

enum HubSection: String, CaseIterable, Identifiable {
    // Order here IS the sidebar order (contentSections filters allCases).
    // Transcription sits under Vocabulary and above AI Polish: it's a feature
    // area, not app-wide chrome, and it's the counterpart to AI Polish —
    // speech -> text, then text -> better text. It was a Settings tab, which
    // buried the app's most-changed setting two levels down.
    case home, history, meetings, vocabulary, transcription, aiPolish, brainDump, replyAssist, memory, settings

    var id: String { rawValue }

    /// The main sidebar list -- everything except `.settings`, which renders
    /// separately in the footer (hub-concept.html's `.side-foot` treatment).
    static var contentSections: [HubSection] {
        allCases.filter { $0 != .settings }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .meetings: "Meetings"
        case .vocabulary: "Vocabulary"
        case .transcription: "Transcription"
        case .aiPolish: "AI Polish"
        case .brainDump: "Brain-dump"
        case .replyAssist: "Reply Assist"
        case .memory: "Memory"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .meetings: "person.2"
        case .vocabulary: "textformat.abc"
        case .transcription: "waveform.badge.mic"
        case .aiPolish: "sparkles"
        case .brainDump: "list.bullet.rectangle"
        case .replyAssist: "text.bubble"
        case .memory: "brain"
        case .settings: "gearshape"
        }
    }

}

struct HubShellView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: HubSection = .home

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .environment(\.hubNavigate) { selection = $0 }
                .frame(minWidth: 480, minHeight: 520)
                .background(Color.Porcelain.bg)
                .id(selection)
                .transition(.opacity)
                .animation(PorcelainMotion.resolved(reduceMotion: reduceMotion), value: selection)
        }
        .frame(minWidth: 760, minHeight: 560)
        // Set once here, not per control: native controls (segmented pickers,
        // toggles, borderless buttons) default to the SYSTEM accent — stock blue,
        // against a green palette. `.tint` flows down the environment, so every
        // section inherits it and a newly added control can't quietly land blue.
        // Explicit .tint on an individual control still wins where one is set.
        .tint(Color.Porcelain.emerald)
        .porcelainWindow(colorScheme: appState.appearancePreference.colorScheme)
        .preferredColorScheme(appState.appearancePreference.colorScheme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brandRow
            ForEach(HubSection.contentSections) { section in
                Button {
                    selection = section
                } label: {
                    NavRow(icon: section.icon, title: section.title, isSelected: selection == section)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selection == section ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
            Divider().padding(.vertical, 4)
            Button {
                selection = .settings
            } label: {
                NavRow(icon: HubSection.settings.icon, title: HubSection.settings.title, isSelected: selection == .settings)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(HubSection.settings.title)
            .accessibilityAddTraits(selection == .settings ? [.isButton, .isSelected] : .isButton)
            privacyStatusLine
        }
        .padding(12)
        .navigationSplitViewColumnWidth(min: 200, ideal: 224)
        // `.ultraThinMaterial` is an NSVisualEffectView-backed vibrancy
        // material -- it follows system Dark Mode regardless of any SwiftUI
        // color layered under it, which rendered this sidebar as dark glass
        // instead of hub-concept.html's light frosted look (found via live
        // screenshots, 2026-07-10). Fixed, non-adaptive gradient instead —
        // still an approximation of DESIGN_DIRECTION.md §4's "aurora"
        // underlay, real radial-gradient treatment is D4b's job.
        .background(
            LinearGradient(
                colors: [Color.Porcelain.emerald.opacity(0.10), Color.Porcelain.panel2],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// hub-concept.html's "🔒 All processing on this Mac" line -- made live
    /// rather than copied verbatim, since that copy predates M4.2's CloudEngine:
    /// it would be actively misleading if the user has Cloud selected.
    ///
    /// It names the live engine and switches it in place. This complements the
    /// Transcription section rather than replacing it: the section is where you
    /// go to set things up (download a model, save a key), the footer is what
    /// tells you what's running right now and flips between things already set up.
    private var privacyStatusLine: some View {
        Menu {
            engineSwitcherItems
            Divider()
            Button("More models & downloads…") {
                selection = .transcription
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(appState.usesCloud ? Color.Porcelain.dim : Color.Porcelain.emerald)
                    .frame(width: 6, height: 6)
                Text(appState.engineStatusLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Porcelain.dim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Switch transcription engine")
        .accessibilityLabel("\(appState.engineStatusLine). Switch transcription engine.")
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    /// The quick switcher. Lists ONLY what can run right now — a downloaded model,
    /// a cloud provider with a saved key. Offering a model that isn't downloaded
    /// would set it and then fail at the next dictation (transcribe() throws
    /// modelNotDownloaded), which defeats the point of a one-click switcher;
    /// downloading stays in Settings, where the progress UI lives.
    @ViewBuilder
    private var engineSwitcherItems: some View {
        // Sarvam overrides whatever engine is picked (see AppState.activeEngine),
        // so offering engine choices under it would be a lie — the pick would
        // appear to work and change nothing. Offer the way out instead.
        if appState.crossLingualUsesSarvam {
            Button("Stop using Sarvam for cross-lingual") {
                appState.crossLingualUseSarvam = false
            }
            Text("Sarvam handles cross-lingual dictation. Turn it off to pick an engine.")
        } else {
            ForEach(engineOptions) { option in
                Button {
                    option.apply()
                } label: {
                    // A menu Button's label can't carry a checkmark on macOS the
                    // way a Picker's does, so mark the live one inline.
                    Text(option.isCurrent ? "✓  \(option.label)" : "     \(option.label)")
                }
            }
        }
    }

    private struct EngineOption: Identifiable {
        let id: String
        let label: String
        let isCurrent: Bool
        let apply: () -> Void
    }

    private var engineOptions: [EngineOption] {
        var options: [EngineOption] = [
            EngineOption(id: "apple", label: "Apple Speech", isCurrent: appState.engineKind == .apple) {
                appState.engineKind = .apple
            }
        ]
        for model in WhisperModel.allCases where WhisperEngine.isDownloaded(model) {
            options.append(EngineOption(
                id: "whisper-\(model.rawValue)",
                label: "Whisper \(model.displayName)",
                isCurrent: appState.engineKind == .whisper && appState.whisperModel == model
            ) {
                appState.whisperModel = model
                appState.engineKind = .whisper
            })
        }
        for model in ParakeetModel.allCases where ParakeetEngine.isDownloaded(model) {
            options.append(EngineOption(
                id: "parakeet-\(model.rawValue)",
                label: "Parakeet \(model.displayName)",
                isCurrent: appState.engineKind == .parakeet && appState.parakeetModel == model
            ) {
                appState.parakeetModel = model
                appState.engineKind = .parakeet
            })
        }
        for provider in CloudProviderKind.allCases where Keychain.loadSTTKey(provider) != nil {
            options.append(EngineOption(
                id: "cloud-\(provider.rawValue)",
                label: "\(provider.displayName) (online)",
                isCurrent: appState.engineKind == .cloud && appState.cloudProvider == provider
            ) {
                appState.cloudProvider = provider
                appState.engineKind = .cloud
            })
        }
        return options
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var brandRow: some View {
        HStack(spacing: 11) {
            OmBrandJewel(appState: appState, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(appDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                // Read the version; do not hardcode it. This said "2.0" while the
                // app was running 2.0.1. "listening locally" was hardcoded too,
                // and would have claimed it while streaming audio to a cloud
                // provider — the engine line in the sidebar footer is the one
                // that actually knows, so this row just carries the version.
                Text(Self.appVersion)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Porcelain.dim)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home: HubHomeView()
        case .history: HistoryView()
        case .meetings: HubMeetingsSectionView()
        case .vocabulary: VocabularySettingsView()
        case .transcription: TranscriptionSettingsView()
        case .aiPolish: AISettingsView()
        case .brainDump: HubBrainDumpSectionView()
        case .replyAssist: ReplyAssistSettingsView()
        case .memory: HubMemorySectionView()
        case .settings: SettingsView()
        }
    }
}

#Preview {
    HubShellView().environment(AppState())
}
