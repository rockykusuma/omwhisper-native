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
import os

private nonisolated let callLog = Logger(subsystem: "com.omwhisper.mac", category: "CallDetection")

nonisolated enum CallDetection {
    /// Bundle-ID base -> display name. The process that actually holds the mic
    /// is frequently a helper below one of these, so every lookup goes through
    /// `matchesBundle`, never a dictionary subscript.
    ///
    /// No verification tier any more: an app in this list capturing microphone
    /// input IS the evidence. The old two-tier scheme existed only to decide
    /// whether to consult the window title, and the title heuristic is what
    /// missed a real 30-minute Teams call on 2026-08-03.
    ///
    /// **Entries are VENDOR NAMESPACES, not app bundle IDs**, wherever the
    /// vendor's namespace is unambiguous. This is not tidiness -- it is the
    /// difference between detecting a call and missing it. Enumerating the
    /// helper bundles inside zoom.us.app on 2026-08-04 found that EVERY one of
    /// them (us.zoom.aomhost -- the audio module host -- us.zoom.ZoomPhone,
    /// us.zoom.CptHost and ten more) sits OUTSIDE `us.zoom.xos`, so the app we
    /// trusted most would have failed exactly the way Teams did. `com.hnc`
    /// likewise covers DiscordPTB and DiscordCanary, which are siblings of
    /// com.hnc.Discord rather than children.
    ///
    /// Verified against real bundles on this machine: Teams (modulehost seen
    /// holding the mic during a live call) and Zoom (helper list above).
    /// WhatsApp's ServiceExtension was seen in the same live probe. **The rest
    /// are best-effort and unverified.** That asymmetry is deliberate: a wrong
    /// ID here simply never matches and costs nothing, while a missing one
    /// costs a whole meeting. `noteUnrecognisedMicHolder` below is what turns a
    /// wrong guess into a fixable fact instead of a silent miss.
    static let callerApps: [String: String] = [
        // Verified on this machine.
        "us.zoom": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "net.whatsapp.WhatsApp": "WhatsApp",
        // Namespace covers Discord, DiscordPTB and DiscordCanary.
        "com.hnc": "Discord",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        // Best-effort: not installed here, so these bundle IDs are unverified.
        "Cisco-Systems.Spark": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.skype.skype": "Skype",
        "com.microsoft.SkypeForBusiness": "Skype for Business",
        "com.google.meetings": "Google Meet",
        "com.amazon.Chime": "Amazon Chime",
        "com.logmein.GoToMeeting": "GoToMeeting",
        "com.bluejeansnet.Blue": "BlueJeans",
        "com.ringcentral.glip": "RingCentral",
        "org.jitsi.jitsi-meet": "Jitsi Meet",
        "com.jitsi.jitsi-meet": "Jitsi Meet",
        "org.telegram.desktop": "Telegram",
        "ru.keepcoder.Telegram": "Telegram",
        "org.whispersystems.signal-desktop": "Signal",
        "com.facebook.archon": "Messenger",
    ]

    /// Our own bundle. Prefix-matched, so the Debug build
    /// (com.omwhisper.mac.dev) is covered by the same entry.
    static let ownBundleID = "com.omwhisper.mac"

    static let meetingDomains = [
        "meet.google", "zoom.us", "teams.microsoft", "whereby.com", "web.whatsapp",
    ]

    private static let callLikeWords = ["call", "calling", "ringing", "meeting", "huddle"]

    /// Window titles that are app chrome, never a meeting name. Teams' left
    /// nav is the reason this exists: an ad-hoc 1:1 call on 2026-08-06 was
    /// filed as "Chat", because the nav window's title is LONGER than the call
    /// window's and the old rule picked the longest.
    ///
    /// This is a vendor-shaped string list -- the same class of heuristic that
    /// missed a 30-minute call on 2026-08-03 -- and it will rot when Teams
    /// renames a tab. It is here because without it a generic title wins and
    /// the model is never asked to name the meeting. Its failure mode is
    /// benign: a missed entry falls through to the generated title.
    private static let genericTitles: Set<String> = [
        "chat", "chats", "calls", "activity", "calendar", "home", "files",
        "communities", "teams", "microsoft teams", "meet", "google meet",
        "slack", "zoom", "zoom workplace", "discord", "whatsapp", "messages",
        "facetime", "webex", "inbox", "untitled",
        // Teams window states and its default meeting name, all observed as
        // stored titles across 12 real recordings 11-14 Aug 2026. They arrive
        // as SINGLE segments, so the pipe-splitting rule never engages and they
        // were kept verbatim. Every one of those meetings had a rich summary,
        // so the model names them far better than the label does.
        "meeting join", "meeting compact view", "microsoft teams meeting",
    ]

    /// Is this title app chrome rather than a meeting name?
    ///
    /// Matched EXACTLY (case-insensitive), never by substring: "Chat app
    /// redesign" is a real meeting name. A `contains` test here would be the
    /// same length-unbounded mistake that made `answer()` throw away extracts
    /// beginning "Nothing relevant to the budget, but...".
    static func isGenericTitle(_ title: String, appName: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == appName.lowercased() { return true }
        return genericTitles.contains(normalized)
    }

    /// The part of a window title that could actually be a meeting name.
    ///
    /// Dash separators keep first-segment semantics -- that is the browser tab
    /// convention ("Q3 Planning - Google Meet - Google Chrome").
    ///
    /// **Pipes do not**, because Teams uses BOTH orders and position therefore
    /// tells you nothing. Observed live on 2026-08-11:
    ///
    ///     pre-join window:   "Meeting join | CatchUp With Venkat"   name SECOND
    ///     in-call window:    "CatchUp With Venkat"                  no separator
    ///     older main window: "D-WHAS | Microsoft Teams"             name FIRST
    ///
    /// Taking the first segment stored "Meeting join" as the meeting name for
    /// two real calls. So chrome segments are dropped and the longest survivor
    /// wins, which is right in every observed case and needs no list of Teams'
    /// UI strings -- a list that would have worked for "Meeting join" and
    /// failed for whatever it is renamed to.
    ///
    /// Extracted so `bestWindowTitle` judges the same string the meeting would
    /// actually be named: judging the raw title would let "Chat | Microsoft
    /// Teams" pass, since that whole string is not itself in the chrome list.
    private static func meaningfulSegment(_ windowTitle: String, appName: String) -> String {
        let base = windowTitle
            .components(separatedBy: " – ").first!
            .components(separatedBy: " - ").first!
        let parts = base.components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1 else { return parts.first ?? "" }
        let specific = parts.filter { !isGenericTitle($0, appName: appName) }
        // All chrome: hand back the first so the caller's own rejection fires
        // and the meeting falls through to being named from its summary.
        return specific.max { $0.count < $1.count } ?? parts.first ?? ""
    }

    /// Pure: which of an app's window titles is most likely the CALL window.
    ///
    /// Chrome is discarded FIRST, then a call-like title is preferred among
    /// what survives, then the longest. The old rule was "longest, full stop",
    /// which for a 1:1 Teams call picks the nav window over the call window.
    ///
    /// The filter has to come first, not second: Teams' "Calls" nav tab
    /// contains the word "call", so preferring call-like titles up front let
    /// it bypass the chrome rejection entirely and beat the person's-name
    /// window it exists to lose to.
    ///
    /// Guarantees that whatever this returns also survives
    /// `cleanedMeetingTitle` -- the invariant the title poll relies on to know
    /// when to stop looking.
    static func bestWindowTitle(_ titles: [String], appName: String) -> String? {
        let specific = titles.filter { !isGenericTitle(meaningfulSegment($0, appName: appName), appName: appName) }
        if let callLike = specific.first(where: hasCallLikeTitle) { return callLike }
        return specific.max { $0.count < $1.count }
    }

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

    /// The recorded call's window title, for use as the meeting's display
    /// title. Selection lives in `bestWindowTitle`; this is only the AX
    /// enumeration. nil when AX yields nothing usable.
    static func callWindowTitle(pid: pid_t, appName: String) -> String? {
        let app = AX.appElement(pid: pid)
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
        return bestWindowTitle(titles, appName: appName)
    }

    /// Pure: raw window title → meeting display title. Takes the first
    /// " – "/" - "/" | " segment (apps suffix the product and window names),
    /// nil when nothing usable remains — empty, or just the app's own name.
    ///
    /// " | " is Teams' separator: a real call on 2026-08-03 was titled
    /// "D-WHAS | Microsoft Teams", and without it the whole string became the
    /// meeting name. The cost is a meeting genuinely named "Q3 | Planning"
    /// truncating to "Q3" — the same trade already accepted for " - ".
    static func cleanedMeetingTitle(windowTitle: String, appName: String) -> String? {
        let first = meaningfulSegment(windowTitle, appName: appName)
        guard !isGenericTitle(first, appName: appName) else { return nil }
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
            guard !isOwnProcess(process.bundleID) else { continue }
            guard let base = callAppBundleID(forAudioBundleID: process.bundleID) else {
                noteUnrecognisedMicHolder(process.bundleID)
                continue
            }
            let pid = owningPID(baseBundleID: base) ?? process.pid
            if BrowserURL.isBrowser(base), !hasMeetingPage(pid: pid, bundleID: base) { continue }
            let name = callerApps[base]
                ?? NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? base
            return (name, pid)
        }
        return nil
    }

    /// Bundle IDs already reported this session, so the 2s poll logs each one
    /// once rather than every tick.
    private static let reportedMicHolders = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Names a process that holds the microphone but is not a known call app.
    ///
    /// `callerApps` is a hardcoded list, so an app missing from it is undetected
    /// AND silent -- which is how a 30-minute Teams call went unrecorded. By
    /// the time anyone thinks to run a diagnostic the call is over, so the
    /// evidence has to be captured while the mic is actually held. If a call
    /// app is not being detected, this line names the bundle ID to add.
    ///
    /// Bundle IDs only, never window titles or content. `.public` because a
    /// redacted bundle ID would defeat the entire purpose.
    static func noteUnrecognisedMicHolder(_ bundleID: String) {
        let isNew = reportedMicHolders.withLock { $0.insert(bundleID).inserted }
        guard isNew else { return }
        callLog.notice("mic held by unrecognised process: \(bundleID, privacy: .public) — add to callerApps if this is a call app")
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

    /// Is the app we are recording still capturing microphone input?
    ///
    /// The stop path asks about THIS call rather than re-running activeCall(),
    /// for two reasons. A browser's meeting-URL check reads the FOCUSED window,
    /// so taking notes in another window or tab mid-call would otherwise read
    /// as the call having ended and stop the recording after the end debounce.
    /// And a different call starting elsewhere must not keep this recording
    /// alive.
    ///
    /// Matched by bundle family, not pid: the pid we hold is the owning app's
    /// (Teams, windows) while the capturing process is its helper.
    static func isCallStillActive(pid: pid_t) -> Bool {
        guard let base = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return false }
        return AudioProcesses.capturingInput().contains { matchesBundle($0.bundleID, base: base) }
    }

    /// A browser holding the mic means nothing on its own -- any WebRTC page
    /// does it -- so it counts as a call only when the focused window resolves
    /// to a meeting URL. Silence is the safe direction here: a false positive
    /// prompts during ordinary browsing, a false negative costs one
    /// auto-started recording and the Record button still works.
    static func hasMeetingPage(pid: pid_t, bundleID: String) -> Bool {
        let appElement = AX.appElement(pid: pid)
        guard let window = ScreenContextReader.copyAttribute(appElement, kAXFocusedWindowAttribute)
        else { return false }
        // Not `as?`: the compiler rejects that as dead code ("conditional
        // downcast to CoreFoundation type 'AXUIElement' will always succeed").
        // Same construct and same reason as ScreenContextReader.swift:66.
        let windowElement = window as! AXUIElement
        return isMeetingURL(BrowserURL.url(bundleId: bundleID, window: windowElement))
    }
}
