//
//  GeneralSettingsView.swift
//  OmWhisper
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var conflictMessage: String?

    var body: some View {
        @Bindable var state = appState
        return PorcelainPage {
            PorcelainSection(eyebrow: "Appearance") {
                Picker("Theme", selection: $state.appearancePreference) {
                    ForEach(AppearancePreference.allCases) { pref in
                        Text(pref.title).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Color.Porcelain.emerald)
                Text("Light or dark, or follow your Mac's system setting.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
            }

            PorcelainSection(eyebrow: "Recording overlay") {
                Text("How OmWhisper appears while you dictate. Every style shows warming, listening, and errors — minimal styles just skip the live words.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
                HStack(spacing: 10) {
                    ForEach(OverlayStyle.allCases) { style in
                        OverlayStyleCard(
                            style: style,
                            appState: appState,
                            isSelected: state.overlayStyle == style,
                            onSelect: { state.overlayStyle = style }
                        )
                    }
                }
                Button("Preview") { appState.previewOverlay(appState.overlayStyle) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.mint)
            }

            PorcelainSection(eyebrow: "General") {
                Toggle("Paste into the active app when dictation stops", isOn: $state.pasteAfterStop)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                Toggle("Restore my previous clipboard afterwards", isOn: $state.restoreClipboard)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
                if state.restoreClipboard {
                    HStack {
                        Text("Wait before restoring")
                            .foregroundStyle(Color.Porcelain.ink)
                        Spacer()
                        Stepper(value: $state.clipboardRestoreDelayMS, in: 0...10_000, step: 250) {
                            Text(Self.delayLabel(state.clipboardRestoreDelayMS))
                                .foregroundStyle(Color.Porcelain.dim)
                                .monospacedDigit()
                        }
                    }
                    Text("Raise this if a slow app — Electron, a remote desktop, a VM — sometimes pastes your old clipboard instead of what you dictated.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                }
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                    .tint(Color.Porcelain.emerald)
                    .foregroundStyle(Color.Porcelain.ink)
            }

            PorcelainSection(eyebrow: "Shortcuts") {
                HStack {
                    Text("Toggle dictation").foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    KeyRecorderView(combo: $state.dictationShortcut)
                }
                // Three of four shortcuts used to be hardcoded. NSEvent global
                // monitors observe rather than own, so a combo another app uses
                // fires BOTH — OmWhisper then bails silently. Being able to turn
                // one off is the direct fix, not only moving it.
                optionalShortcutRow(.smartDictation, combo: $state.smartDictationShortcut)
                optionalShortcutRow(.polishSelected, combo: $state.polishSelectedShortcut)
                optionalShortcutRow(.brainDump, combo: $state.brainDumpShortcut)

                if let conflictMessage {
                    Text(conflictMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !appState.hasAccessibilityPermission {
                    Text("Shortcuts need Accessibility to fire in other apps. Until it's granted they're saved but inactive.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Push-to-talk").foregroundStyle(Color.Porcelain.ink)
                    Spacer()
                    Picker("", selection: $state.pttKey) {
                        ForEach(PTTKey.allCases) { Text($0.display).tag($0) }
                    }
                    .labelsHidden()
                    .tint(Color.Porcelain.emerald)
                }
                if state.pttKey == .rightOption {
                    Text("Right ⌥ is also Reply Assist's double-tap gesture — they may interfere.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                }
                Button("Reset to defaults") {
                    state.dictationShortcut = .defaultDictation
                    state.smartDictationShortcut = AppState.defaultSmartDictation
                    state.polishSelectedShortcut = AppState.defaultPolishSelected
                    state.brainDumpShortcut = AppState.defaultBrainDump
                    state.pttKey = .fn
                    conflictMessage = nil
                }
                .tint(Color.Porcelain.emerald)
            }
        }
    }

    /// Milliseconds as a short label. %g drops trailing zeros on its own, so the
    /// 250ms steps read as 0.25s / 2s / 2.5s rather than 2.50s.
    static func delayLabel(_ milliseconds: Int) -> String {
        guard milliseconds > 0 else { return "immediately" }
        return String(format: "%gs", Double(milliseconds) / 1000)
    }

    /// A shortcut row that can also be turned off. Validation runs on the way
    /// in, so an unusable assignment can't be saved — the alternative is a
    /// shortcut that looks correct in the UI and silently never fires.
    private func optionalShortcutRow(_ slot: ShortcutSlot, combo: Binding<KeyCombo?>) -> some View {
        HStack {
            Text(slot.title).foregroundStyle(Color.Porcelain.ink)
            Spacer()
            if let existing = combo.wrappedValue {
                KeyRecorderView(combo: Binding(
                    get: { existing },
                    set: { proposed in
                        if let conflict = ShortcutValidation.conflict(
                            for: proposed, assigning: slot, current: appState.assignedShortcuts) {
                            conflictMessage = "\(slot.title): \(conflict.message)"
                        } else {
                            conflictMessage = nil
                            combo.wrappedValue = proposed
                        }
                    }))
                Button("Off") { combo.wrappedValue = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Porcelain.mint)
            } else {
                Text("Off").foregroundStyle(Color.Porcelain.dim)
                Button("Set") { combo.wrappedValue = appState.defaultShortcut(for: slot) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Porcelain.mint)
            }
        }
    }

}

private struct OverlayStyleCard: View {
    let style: OverlayStyle
    let appState: AppState
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                miniPreview.frame(height: 44)
                Text(style.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.Porcelain.ink)
                Text(style.caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.Porcelain.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.Porcelain.emerald.opacity(0.06) : Color.Porcelain.panel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.Porcelain.emerald : Color.Porcelain.hair,
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.title) overlay style")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // Dark HUD chips on the light card (intended contrast, per the mockup).
    @ViewBuilder private var miniPreview: some View {
        switch style {
        case .full:
            HStack(spacing: 5) {
                Circle().fill(Color.omEmerald).frame(width: 10, height: 10)
                Capsule()
                    .fill(LinearGradient(colors: [Color.omMint.opacity(0.9), Color.omMint.opacity(0.25)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 3)
            }
            .padding(.horizontal, 7)
            .frame(width: 120, height: 26)
            .background(Color.omBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
        case .orb:
            OmOrbView(appState: appState)
                .frame(width: 30, height: 30)
                .frame(width: 40, height: 40)
                .background(Color.omBackground.opacity(0.92), in: Circle())
                .overlay(Circle().strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
        case .whisperLine:
            WhisperBars(appState: appState)
                .frame(width: 64, height: 20)
                .background(Color.omBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
        }
    }
}

#Preview {
    GeneralSettingsView().environment(AppState())
}
