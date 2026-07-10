//
//  MiniPanelView.swift
//  OmWhisper
//
//  The menu-bar mini-panel (D3b): shown in an NSPopover on left-click of the
//  status item, right-click still shows the traditional NSMenu unchanged.
//  See docs/DESIGN_DIRECTION.md §3 and docs/hub-concept.html's minipanel
//  mockup. Rebuilt fresh on every open (AppDelegate.togglePopover) so it
//  always reflects current state -- same principle menuNeedsUpdate already
//  uses for the traditional menu.
//

import SwiftUI

/// Pure state->label mapping, extracted for direct testing.
nonisolated func miniPanelStateLine(for dictation: DictationState) -> String {
    switch dictation {
    case .idle: "Ready"
    case .starting: "Starting…"
    case .recording: "Listening…"
    case .finalizing: "Finishing…"
    }
}

struct MiniPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var lastEntry: TranscriptionEntry?
    @State private var copied = false
    let onOpenHub: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            startStopButton
            styleRow
            if let lastEntry {
                lastTranscriptionCard(lastEntry)
            }
            Divider()
            openHubRow
        }
        .padding(16)
        .frame(width: 270)
        .background(Color.Porcelain.bg)
        .task { load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OmOrbView(appState: appState, palette: .porcelain)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("OmWhisper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Text(miniPanelStateLine(for: appState.dictation))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Porcelain.dim)
            }
        }
    }

    private var startStopButton: some View {
        Button {
            appState.toggleDictation()
        } label: {
            Text(appState.dictation == .idle ? "Start Dictating" : "Stop")
                .font(.system(size: 13.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color.Porcelain.emerald, Color.Porcelain.teal], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // ponytail: DESIGN_DIRECTION.md §3 specs "click = cycle, right-click =
    // menu" for this chip -- simplified to a single Menu (click opens the
    // full style list). True right-click detection in a SwiftUI view hosted
    // inside an NSPopover needs custom AppKit gesture bridging with no
    // natural SwiftUI equivalent on macOS; a Menu satisfies the actual need
    // (pick a style) without that complexity.
    private var styleRow: some View {
        HStack {
            Text("Polish style")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Porcelain.dim)
            Spacer()
            Menu(appState.activePolishStyle?.name ?? "None") {
                ForEach(PolishStyles.all(customStyles: appState.customPolishStyles)) { style in
                    Button(style.name) { appState.activePolishStyleID = style.id }
                }
            }
            .font(.system(size: 11.5))
        }
    }

    private func lastTranscriptionCard(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .font(.system(size: 12))
                .foregroundStyle(Color.Porcelain.ink)
                .lineLimit(2)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = true
            }
            .font(.system(size: 10.5))
            .buttonStyle(.plain)
            .foregroundStyle(Color.Porcelain.mint)
        }
        .padding(10)
        .omCard()
    }

    private var openHubRow: some View {
        Button(action: onOpenHub) {
            HStack {
                Text("Open OmWhisper")
                    .font(.system(size: 12.5))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10.5))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.Porcelain.ink)
    }

    private func load() {
        lastEntry = try? appState.historyStore?.fetchPage(offset: 0, limit: 1).first
    }
}

#Preview {
    MiniPanelView(onOpenHub: {}).environment(AppState())
}
