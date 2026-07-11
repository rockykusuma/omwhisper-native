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
    private var countdownTask: Task<Void, Never>?

    func show(appName: String, onDecision: @escaping (Bool) -> Void) {
        dismiss()

        let initialSeconds = Int(MeetingWatcherTiming.consentTimeout.components.seconds)
        let content = MeetingConsentView(appName: appName, secondsRemaining: initialSeconds) { [weak self] accepted in
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

        // Timeout = auto-decline. A Task (not a @Sendable Timer block) inherits this
        // @MainActor class's isolation, so dismiss()/onDecision are safe to call and
        // no mutable/non-Sendable state is captured across a concurrency boundary.
        // The visible countdown is the SwiftUI view's own .onReceive, not this.
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: MeetingWatcherTiming.consentTimeout)
            guard !Task.isCancelled else { return }
            self?.dismiss()
            onDecision(false)
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
