//
//  OmWhisperApp.swift
//  OmWhisper
//
//  Menu-bar dictation app. See CLAUDE.md and docs/NATIVE_MIGRATION_PLAN.md.
//

import AppKit
import Observation
import SwiftUI

// The menu bar is AppKit NSStatusItem + NSMenu, NOT SwiftUI MenuBarExtra:
// on macOS 26 (Tahoe) MenuBarExtra silently drops REAL mouse clicks to the item
// (synthetic AX clicks still work, which masks the bug). Verified 2026-07-07 by
// an NSStatusItem spike that registered 36/36 real trackpad clicks where
// MenuBarExtra registered none. NSStatusItem is the reliable path.
@main
struct OmWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Kept as a real SwiftUI scene so `showSettingsWindow:` (fired from the
        // AppKit menu below) has a window to present.
        Settings {
            SettingsView()
                .environment(delegate.appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self          // rebuilt on each open — reflects live state
        item.menu = menu
        statusItem = item
        observeDictationState()       // keep the icon in sync while the menu is closed
    }

    // MARK: Icon

    /// The menu title is rebuilt on open, but the icon must change when dictation
    /// starts/stops with the menu closed — so observe `dictation` directly.
    private func observeDictationState() {
        withObservationTracking {
            updateIcon()
        } onChange: {
            Task { @MainActor [weak self] in self?.observeDictationState() }
        }
    }

    private func updateIcon() {
        // TODO(M2): swap for the ॐ template icon. Deliberately NOT a mic glyph —
        // indistinguishable from the system mic indicator in the menu bar.
        let name = appState.dictation == .idle ? "waveform" : "waveform.circle.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "OmWhisper")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: Menu — mirrors the old MenuContent view; rebuilt on every open so
    // Start/Stop, the error line, and the accessibility item reflect current state.

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // No key equivalent: Cmd+Shift+V is owned by GlobalHotkey (a menu key
        // equivalent here would double-fire when the app is frontmost).
        addItem(to: menu,
                title: appState.dictation == .idle ? "Start Dictation" : "Stop Dictation",
                action: #selector(toggleDictation))

        if let error = appState.errorMessage {
            menu.addItem(.separator())
            menu.addItem(withTitle: error, action: nil, keyEquivalent: "")  // disabled label
        }

        menu.addItem(.separator())

        if !appState.hasAccessibilityPermission {
            addItem(to: menu, title: "Grant Accessibility Access…", action: #selector(grantAccessibility))
        }

        addItem(to: menu, title: "Settings…", action: #selector(openSettings), key: ",")
        addItem(to: menu, title: "Quit OmWhisper", action: #selector(quit), key: "q")
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self   // explicit target so status-menu items are enabled + routed here
        return item
    }

    // MARK: Actions

    @objc private func toggleDictation() { appState.toggleDictation() }
    @objc private func grantAccessibility() { PasteService.openAccessibilitySettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // macOS 14+/26 selector, with the pre-Ventura name as fallback.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
