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
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastEntry: TranscriptionEntry?
    @State private var copied = false
    let onOpenHub: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            startStopButton
            styleRow
            if appState.meetingsEnabled {
                meetingRecordRow
            }
            if let lastEntry {
                lastTranscriptionCard(lastEntry)
            }
            if !appState.hasAccessibilityPermission {
                accessibilityRow
            }
            Divider()
            footerRow
        }
        .padding(16)
        .frame(width: 270)
        .background(Color.Porcelain.bg)
        .preferredColorScheme(appState.appearancePreference.colorScheme)
        .task { load() }
    }

    /// The scheme actually in effect (explicit preference, or live system when
    /// `.system`) — for the Canvas orb, which can't read the adaptive palette.
    private var effectiveScheme: ColorScheme {
        switch appState.appearancePreference {
        case .system: colorScheme
        case .light: .light
        case .dark: .dark
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OmOrbView(appState: appState, palette: effectiveScheme == .dark ? .dark : .porcelain)
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

    // Distinct from the big "Start Dictating" gradient button above — dictation
    // and meeting recording are different actions. A ghost row, shown only when
    // meeting detection is enabled.
    private var meetingRecordRow: some View {
        Button { appState.toggleMeetingRecording() } label: {
            HStack(spacing: 6) {
                if appState.isRecordingMeeting {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Stop recording")
                } else {
                    Image(systemName: "record.circle").font(.system(size: 11))
                    Text("Record meeting")
                }
                Spacer()
            }
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.isRecordingMeeting ? Color.Porcelain.ink : Color.Porcelain.dim)
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

    // Shown only while Accessibility is missing (so auto-paste can't work). This
    // was a conditional item in the removed status-bar menu; surfaced here instead.
    private var accessibilityRow: some View {
        Button {
            PasteService.openAccessibilitySettings()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("Grant Accessibility to auto-paste")
                    .font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.Porcelain.mint)
    }

    private var footerRow: some View {
        HStack {
            Button(action: onOpenHub) {
                HStack(spacing: 5) {
                    Text("Open OmWhisper")
                        .font(.system(size: 12.5))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10.5))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.Porcelain.ink)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.Porcelain.dim)
        }
    }

    private func load() {
        lastEntry = try? appState.historyStore?.fetchPage(offset: 0, limit: 1).first
    }
}

#Preview {
    MiniPanelView(onOpenHub: {}).environment(AppState())
}
