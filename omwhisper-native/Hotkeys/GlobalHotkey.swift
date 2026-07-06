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

@MainActor
final class GlobalHotkey {
    /// kVK_ANSI_V — same virtual keycode PasteService uses to synthesize Cmd+V.
    static let vKeyCode: UInt16 = 9

    private let keyCode: UInt16
    private let modifiers: NSEvent.ModifierFlags
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
            self?.handleIfMatch(event)
        }

        // Local monitor: fires when OmWhisper itself (e.g. the Settings window) is
        // frontmost, and swallows the event so it doesn't also type "v" into a field.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.matches(event) {
                self.action()
                return nil
            }
            return event
        }
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

    private func handleIfMatch(_ event: NSEvent) {
        guard matches(event) else { return }
        action()
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard !event.isARepeat, event.keyCode == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        return event.modifierFlags.intersection(relevant) == modifiers
    }
}
