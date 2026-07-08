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
        guard let window = ScreenContextReader.copyAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        let windowElement = window as! AXUIElement

        let title = (ScreenContextReader.copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        guard !ScreenContextReader.isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }

        var lines: [String] = []
        var budget = 50_000
        let deadline = Date().addingTimeInterval(timeBudget)
        ScreenContextReader.collectText(windowElement, depth: 0, into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

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
