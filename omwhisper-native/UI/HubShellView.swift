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

enum HubSection: String, CaseIterable, Identifiable {
    case home, history, meetings, vocabulary, aiPolish, brainDump, replyAssist, memory, settings

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
    /// Which Settings tab to land on — the footer's engine line deep-links to
    /// Transcription. Part of the content `.id` below so clicking it while
    /// Settings is already open still switches tabs.
    @State private var settingsTab: SettingsView.Tab = .general

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .frame(minWidth: 480, minHeight: 520)
                .background(Color.Porcelain.bg)
                .id("\(selection.rawValue)-\(settingsTab.rawValue)")
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
                settingsTab = .general
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
    /// It also names the engine and opens Transcription settings. Which engine is
    /// running was invisible and buried two levels deep (Settings > Transcription),
    /// so it got opened constantly just to check. Chosen over promoting
    /// Transcription to its own sidebar section: engine choice is mostly one-time
    /// setup, and a permanent top-level slot would outlive the churn — the real
    /// problem was that the answer wasn't visible, not that it wasn't clickable.
    private var privacyStatusLine: some View {
        Button {
            settingsTab = .transcription
            selection = .settings
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
        .buttonStyle(.plain)
        .help("Open Transcription settings")
        .accessibilityLabel("\(appState.engineStatusLine). Open Transcription settings.")
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var brandRow: some View {
        HStack(spacing: 11) {
            OmBrandJewel(appState: appState, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("OmWhisper")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Text("2.0 · listening locally")
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
        case .aiPolish: AISettingsView()
        case .brainDump: HubBrainDumpSectionView()
        case .replyAssist: ReplyAssistSettingsView()
        case .memory: HubMemorySectionView()
        case .settings: SettingsView(initialTab: settingsTab)
        }
    }
}

#Preview {
    HubShellView().environment(AppState())
}
