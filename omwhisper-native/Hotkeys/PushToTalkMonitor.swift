//
//  PushToTalkMonitor.swift
//  OmWhisper
//
//  Push-to-talk: hold the Fn/Globe key to dictate, release to stop. Sits
//  alongside GlobalHotkey's Cmd+Shift+V toggle — this is a separate, optional
//  input path, not a replacement.
//
//  The Fn/Globe key is a pure modifier: it never produces .keyDown/.keyUp,
//  only .flagsChanged, with NSEvent.modifierFlags.contains(.function) toggling
//  as it's held/released. We track that containment across events and fire
//  onStart/onEnd only on an actual false→true / true→false transition.
//
//  Like GlobalHotkey, this requires Accessibility trust for the global monitor
//  to receive anything — the app already needs that for CGEventPost paste
//  (see PasteService), so there's no extra permission burden.
//
//  Known limitation: macOS's own "Press 🌐 to…" behavior (emoji picker,
//  dictation, etc.) can intercept the Fn key before it ever reaches this
//  monitor as a clean press/release pair. For reliable PTT, the user needs to
//  set System Settings → Keyboard → Globe key (🌐) key → "Do Nothing".
//

import AppKit
import os

private let pttLog = Logger(subsystem: "com.omwhisper.mac", category: "PushToTalk")

@MainActor
final class PushToTalkMonitor {
    private let onStart: () -> Void
    private let onEnd: () -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isFunctionKeyDown = false

    init(onStart: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onStart = onStart
        self.onEnd = onEnd
    }

    func start() {
        stop()

        // Global monitor: fires for flag changes while another app is frontmost.
        // Requires Accessibility trust — until granted, this is installed but
        // silently receives nothing.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Local monitor: fires when OmWhisper itself (e.g. the Settings window)
        // is frontmost. A modifier-only event never inserts a character into a
        // focused field, so we always return the event unchanged.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        pttLog.info("start — global monitor=\(self.globalMonitor != nil), local monitor=\(self.localMonitor != nil)")
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isFunctionKeyDown = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isDown = event.modifierFlags.contains(.function)
        guard isDown != isFunctionKeyDown else { return }
        isFunctionKeyDown = isDown
        if isDown {
            onStart()
        } else {
            onEnd()
        }
    }
}
