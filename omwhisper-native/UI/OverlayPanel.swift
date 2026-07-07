//
//  OverlayPanel.swift
//  OmWhisper
//
//  Non-activating floating panel that hosts OverlayView. Never takes key focus
//  or steals the frontmost app — the whole live-partials-while-you-dictate-
//  into-another-app model depends on that. Positioned bottom-center, like the
//  Tauri app's overlay window.
//

import AppKit
import SwiftUI

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?

    func show(appState: AppState) {
        let panel = panel ?? makePanel(appState: appState)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(appState: AppState) -> NSPanel {
        let hosting = NSHostingView(rootView: OverlayView().environment(appState))
        // Pill is 90pt tall (see OverlayView) + up to 14pt of exit-slide headroom
        // below it — 500x115 keeps both comfortably clear of the panel edge.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 115),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Never accept clicks/keys — this is a display-only HUD, so the frontmost
        // app (the paste target) never loses focus to it.
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = panel.frame.size
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 90
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
