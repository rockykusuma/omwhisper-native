//
//  ReplyAssistPanel.swift
//  OmWhisper
//
//  Small interactive panel offering: type intent, leave blank for a silent
//  auto-draft, or hold to speak. Positioned like MeetingConsentPanel (fixed
//  screen corner) -- NOT cursor-relative; resolving precise caret bounds via
//  AX across native/web/Electron fields is its own edge-case-prone problem,
//  out of scope for this ship (see the design spec).
//
//  A new NSPanel, not OverlayPanel (deliberately click-through) -- this needs
//  real keyboard/mouse interaction, matching MeetingConsentPanel's approach.
//

import SwiftUI

@MainActor
final class ReplyAssistPanel {
    private var panel: NSPanel?

    /// onSubmitText receives the typed intent (empty string for a silent
    /// auto-draft). onStartListening/onStopListening bracket a press-and-hold
    /// gesture on the speak button -- separate calls, not one opaque async
    /// call, because the VIEW needs to tell AppState exactly when the mouse
    /// released (matching the start/stop shape this app's own push-to-talk
    /// already uses); a single `() async -> String?` closure called on press
    /// would have no way to signal "the user just released" from outside.
    /// onCancel fires on Escape/dismiss with nothing typed.
    func show(
        mode: ReplyMode,
        onSubmitText: @escaping (String) -> Void,
        onStartListening: @escaping () -> Void,
        onStopListening: @escaping () async -> String?,
        onCancel: @escaping () -> Void
    ) {
        dismiss()
        let newPanel = makePanel()
        let view = ReplyAssistView(
            mode: mode,
            onSubmitText: { [weak self] text in
                self?.dismiss()
                onSubmitText(text)
            },
            onStartListening: onStartListening,
            onStopListening: onStopListening,
            onCancel: { [weak self] in
                self?.dismiss()
                onCancel()
            }
        )
        newPanel.contentView = NSHostingView(rootView: view)
        position(newPanel)
        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        return newPanel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
    }
}

private struct ReplyAssistView: View {
    let mode: ReplyMode
    let onSubmitText: (String) -> Void
    let onStartListening: () -> Void
    let onStopListening: () async -> String?
    let onCancel: () -> Void

    @State private var intent = ""
    @State private var isListening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Type intent, or leave blank…", text: $intent)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmitText(intent) }
            HStack {
                Button(isListening ? "Listening… release to draft" : "Hold to speak") {}
                    .buttonStyle(.bordered)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !isListening else { return }
                                isListening = true
                                onStartListening()
                            }
                            .onEnded { _ in
                                guard isListening else { return }
                                isListening = false
                                Task {
                                    let spoken = await onStopListening()
                                    onSubmitText(spoken ?? intent)
                                }
                            }
                    )
                Spacer()
                Button("Draft") { onSubmitText(intent) }
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var title: String {
        switch mode {
        case .reply: "Draft a reply"
        case .continueDraft: "Continue this draft"
        case .rewrite: "Rewrite selection"
        }
    }
}
