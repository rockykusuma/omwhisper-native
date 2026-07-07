//
//  OmWhisperApp.swift
//  OmWhisper
//
//  Menu-bar dictation app. See CLAUDE.md and docs/NATIVE_MIGRATION_PLAN.md.
//

import AppKit
import Observation
import Sparkle
import SwiftUI

// The menu bar is AppKit NSStatusItem + NSMenu, NOT SwiftUI MenuBarExtra:
// on macOS 26 (Tahoe) MenuBarExtra silently drops REAL mouse clicks to the item
// (synthetic AX clicks still work, which masks the bug). Verified 2026-07-07 by
// an NSStatusItem spike that registered 36/36 real trackpad clicks where
// MenuBarExtra registered none. NSStatusItem is the reliable path.
@main
struct OmWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        makeScene()
    }

    // @SceneBuilder so we can store the openSettings/openWindow actions on the
    // delegate (bridges SwiftUI to AppKit) and still return multiple scenes.
    @SceneBuilder
    private func makeScene() -> some Scene {
        let _ = {
            delegate.openSettingsAction = openSettings
            delegate.openHistoryAction = openWindow
        }()
        Settings {
            SettingsView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
        // .suppressed: without this, macOS's window-state restoration reopens this
        // window at next launch whenever the app was last killed uncleanly (e.g.
        // Xcode's Stop button) while it was open — should only appear via the menu.
        Window("History", id: "history") {
            HistoryView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    // Reads SUFeedURL from Info.plist — inert until a real appcast.xml + EdDSA
    // public key exist (SUPublicEDKey not set yet); "Check for Updates…" will
    // just fail quietly until then. startingUpdater: true begins the normal
    // scheduled background check cycle (Sparkle's own default: daily).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    // Set by OmWhisperApp.makeScene() so AppKit menu can open the SwiftUI Settings/History scenes.
    var openSettingsAction: OpenSettingsAction?
    var openHistoryAction: OpenWindowAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self          // rebuilt on each open — reflects live state
        item.menu = menu
        statusItem = item
        observeDictationState()       // keep the icon in sync while the menu is closed
    }

    // Menu-bar-only (LSUIElement) app: NSStatusItem is what keeps it alive, not a
    // window. Without this override, AppKit's default is to quit when the last
    // window closes — so closing Settings/History would kill the whole app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        let name: String = switch appState.dictation {
        case .idle: "waveform"
        case .starting, .recording: "waveform.circle.fill"
        case .finalizing: "waveform.circle"
        }
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
        addItem(to: menu, title: "History…", action: #selector(openHistory))
        addItem(to: menu, title: "Check for Updates…", action: #selector(checkForUpdates))
            .isEnabled = updaterController.updater.canCheckForUpdates
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
        openSettingsAction?()
    }

    @objc private func openHistory() {
        NSApp.activate(ignoringOtherApps: true)
        openHistoryAction?(id: "history")
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
