//
//  GlobalHotkey.swift
//  OmWhisper
//
//  System-wide keyboard shortcut (default: Cmd+Shift+V, toggle dictation) that
//  fires even when OmWhisper isn't the frontmost app — the whole point of a
//  menu-bar dictation tool. Uses NSEvent global + local monitors rather than
//  Carbon's RegisterEventHotKey; this requires Accessibility trust, which the
//  app already needs for CGEventPost paste (see PasteService), so there's no
//  extra permission burden.
//

import AppKit
import os

private let hotkeyLog = Logger(subsystem: "com.omwhisper.mac", category: "GlobalHotkey")

@MainActor
final class GlobalHotkey {
    /// kVK_ANSI_V — same virtual keycode PasteService uses to synthesize Cmd+V.
    static let vKeyCode: UInt16 = 9

    private var keyCode: UInt16
    private var modifiers: NSEvent.ModifierFlags
    private let action: () -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    func start() {
        stop()

        // Global monitor: fires for keydowns in other apps. Requires Accessibility trust
        // (PasteService.hasAccessibilityPermission) — until granted, this monitor is
        // installed but silently receives nothing.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            hotkeyLog.debug("global keyDown: keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)")
            self?.handleIfMatch(event)
        }

        // Local monitor: fires when OmWhisper itself (e.g. the Settings window) is
        // frontmost, and swallows the event so it doesn't also type "v" into a field.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            hotkeyLog.debug("local keyDown: keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)")
            guard let self else { return event }
            if self.matches(event) {
                hotkeyLog.info("local hotkey matched — firing action")
                self.action()
                return nil
            }
            return event
        }

        hotkeyLog.info("start — global monitor=\(self.globalMonitor != nil), local monitor=\(self.localMonitor != nil)")
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
    }

    /// Swap the binding and restart (start() stops first). Live shortcut changes.
    func reconfigure(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        // The KeyRecorder captures the new combo from inside a local keyDown
        // monitor callback, so this runs mid-dispatch of that event. start()'s
        // stop() would removeMonitor a monitor AppKit is still iterating —
        // a use-after-free crash (worst when the new combo == the current one).
        // Defer the rebuild one runloop turn so the current event finishes first.
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    private func handleIfMatch(_ event: NSEvent) {
        guard matches(event) else { return }
        hotkeyLog.info("global hotkey matched — firing action")
        action()
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard !event.isARepeat, event.keyCode == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        return event.modifierFlags.intersection(relevant) == modifiers
    }
}
