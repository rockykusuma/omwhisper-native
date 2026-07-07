//
//  PasteService.swift
//  OmWhisper
//
//  Clipboard paste + clipboard restore + Accessibility permission handling.
//  Port of the Tauri app's paste.rs (macOS path). Requires Accessibility permission
//  (app is NOT sandboxed — Developer ID distribution only).
//

import AppKit
@preconcurrency import ApplicationServices

struct PasteService {
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Actively asks the OS to show the Accessibility trust prompt, unlike
    /// `hasAccessibilityPermission()` which only checks silently. Pass `true` for
    /// the prompt option so macOS shows the system "OmWhisper.app would like to
    /// control this computer" dialog if not already trusted. No-op if already
    /// trusted, or if the user was already prompted once this grant/deny cycle —
    /// macOS only shows the dialog once per cycle, that's expected system
    /// behavior, not a bug to work around.
    static func requestAccessibilityPrompt() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Put `text` on the pasteboard and send Cmd+V to the frontmost app. Returns
    /// immediately; the previous pasteboard contents are restored `restoreDelay`
    /// later on a detached timeline so the caller (stopDictation) isn't blocked for
    /// two seconds before it can reset state / hide the overlay / accept the hotkey.
    static func paste(_ text: String, restoreDelay: Duration = .seconds(2)) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendCmdV()

        // ponytail: only .string is preserved (M1); non-text clipboard content is
        // still lost on restore — that's finding M1, fix when the clipboard-
        // preservation work lands.
        Task {
            try? await Task.sleep(for: restoreDelay)
            if let saved {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    private static func sendCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Reads whatever's selected in the frontmost app, for Polish Selected Text.
    /// Simulates Cmd+C rather than reading kAXSelectedTextAttribute — AX text
    /// selection is inconsistently supported across third-party/cross-toolkit
    /// apps, whereas Cmd+C works everywhere copy already works. Returns nil if
    /// nothing was selected (pasteboard content unchanged after the copy) or if
    /// the pasteboard had no prior string content to compare against a fresh one.
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.string(forType: .string)
        let beforeChangeCount = pasteboard.changeCount

        sendCmdC()
        // Cmd+C is asynchronous (goes through the target app's own event
        // handling) — give it a moment to land before reading the pasteboard.
        try? await Task.sleep(for: .milliseconds(150))

        guard pasteboard.changeCount != beforeChangeCount else { return nil }
        let after = pasteboard.string(forType: .string)
        guard let after, after != before else { return nil }
        return after
    }

    private static func sendCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
