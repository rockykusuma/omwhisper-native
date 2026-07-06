//
//  PasteService.swift
//  OmWhisper
//
//  Frontmost-app capture + clipboard paste + clipboard restore.
//  Port of the Tauri app's paste.rs (macOS path). Requires Accessibility permission
//  (app is NOT sandboxed — Developer ID distribution only).
//

import AppKit
import ApplicationServices

struct PasteService {
    /// Capture the frontmost app *before* recording starts, so we can return focus to it.
    static func frontmostApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
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
}
