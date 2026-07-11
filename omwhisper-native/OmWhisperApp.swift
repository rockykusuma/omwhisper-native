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
struct OmWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        makeScene()
    }

    // @SceneBuilder so we can store the openWindow actions on the delegate
    // (bridges SwiftUI to AppKit) and still return multiple scenes.
    @SceneBuilder
    private func makeScene() -> some Scene {
        let _ = {
            delegate.openHubAction = openWindow
            delegate.openOnboardingAction = openWindow
            #if DEBUG
            delegate.openDesignGalleryAction = openWindow
            #endif
        }()
        Window("OmWhisper", id: "hub") {
            HubShellView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
        Window("Welcome", id: "onboarding") {
            OnboardingView()
                .environment(delegate.appState)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        #if DEBUG
        Window("Design Gallery", id: "design-gallery") {
            DesignGalleryView()
        }
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    #if DEBUG
    private let statusMenu = NSMenu()   // dev-tools right-click menu (DEBUG only)
    #endif
    private let popover = NSPopover()
    // Reads SUFeedURL from Info.plist — inert until a real appcast.xml + EdDSA
    // public key exist (SUPublicEDKey not set yet); "Check for Updates…" will
    // just fail quietly until then. startingUpdater: begins the normal
    // scheduled background check cycle (Sparkle's own default: daily) — never
    // under tests, see isRunningUnderTests in AppState.swift.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: !isRunningUnderTests, updaterDelegate: nil, userDriverDelegate: nil
    )
    // Set by OmWhisperApp.makeScene() so AppKit menu can open the hub/gallery scenes.
    var openHubAction: OpenWindowAction?
    var openOnboardingAction: OpenWindowAction?
    #if DEBUG
    var openDesignGalleryAction: OpenWindowAction?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip entirely under XCTest — see isRunningUnderTests in AppState.swift.
        // Without this, every `xcodebuild test` run launches a real, interactive
        // menu-bar instance that outlives the test run.
        guard !isRunningUnderTests else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        #if DEBUG
        statusMenu.delegate = self          // dev-tools menu, rebuilt on each open (DEBUG only)
        #endif
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        popover.behavior = .transient        // closes on outside click
        observeDictationState()             // keep the icon in sync while the menu is closed

        // First run: show the Welcome window once. Dispatched to the next runloop
        // tick so makeScene() has stored openOnboardingAction (same store-on-delegate
        // bridge as openHubAction). LSUIElement app → activate so it comes forward.
        if !appState.hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.openOnboardingAction?(id: "onboarding")
            }
        }
    }

    // MARK: Click routing — left-click shows the mini-panel popover,
    // right-click shows the traditional menu (docs/DESIGN_DIRECTION.md §3:
    // "menu stays as right-click fallback"). Neither is ever assigned to
    // `statusItem.menu` permanently -- doing that hands ALL clicks to the
    // menu and this button action never fires again.

    @objc private func statusItemClicked() {
        #if DEBUG
        // Debug builds keep a right-click dev-tools menu; real users get the
        // mini-panel on any click — no confusing, undiscoverable hidden menu.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        #endif
        togglePopover()
    }

    #if DEBUG
    /// Synthesizes the dev-tools menu popup for a right-click without permanently
    /// binding `statusItem.menu` (which would hijack left-clicks too).
    private func showMenu() {
        guard let item = statusItem else { return }
        item.menu = statusMenu
        item.button?.performClick(nil)
        item.menu = nil
    }
    #endif

    /// Rebuilds the popover's content fresh on every open, matching
    /// `menuNeedsUpdate`'s "read live state, never cache" principle.
    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.contentSize = NSSize(width: 270, height: 340)
        // Honor the appearance preference so the mini-panel's adaptive Porcelain
        // colors resolve to the same theme as the hub (nil = follow system).
        popover.appearance = switch appState.appearancePreference {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        popover.contentViewController = NSHostingController(
            rootView: MiniPanelView(onOpenHub: { [weak self] in
                self?.popover.performClose(nil)
                self?.openHub()
            }).environment(appState)
        )
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

    // MARK: Dev-tools menu (DEBUG only)
    // The status item shows the mini-panel on any click for real users (see
    // statusItemClicked). Everything the old menu offered lives elsewhere now:
    // Start/Stop, Open OmWhisper, and Quit are in the mini-panel; Check for
    // Updates is in Settings → About; Grant Accessibility is a contextual
    // mini-panel row. Only DEBUG dev tools remain, behind a right-click menu
    // that never ships to users.

    #if DEBUG
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem(to: menu, title: "Meeting Self-Test…", action: #selector(runMeetingSelfTest))
        addItem(to: menu, title: "Memory Self-Test…", action: #selector(runMemorySelfTest))
        addItem(to: menu, title: "Design Gallery…", action: #selector(openDesignGallery))
        addItem(to: menu, title: "Reset Onboarding…", action: #selector(resetOnboarding))
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
    #endif

    // MARK: Actions

    // Called from the mini-panel's "Open OmWhisper" row (via a closure), not a menu.
    private func openHub() {
        NSApp.activate(ignoringOtherApps: true)
        openHubAction?(id: "hub")
    }

    #if DEBUG
    @objc private func openDesignGallery() {
        NSApp.activate(ignoringOtherApps: true)
        openDesignGalleryAction?(id: "design-gallery")
    }
    #endif

    /// Triggered from Settings → About (no longer a menu item). Internal so the
    /// About view can reach it via `NSApp.delegate as? AppDelegate`.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Whether Sparkle can currently check — lets the About button disable itself.
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    #if DEBUG
    @objc private func runMeetingSelfTest() {
        Task {
            let report = await MeetingSelfTest.run()
            let alert = NSAlert()
            alert.messageText = "Meeting Self-Test"
            alert.informativeText = report
            alert.runModal()
        }
    }

    @objc private func runMemorySelfTest() {
        let report = MemorySelfTest.run()
        let alert = NSAlert()
        alert.messageText = "Memory Self-Test"
        alert.informativeText = report
        alert.runModal()
    }

    @objc private func resetOnboarding() {
        appState.hasCompletedOnboarding = false
        NSApp.activate(ignoringOtherApps: true)
        openOnboardingAction?(id: "onboarding")
    }
    #endif
}
