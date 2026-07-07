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
    /// nothing was selected — detected via `changeCount` being untouched, since
    /// no app writes to the pasteboard without an actual copy action firing.
    /// NOT content-equality against the prior pasteboard value: if the current
    /// selection happens to match whatever was already on the clipboard (e.g.
    /// re-selecting text you just copied a moment ago), that's still a real,
    /// successful copy and must not be treated as "nothing selected".
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let beforeChangeCount = pasteboard.changeCount

        sendCmdC()
        // Cmd+C is asynchronous (goes through the target app's own event
        // handling) — give it a moment to land before reading the pasteboard.
        try? await Task.sleep(for: .milliseconds(150))

        guard pasteboard.changeCount != beforeChangeCount else { return nil }
        return pasteboard.string(forType: .string)
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
