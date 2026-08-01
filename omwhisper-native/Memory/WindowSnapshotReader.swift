//
//  WindowSnapshotReader.swift
//  OmWhisper
//
//  Frontmost-window capture for S1's background memory daemon -- returns
//  richer metadata (bundleID, appName, windowTitle, url) than S2's
//  ScreenContextReader.captureFrontmostWindowText(), which only needs the
//  text itself. Reuses ScreenContextReader's proven AX walk (collectText)
//  and exclusion check (isExcluded) rather than forking them; only the
//  thin wrapper around the walk is new here.
//
//  nonisolated: same rationale as ScreenContextReader -- AXUIElement calls
//  are cross-process IPC with no MainActor affinity.
//

import AppKit
import ApplicationServices
import Foundation
import os

private nonisolated let snapshotLog = Logger(subsystem: "com.omwhisper.mac", category: "WindowSnapshot")

nonisolated enum WindowSnapshotReader {
    struct Snapshot {
        let bundleID: String
        let appName: String
        let windowTitle: String
        let content: String
        let url: String?
    }

    /// nil when there's nothing meaningful, the app/window is excluded, or
    /// the walk hits its deadline before finding anything. Never throws.
    static func captureFrontmost(timeBudget: TimeInterval = 2.0) -> Snapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium apps (Teams, Slack, Discord, VS Code, …) don't expose
        // their AX tree until an assistive tech asks. Set the Chromium hydration
        // flag so their window/text become readable — idempotent, native apps
        // ignore it. The tree may still be empty on the very first tick after
        // switching (hydration lag), but the flag persists on the app, so the next
        // 5s poll captures. Mirrors ReplyContext's Electron handling.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = ScreenContextReader.copyAttribute(appElement, kAXFocusedWindowAttribute) else {
            snapshotLog.debug("no focused window: \(app.localizedName ?? bundleID, privacy: .public)")
            return nil
        }
        return capture(
            window: window as! AXUIElement,
            appElement: appElement,
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            deadline: Date().addingTimeInterval(timeBudget)
        )
    }

    /// Reads one already-resolved window. Takes a `deadline` rather than a
    /// budget so a single capture tick can share one allowance across several
    /// windows without their walks compounding past the poll interval.
    static func capture(
        window windowElement: AXUIElement,
        appElement: AXUIElement,
        bundleID: String,
        appName: String,
        deadline: Date
    ) -> Snapshot? {
        let title = (ScreenContextReader.copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        guard !ScreenContextReader.isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }

        // Walk the page, not the window. Measured on the real store, 58% of a
        // median Arc snapshot was sidebar and pinned-tab chrome -- indexing that
        // buried the actual content and produced search hits like
        // "Footer (c) 2026 GitHub, Inc.". Any app exposing a web area benefits,
        // including Electron ones; native apps find none and behave as before.
        let webArea = BrowserURL.findWebArea(windowElement)
        var lines: [String] = []
        var budget = 50_000
        ScreenContextReader.collectText(webArea ?? windowElement, depth: 0,
                                        into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // A web area that yielded nothing means a page mid-load, a canvas app or
        // a PDF viewer. Skip the tick rather than falling back to the window
        // walk: a snapshot that is 100% chrome is worse than no snapshot, and
        // the 5s poll retries almost immediately.
        if webArea != nil, content.isEmpty {
            snapshotLog.debug("web area empty, skipping tick: \(appName, privacy: .public)")
            return nil
        }
        guard !content.isEmpty else {
            // Escalate: the window is exposed (we read its title) but its WebView
            // content isn't — some apps (new Teams) only surface web text under
            // the full "assistive tech active" flag, not the lighter Chromium one.
            // Set it so the NEXT 5s poll reads them. Scoped to apps that already
            // came back empty, so apps that work with the light flag (Arc / Chrome
            // / Claude / …) never get this heavier, more side-effectful flag.
            // Idempotent; a genuine wall just stays empty.
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            snapshotLog.debug("empty content, escalating a11y: \(appName, privacy: .public)")
            return nil
        }

        let url = BrowserURL.url(bundleId: bundleID, window: windowElement)
        return Snapshot(
            bundleID: bundleID,
            appName: appName,
            windowTitle: title,
            content: content,
            url: url
        )
    }

    // MARK: - Multi-display capture

    /// The focused window, plus the frontmost window on each OTHER display.
    ///
    /// `totalBudget` is shared across the whole tick, so attaching more monitors
    /// cannot push a capture past MemoryCapture's 5s poll -- windows that don't
    /// fit are simply picked up next tick.
    static func captureVisible(
        totalBudget: TimeInterval = 3.0,
        focusedBudget: TimeInterval = 2.0,
        perWindowBudget: TimeInterval = 1.0
    ) -> [Snapshot] {
        let tickDeadline = Date().addingTimeInterval(totalBudget)
        var snapshots: [Snapshot] = []
        if let focused = captureFrontmost(timeBudget: min(focusedBudget, totalBudget)) {
            snapshots.append(focused)
        }

        let displays = VisibleWindows.activeDisplays()
        // One display means the focused window already covered everything
        // visible -- skip enumeration entirely so the common case pays nothing.
        guard displays.count > 1 else { return snapshots }

        let windows = VisibleWindows.onScreen()
        // The focused window is the frontmost normal window of the frontmost app.
        // Derived from the CG list rather than AX geometry so the display lookup
        // uses one coordinate space throughout.
        let focusedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedDisplayID = windows
            .first { $0.pid == focusedPID && $0.layer == 0 }
            .flatMap { VisibleWindows.display(containing: $0.bounds, in: displays) }

        let selected = VisibleWindows.select(
            windows: windows,
            displays: displays,
            focusedDisplayID: focusedDisplayID,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )

        for (index, descriptor) in selected.enumerated() {
            guard Date() < tickDeadline else {
                snapshotLog.debug("tick budget spent, \(selected.count - index) window(s) deferred")
                break
            }
            let deadline = min(Date().addingTimeInterval(perWindowBudget), tickDeadline)
            if let snapshot = capture(descriptor: descriptor, deadline: deadline) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    /// AX-reads a specific CG window. AX exposes no window number, so the link
    /// is geometric: find the app's AX window whose frame matches the CG bounds.
    private static func capture(descriptor: VisibleWindows.Descriptor, deadline: Date) -> Snapshot? {
        guard let app = NSRunningApplication(processIdentifier: descriptor.pid),
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(descriptor.pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windows = ScreenContextReader.copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement],
              let windowElement = windows.first(where: { frameMatches(descriptor.bounds, $0) })
        else {
            snapshotLog.debug("no AX window matching bounds: \(app.localizedName ?? bundleID, privacy: .public)")
            return nil
        }

        return capture(
            window: windowElement,
            appElement: appElement,
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            deadline: deadline
        )
    }

    /// AX window position/size are in the same top-left-origin screen space as
    /// CG window bounds. 2pt tolerance absorbs rounding, not a different window.
    private static func frameMatches(_ bounds: CGRect, _ window: AXUIElement) -> Bool {
        guard let origin = axValue(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = axValue(window, kAXSizeAttribute, .cgSize, CGSize.zero)
        else { return false }

        return abs(origin.x - bounds.origin.x) < 2 && abs(origin.y - bounds.origin.y) < 2
            && abs(size.width - bounds.width) < 2 && abs(size.height - bounds.height) < 2
    }

    /// Unwraps an AXValue-typed attribute. The CFGetTypeID check is not
    /// ceremony: this runs every 5s against arbitrary third-party apps, and a
    /// force-cast of an attribute that came back as something else would trap
    /// the whole daemon.
    private static func axValue<T>(
        _ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ empty: T
    ) -> T? {
        guard let raw = ScreenContextReader.copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var out = empty
        guard AXValueGetValue(raw as! AXValue, type, &out) else { return nil }
        return out
    }
}
