//
//  MeetingConsentPanel.swift
//  OmWhisper
//
//  Interactive consent prompt for meeting recording -- a NEW NSPanel, not
//  OverlayPanel reused: that panel is deliberately `ignoresMouseEvents = true`
//  for the display-only dictation HUD, incompatible with a panel that needs a
//  clickable countdown button. Non-activating, floating, top-right, matching
//  smriti's positioning. 10-second timeout -- "silence = no", always.
//

import AppKit
import Combine
import SwiftUI

/// What the consent prompt actually returned. A Bool cannot express the
/// difference between a refusal and an unanswered prompt, and treating them
/// alike is why a prompt missed during a call's pre-join screen silenced
/// recording for the whole meeting.
nonisolated enum MeetingConsent: Equatable {
    case accepted
    case declined
    case timedOut
}

@MainActor
final class MeetingConsentPanel {
    private var panel: NSPanel?
    private var countdownTask: Task<Void, Never>?

    func show(appName: String, onDecision: @escaping (MeetingConsent) -> Void) {
        dismiss()

        let initialSeconds = Int(MeetingWatcherTiming.consentTimeout.components.seconds)
        let content = MeetingConsentView(appName: appName, secondsRemaining: initialSeconds) { [weak self] consent in
            self?.dismiss()
            onDecision(consent)
        }
        let hosting = NSHostingView(rootView: content)
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.contentView = hosting
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        position(newPanel)
        newPanel.orderFrontRegardless()
        panel = newPanel
        NSSound(named: "Submarine")?.play()

        // Timeout reports .timedOut, NOT .declined -- the watcher asks once more
        // rather than treating an unseen prompt as a refusal. A Task (not a
        // @Sendable Timer block) inherits this @MainActor class's isolation, so
        // dismiss()/onDecision are safe to call and no mutable/non-Sendable
        // state is captured across a concurrency boundary. The visible
        // countdown is the SwiftUI view's own .onReceive, not this.
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: MeetingWatcherTiming.consentTimeout)
            guard !Task.isCancelled else { return }
            self?.dismiss()
            onDecision(.timedOut)
        }
    }

    func dismiss() {
        countdownTask?.cancel()
        countdownTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
    }
}

private struct MeetingConsentView: View {
    let appName: String
    @State var secondsRemaining: Int
    let onDecision: (MeetingConsent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.omEmerald).frame(width: 8, height: 8)
                Text("Record this \(appName) call?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.omGlyphCore)
            }
            Text("No answer? We'll ask once more, then leave it. Stays on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(Color.omGlyphCore.opacity(0.55))
            HStack {
                Button("Not now") { onDecision(.declined) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.omGlyphCore.opacity(0.55))
                Spacer()
                Button { onDecision(.accepted) } label: {
                    Text("Record (\(secondsRemaining))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(white: 0.03))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                LinearGradient(colors: [Color.omEmerald, Color.omTeal],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color.omBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1)
        )
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if secondsRemaining > 0 { secondsRemaining -= 1 }
        }
    }
}
