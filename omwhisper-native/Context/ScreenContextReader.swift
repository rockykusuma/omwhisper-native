//
//  ScreenContextReader.swift
//  OmWhisper
//
//  On-demand read of the frontmost window's visible text via the macOS
//  Accessibility API, for S2 (context-aware dictation). Ported from
//  github.com/rockykusuma/smriti (same author, MIT) — Sources/SmritiKit/
//  AXReader.swift — with a Swift 6 concurrency pass and a tighter time budget
//  (0.6s vs Smriti's 2.0s default; this sits on the critical path to
//  first-partial latency, unlike Smriti's background daemon use). Exclusion
//  defaults (excludedBundleIDs/excludedTitleSubstrings) match Smriti's
//  Config.defaults verbatim.
//
//  nonisolated: AXUIElement calls are cross-process IPC with no MainActor
//  affinity, same rationale as AudioCapture — must run off the main thread
//  without an actor hop (see AppState concurrency note in CLAUDE.md).
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum ScreenContextReader {
    static let excludedBundleIDs: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7",
    ]
    static let excludedTitleSubstrings = ["Private Browsing", "Incognito"]

    static func isExcluded(bundleID: String, windowTitle: String) -> Bool {
        if excludedBundleIDs.contains(bundleID) { return true }
        if isDotEnvTitle(windowTitle) { return true }
        return excludedTitleSubstrings.contains { windowTitle.localizedCaseInsensitiveContains($0) }
    }

    /// True when the title names a dotenv file -- `.env`, `.env.local`,
    /// `.env.production` -- however the editor decorates it (VS Code appends
    /// the project, vim appends the cwd, Finder-opened files are bare).
    ///
    /// Matched at a path/word boundary rather than as a plain substring, so
    /// `.environment-setup.md` is not swept up. Deliberately hardcoded beside
    /// the password managers rather than exposed as a setting: a file whose
    /// entire purpose is holding secrets should not be capturable by
    /// forgetting to configure something.
    static func isDotEnvTitle(_ windowTitle: String) -> Bool {
        windowTitle
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "\\" })
            .contains {
                let token = $0.lowercased()
                return token == ".env" || token.hasPrefix(".env.")
            }
    }

    /// The frontmost window's identity and readable content.
    nonisolated struct ConversationContext {
        let appName: String
        let windowTitle: String
        /// nil when the window exposed no text at all.
        let text: String?
    }

    /// What the user is looking at, for Reply Assist: the page's conversation
    /// rather than the window's furniture.
    ///
    /// Memory hit this first -- its snapshots were "largely sidebar and
    /// tab-strip text" until WindowSnapshotReader started targeting the web
    /// area. Reply Assist reads the same kind of window for the same reason and
    /// never got that fix, so a Slack or Gmail reply was drafted from up to
    /// 2,000 characters of channel list and navigation.
    ///
    /// Differs from Memory in ONE deliberate way: when the web area yields
    /// nothing, this FALLS BACK to the whole-window walk. Memory skips the tick
    /// instead, because "a snapshot that is 100% chrome is worse than no
    /// snapshot, and the 5s poll retries almost immediately" -- neither half of
    /// that holds here. There is no retry, and the user is waiting on a draft.
    ///
    /// nil when there is no frontmost app or focused window, or the app/window
    /// is excluded -- in which case no app name or title is returned either,
    /// since a password manager's window title is not ours to put in a prompt.
    static func captureConversationText(timeBudget: TimeInterval = 0.6) -> ConversationContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        // Not `as?`: the compiler rejects that as dead code ("conditional downcast
        // to CoreFoundation type 'AXUIElement' will always succeed") — CFTypeRef
        // bridging isn't a dynamic class-hierarchy check the way `as!` normally
        // implies, so this can't trap the way a force-cast on a class type could.
        let windowElement = window as! AXUIElement

        let title = (copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        guard !isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }

        let deadline = Date().addingTimeInterval(timeBudget)
        var lines: [String] = []
        var budget = 50_000
        let webArea = BrowserURL.findWebArea(windowElement)
        collectText(webArea ?? windowElement, depth: 0, into: &lines,
                    budget: &budget, deadline: deadline)

        var content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // A web area that yielded nothing means a page mid-load, a canvas app or
        // a PDF viewer. Unlike Memory, fall back rather than give up: the user
        // asked for a draft and is waiting for one.
        if content.isEmpty, webArea != nil {
            lines = []
            budget = 50_000
            collectText(windowElement, depth: 0, into: &lines, budget: &budget, deadline: deadline)
            content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ConversationContext(appName: app.localizedName ?? bundleID,
                                   windowTitle: title,
                                   text: content.isEmpty ? nil : content)
    }

    /// nil when there's nothing meaningful, the app/window is excluded, or the
    /// walk hits its deadline before finding anything. Never throws.
    ///
    /// Used by S2's context-aware dictation. Deliberately NOT switched to the
    /// web-area targeting above: engine biasing is measured inert on Apple
    /// Speech and both Parakeet variants, so changing it buys nothing and risks
    /// a second feature.
    static func captureFrontmostWindowText(timeBudget: TimeInterval = 0.6) -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyAttribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        // Not `as?`: the compiler rejects that as dead code ("conditional downcast
        // to CoreFoundation type 'AXUIElement' will always succeed") — CFTypeRef
        // bridging isn't a dynamic class-hierarchy check the way `as!` normally
        // implies, so this can't trap the way a force-cast on a class type could.
        let windowElement = window as! AXUIElement

        let title = (copyAttribute(windowElement, kAXTitleAttribute) as? String) ?? ""
        guard !isExcluded(bundleID: bundleID, windowTitle: title) else { return nil }

        var lines: [String] = []
        var budget = 50_000
        let deadline = Date().addingTimeInterval(timeBudget)
        collectText(windowElement, depth: 0, into: &lines, budget: &budget, deadline: deadline)

        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    // MARK: - Tree walking (ported near-verbatim from AXReader.collectText)

    static let textBearingRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole,
        "AXLink", "AXHeading", "AXCell", "AXMenuItem", "AXButton",
    ]

    static func collectText(
        _ element: AXUIElement,
        depth: Int,
        into lines: inout [String],
        budget: inout Int,
        deadline: Date
    ) {
        guard depth < 40, budget > 0, Date() < deadline else { return }

        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""

        if textBearingRoles.contains(role) {
            if let value = copyAttribute(element, kAXValueAttribute) as? String, !value.isEmpty {
                append(value, to: &lines, budget: &budget)
            } else if let title = copyAttribute(element, kAXTitleAttribute) as? String,
                      !title.isEmpty, role != kAXButtonRole {
                append(title, to: &lines, budget: &budget)
            }
        }

        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            guard budget > 0, Date() < deadline else { return }
            collectText(child, depth: depth + 1, into: &lines, budget: &budget, deadline: deadline)
        }
    }

    private static func append(_ text: String, to lines: inout [String], budget: inout Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clipped = String(trimmed.prefix(budget))
        lines.append(clipped)
        budget -= clipped.count
    }

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }
}
