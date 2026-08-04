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
    /// Base bundle ID -> display name. The process that actually holds the mic
    /// is frequently a helper below one of these, so every lookup goes through
    /// `matchesBundle`, never a dictionary subscript.
    ///
    /// No verification tier any more: an app in this list capturing microphone
    /// input IS the evidence. The old two-tier scheme existed only to decide
    /// whether to consult the window title, and the title heuristic is what
    /// missed a real 30-minute Teams call on 2026-08-03.
    static let callerApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.apple.FaceTime": "FaceTime",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "Cisco-Systems.Spark": "Webex",
    ]

    /// Our own bundle. Prefix-matched, so the Debug build
    /// (com.omwhisper.mac.dev) is covered by the same entry.
    static let ownBundleID = "com.omwhisper.mac"

    static let meetingDomains = [
        "meet.google", "zoom.us", "teams.microsoft", "whereby.com", "web.whatsapp",
    ]

    private static let callLikeWords = ["call", "calling", "ringing", "meeting", "huddle"]

    /// Exact match, or a dotted child (`base.helper`). The dot is load-bearing:
    /// a bare `hasPrefix` would make com.microsoft.teams2 match the
    /// com.microsoft.teams entry, and in general would match any app whose ID
    /// merely starts with another's.
    static func matchesBundle(_ bundleID: String, base: String) -> Bool {
        bundleID == base || bundleID.hasPrefix(base + ".")
    }

    /// The BASE bundle ID of the call app this audio process belongs to, or nil
    /// if it is not one we recognise. Browsers are admitted here and gated on
    /// the page URL by `activeCall` -- any WebRTC site opens the mic.
    static func callAppBundleID(forAudioBundleID bundleID: String) -> String? {
        if let base = callerApps.keys.first(where: { matchesBundle(bundleID, base: $0) }) {
            return base
        }
        return BrowserURL.browserBundleIds.first { matchesBundle(bundleID, base: $0) }
    }

    /// True for OmWhisper's own audio process. The recorder holds the mic for a
    /// whole meeting and dictation holds it too, so without this the app
    /// detects itself -- the live probe showed com.omwhisper.mac.dev
    /// input=YES beside Teams.
    static func isOwnProcess(_ bundleID: String) -> Bool {
        matchesBundle(bundleID, base: ownBundleID)
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

    /// The call currently capturing microphone input, as (display name, owning
    /// app pid). Nil when nothing recognised has the mic open.
    ///
    /// Replaces an AX window-title walk: on 2026-08-03 a real Teams call ran
    /// for over half an hour titled "D-WHAS | Microsoft Teams", which contains
    /// none of the call words, so detection returned nil on every poll.
    static func activeCall() -> (name: String, pid: pid_t)? {
        for process in AudioProcesses.capturingInput() {
            guard !isOwnProcess(process.bundleID),
                  let base = callAppBundleID(forAudioBundleID: process.bundleID) else { continue }
            let pid = owningPID(baseBundleID: base) ?? process.pid
            let name = callerApps[base]
                ?? NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? base
            return (name, pid)
        }
        return nil
    }

    /// The pid of the app that OWNS this bundle ID, not the helper that happens
    /// to hold the mic. Teams captured on com.microsoft.teams2.modulehost
    /// (pid 2500) while its windows lived on com.microsoft.teams2 (pid 2221) --
    /// without this, callWindowTitle finds no windows and every auto-detected
    /// meeting falls back to being titled by app name.
    static func owningPID(baseBundleID: String) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == baseBundleID }?
            .processIdentifier
    }
}
