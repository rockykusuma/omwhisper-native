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

@MainActor
final class MeetingConsentPanel {
    private var panel: NSPanel?
    private var countdownTimer: Timer?

    func show(appName: String, onDecision: @escaping (Bool) -> Void) {
        dismiss()

        var remaining = Int(MeetingWatcherTiming.consentTimeout.components.seconds)
        let content = MeetingConsentView(appName: appName, secondsRemaining: remaining) { [weak self] accepted in
            self?.dismiss()
            onDecision(accepted)
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

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            remaining -= 1
            guard remaining > 0 else {
                self?.dismiss()
                onDecision(false)
                return
            }
        }
    }

    func dismiss() {
        countdownTimer?.invalidate()
        countdownTimer = nil
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
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Record this \(appName) call?")
                .font(.headline)
            Text("No response in \(Int(MeetingWatcherTiming.consentTimeout.components.seconds))s = don't record. Stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Not now") { onDecision(false) }
                Spacer()
                Button("Record (\(secondsRemaining))") { onDecision(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if secondsRemaining > 0 { secondsRemaining -= 1 }
        }
    }
}
