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
    case home, history, meetings, vocabulary, aiPolish, replyAssist, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .meetings: "Meetings"
        case .vocabulary: "Vocabulary"
        case .aiPolish: "AI Polish"
        case .replyAssist: "Reply Assist"
        case .memory: "Memory"
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
            ForEach(HubSection.allCases) { section in
                NavRow(icon: section.icon, title: section.title, isSelected: selection == section, badge: section.badge)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = section }
            }
            Spacer()
        }
        .padding(12)
        .navigationSplitViewColumnWidth(min: 200, ideal: 224)
        // ponytail: DESIGN_DIRECTION.md §4 specifies an emerald-tinted "aurora"
        // underlay behind the glass material; simplified to a flat tint here
        // and left for D4's polish pass (motion/contrast) to refine into the
        // real radial-gradient treatment -- structural correctness now,
        // visual polish later matches this project's D1-D4 phasing.
        .background(
            ZStack {
                Color.Porcelain.emerald.opacity(0.06)
                Rectangle().fill(.ultraThinMaterial)
            }
        )
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
        }
    }
}

#Preview {
    HubShellView().environment(AppState())
}
