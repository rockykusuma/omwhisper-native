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
        return excludedTitleSubstrings.contains { windowTitle.localizedCaseInsensitiveContains($0) }
    }

    /// nil when there's nothing meaningful, the app/window is excluded, or the
    /// walk hits its deadline before finding anything. Never throws.
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
