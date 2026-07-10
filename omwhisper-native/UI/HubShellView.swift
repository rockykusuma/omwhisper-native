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
    case home, history, meetings, vocabulary, aiPolish, replyAssist, memory, settings

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
        case .replyAssist: "text.bubble"
        case .memory: "brain"
        case .settings: "gearshape"
        }
    }

    /// Matches hub-concept.html's "soon" badge -- Meetings' browse UI (S3
    /// sub-project 2) hasn't shipped yet, so this section is toggle-only today.
    var badge: String? {
        self == .meetings ? "S3" : nil
    }
}

struct HubShellView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: HubSection = .home

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .frame(minWidth: 480, minHeight: 520)
                .background(Color.Porcelain.bg)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brandRow
            ForEach(HubSection.contentSections) { section in
                NavRow(icon: section.icon, title: section.title, isSelected: selection == section, badge: section.badge)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = section }
            }
            Spacer()
            Divider().padding(.vertical, 4)
            NavRow(icon: HubSection.settings.icon, title: HubSection.settings.title, isSelected: selection == .settings)
                .contentShape(Rectangle())
                .onTapGesture { selection = .settings }
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
    private var privacyStatusLine: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(appState.engineKind == .cloud ? Color.Porcelain.dim : Color.Porcelain.emerald)
                .frame(width: 6, height: 6)
            Text(appState.engineKind == .cloud ? "Cloud transcription active — audio leaves this Mac" : "All processing on this Mac")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.Porcelain.dim)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var brandRow: some View {
        HStack(spacing: 10) {
            OmOrbView(appState: appState, palette: .porcelain)
                .frame(width: 34, height: 34)
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
        case .meetings: MeetingsSettingsView()
        case .vocabulary: VocabularySettingsView()
        case .aiPolish: AISettingsView()
        case .replyAssist: ReplyAssistSettingsView()
        case .memory: HubMemorySectionView()
        case .settings: SettingsView()
        }
    }
}

#Preview {
    HubShellView().environment(AppState())
}
