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
        let windowElement = window as! AXUIElement

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
        let deadline = Date().addingTimeInterval(timeBudget)
        ScreenContextReader.collectText(webArea ?? windowElement, depth: 0,
                                        into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // A web area that yielded nothing means a page mid-load, a canvas app or
        // a PDF viewer. Skip the tick rather than falling back to the window
        // walk: a snapshot that is 100% chrome is worse than no snapshot, and
        // the 5s poll retries almost immediately.
        if webArea != nil, content.isEmpty {
            snapshotLog.debug("web area empty, skipping tick: \(app.localizedName ?? bundleID, privacy: .public)")
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
            snapshotLog.debug("empty content, escalating a11y: \(app.localizedName ?? bundleID, privacy: .public)")
            return nil
        }

        let url = BrowserURL.url(bundleId: bundleID, window: windowElement)
        return Snapshot(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            windowTitle: title,
            content: content,
            url: url
        )
    }
}
