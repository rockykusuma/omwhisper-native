//
//  MiniPanelView.swift
//  OmWhisper
//
//  The menu-bar mini-panel (D3b): shown in an NSPopover on left-click of the
//  status item, right-click still shows the traditional NSMenu unchanged.
//  See docs/DESIGN_DIRECTION.md §3 and docs/hub-concept.html's minipanel
//  mockup. Rebuilt fresh on every open (AppDelegate.togglePopover) so it
//  always reflects current state -- same principle menuNeedsUpdate already
//  uses for the traditional menu. The panel is meeting-recording-first: the
//  primary action records a meeting; dictation is driven by the hotkey/PTT.
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
    // Fast CoreAudio HAL enumeration; the popover is rebuilt on every open, so
    // this refreshes each time without a background task.
    @State private var devices = AudioCapture.availableInputDevices()
    let onOpenHub: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            recordMeetingButton
            microphoneRow
            styleRow
            crossLingualRow
            brainDumpRow
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            OmBrandJewel(appState: appState, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("OmWhisper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Text(statusLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Porcelain.dim)
            }
        }
    }

    // Meeting recording is the panel's primary action, so it leads the status
    // line; otherwise reflect dictation state (driven by the hotkey/PTT).
    private var statusLine: String {
        appState.isRecordingMeeting ? "Recording meeting…" : miniPanelStateLine(for: appState.dictation)
    }

    private var recordMeetingButton: some View {
        Button {
            appState.toggleMeetingRecording()
        } label: {
            HStack(spacing: 8) {
                if appState.isRecordingMeeting {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text("Stop recording")
                } else {
                    Image(systemName: "waveform")
                    Text("Record meeting")
                }
            }
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

    // Quick mic override, in case the right device isn't auto-selected. Bound to
    // the same audioInputDeviceUID the Audio settings tab uses — applies to both
    // dictation and meeting recording. "System Default" clears the override.
    private var microphoneRow: some View {
        HStack {
            Text("Microphone")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Porcelain.dim)
            Spacer()
            Menu(selectedMicName) {
                Button("System Default") { appState.audioInputDeviceUID = nil }
                ForEach(devices) { device in
                    Button(device.name) { appState.audioInputDeviceUID = device.uid }
                }
            }
            .font(.system(size: 11.5))
        }
    }

    // Ramble → structured shape. The dropdown sets the active shape; Start begins
    // a brain-dump (⌘⇧D does the same without opening the panel).
    private var brainDumpRow: some View {
        HStack {
            Text("Brain-dump")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Porcelain.dim)
            Menu(appState.activeBrainDumpShape?.name ?? "—") {
                ForEach(BrainDumpShapes.all(customShapes: appState.brainDumpShapes)) { shape in
                    Button(shape.name) { appState.activeBrainDumpShapeID = shape.id }
                }
            }
            .font(.system(size: 11.5))
            Spacer()
            Button("Start") { appState.beginBrainDump() }
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Porcelain.mint)
                .buttonStyle(.plain)
        }
    }

    private var selectedMicName: String {
        guard let uid = appState.audioInputDeviceUID else { return "System Default" }
        return devices.first(where: { $0.uid == uid })?.name ?? "System Default"
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

    // Quick flip before speaking another language — saves opening Settings.
    // Subtitle names the actual path so it's clear whether audio leaves the Mac.
    private var crossLingualRow: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: $state.crossLingualEnabled) {
                Text("Cross-lingual → English")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Porcelain.ink)
            }
            .toggleStyle(.switch)
            .tint(Color.Porcelain.emerald)
            if state.crossLingualEnabled {
                if Keychain.loadSarvamKey() != nil {
                    Toggle(isOn: $state.crossLingualUseSarvam) {
                        Text("Use Sarvam (cloud)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.Porcelain.dim)
                    }
                    .toggleStyle(.switch)
                    .tint(Color.Porcelain.emerald)
                    .controlSize(.mini)
                    Text(appState.crossLingualUsesSarvam ? "audio to cloud" : "on-device Whisper")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.Porcelain.dim)
                } else {
                    Text("via on-device Whisper")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.Porcelain.dim)
                }
            }
        }
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
}

#Preview {
    MiniPanelView(onOpenHub: {}).environment(AppState())
}
