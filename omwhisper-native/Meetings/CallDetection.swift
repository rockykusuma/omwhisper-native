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
}
