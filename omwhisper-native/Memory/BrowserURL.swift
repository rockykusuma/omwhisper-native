//
//  BrowserURL.swift
//  OmWhisper
//
//  Resolves the URL of the page shown in a browser window, using only the
//  Accessibility API (no AppleScript, so no extra Automation permission).
//  Ported near-verbatim from smriti's BrowserURL.swift (same author, MIT,
//  read-only reference) -- deferred as scope creep for S2 (nothing there
//  called it), genuinely needed now for S1's domain-based exclusion.
//
//  Strategy:
//    1. Find the AXWebArea in the window and read its AXURL -- works for
//       Safari, and for Chromium/Firefox when their AX trees are hydrated.
//    2. Chromium fallback: read the address bar text field and re-add the
//       scheme Chrome strips from display. Real, documented gotcha:
//       "Chromium hides AXURL until a screen reader is active."
//

import ApplicationServices
import Foundation

nonisolated enum BrowserURL {
    static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser", // Arc
        "org.mozilla.firefox",
    ]

    static func isBrowser(_ bundleId: String) -> Bool {
        browserBundleIds.contains(bundleId)
    }

    /// Best-effort URL for a browser window. Returns nil for non-browsers or
    /// when the AX tree doesn't expose one.
    static func url(bundleId: String, window: AXUIElement) -> String? {
        guard isBrowser(bundleId) else { return nil }

        if let url = webAreaURL(window) {
            return url
        }
        if let typed = findAddressBarValue(window, depth: 0) {
            let trimmed = typed.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
            if trimmed.contains("://") { return trimmed }
            return "https://" + trimmed
        }
        return nil
    }

    /// Host with any leading "www." removed; nil when the URL has no host.
    static func domain(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// True when `domain` equals `excluded` or is a subdomain of it
    /// (docs.example.com matches example.com).
    static func domain(_ domain: String, matches excluded: String) -> Bool {
        let d = domain.lowercased()
        let e = excluded.lowercased()
        return d == e || d.hasSuffix("." + e)
    }

    // MARK: - AX tree walks (shallow, breadth-limited)

    /// The first AXWebArea in this window's tree, if any.
    ///
    /// Internal rather than private: WindowSnapshotReader targets its text walk
    /// at this subtree so Memory captures page content instead of the sidebar
    /// and tab strip (see the web-area capture spec). One finder, two callers.
    ///
    /// Not browser-only in practice — Electron apps (Teams, Slack, VS Code,
    /// Claude) expose a web area too, which is why no allowlist is involved.
    static func findWebArea(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if (copyAttribute(element, kAXRoleAttribute) as? String) == "AXWebArea" {
            return element
        }
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        for child in children {
            if let found = findWebArea(child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The AXURL of the window's web area, if it has one.
    private static func webAreaURL(_ window: AXUIElement) -> String? {
        guard let area = findWebArea(window), let url = copyAttribute(area, "AXURL") else { return nil }
        if let cfURL = url as? URL { return cfURL.absoluteString }
        if let s = url as? String, !s.isEmpty { return s }
        return nil
    }

    private static func findAddressBarValue(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 12 else { return nil } // toolbar lives near the top of the tree
        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""
        if role == kAXTextFieldRole {
            let label = [
                copyAttribute(element, kAXTitleAttribute) as? String,
                copyAttribute(element, kAXDescriptionAttribute) as? String,
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            if label.contains("address"),
               let value = copyAttribute(element, kAXValueAttribute) as? String {
                return value
            }
        }
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        for child in children {
            if let found = findAddressBarValue(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}
