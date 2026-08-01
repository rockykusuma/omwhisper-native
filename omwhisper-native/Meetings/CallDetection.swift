//
//  CallDetection.swift
//  OmWhisper
//
//  Identifies whether the frontmost/mic-active context is a real call, not just
//  "the mic is on" — ported from smriti's MeetingWatcher.callerApps/looksInCall
//  (github.com/rockykusuma/smriti, same author, MIT). Apps that also run
//  persistently outside calls (Slack, Discord, Teams, WhatsApp, Webex) need
//  extra verification (frontmost, or a call-like window title); apps that are
//  essentially only mic-active during a real call (Zoom, FaceTime) don't.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum CallDetection {
    struct CallerApp {
        let name: String
        let needsVerification: Bool
    }

    static let callerApps: [String: CallerApp] = [
        "us.zoom.xos": CallerApp(name: "Zoom", needsVerification: false),
        "com.apple.FaceTime": CallerApp(name: "FaceTime", needsVerification: false),
        "com.microsoft.teams2": CallerApp(name: "Teams", needsVerification: true),
        "com.microsoft.teams": CallerApp(name: "Teams", needsVerification: true),
        "net.whatsapp.WhatsApp": CallerApp(name: "WhatsApp", needsVerification: true),
        "com.tinyspeck.slackmacgap": CallerApp(name: "Slack", needsVerification: true),
        "com.hnc.Discord": CallerApp(name: "Discord", needsVerification: true),
        "Cisco-Systems.Spark": CallerApp(name: "Webex", needsVerification: true),
    ]

    static let meetingDomains = [
        "meet.google", "zoom.us", "teams.microsoft", "whereby.com", "web.whatsapp",
    ]

    private static let callLikeWords = ["call", "calling", "ringing", "meeting", "huddle"]

    /// nil = not a recognized call. For apps needing verification, either
    /// `isFrontmost` or `hasCallLikeWindowTitle` must also be true.
    static func recognizedApp(bundleID: String, isFrontmost: Bool, hasCallLikeWindowTitle: Bool) -> String? {
        guard let app = callerApps[bundleID] else { return nil }
        guard app.needsVerification else { return app.name }
        return (isFrontmost || hasCallLikeWindowTitle) ? app.name : nil
    }

    static func isMeetingURL(_ url: String?) -> Bool {
        guard let url else { return false }
        return meetingDomains.contains { url.localizedCaseInsensitiveContains($0) }
    }

    static func hasCallLikeTitle(_ title: String) -> Bool {
        guard !title.isEmpty else { return false }
        return callLikeWords.contains { title.localizedCaseInsensitiveContains($0) }
    }

    /// True if the app with this pid currently has any window whose title looks
    /// like a call (reuses hasCallLikeTitle). Frontmost- and display-independent:
    /// AXWindows lists every window on every monitor regardless of focus — the
    /// key property for multi-monitor call detection. Called on the main actor
    /// by MeetingWatcher.
    static func hasActiveCallWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for window in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, hasCallLikeTitle(title) {
                return true
            }
        }
        return false
    }

    /// The recorded call's window title, for use as the meeting's display title:
    /// prefer a call-like-titled window, else the longest non-empty title
    /// (browser tabs put the meeting name in long titles). Same AX enumeration
    /// as hasActiveCallWindow; nil when AX yields nothing.
    static func callWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        var titles: [String] = []
        for window in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String,
               !title.trimmingCharacters(in: .whitespaces).isEmpty {
                titles.append(title)
            }
        }
        return titles.first(where: hasCallLikeTitle) ?? titles.max { $0.count < $1.count }
    }

    /// Pure: raw window title → meeting display title. Takes the first
    /// " – "/" - " segment (browsers suffix the product and browser names),
    /// nil when nothing usable remains — empty, or just the app's own name.
    static func cleanedMeetingTitle(windowTitle: String, appName: String) -> String? {
        let first = windowTitle
            .components(separatedBy: " – ").first!
            .components(separatedBy: " - ").first!
            .trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty,
              first.localizedCaseInsensitiveCompare(appName) != .orderedSame else { return nil }
        return first
    }

    /// The first running recognized call app that appears to be in a call, as
    /// (name, pid). Non-verification apps (Zoom/FaceTime) count on being run
    /// while the mic is active (the watcher only calls this when the mic is on);
    /// verification apps (Teams/Slack/…) additionally require a call-like window.
    static func activeCall() -> (name: String, pid: pid_t)? {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, let caller = callerApps[bundleID] else { continue }
            let pid = app.processIdentifier
            if !caller.needsVerification { return (caller.name, pid) }
            if hasActiveCallWindow(pid: pid) { return (caller.name, pid) }
        }
        return nil
    }
}
