import Testing
@testable import OmWhisper

struct CallDetectionTests {
    @Test("the helper process that actually holds the mic matches its parent app")
    func helperBundleIDsMatchTheirApp() {
        // Observed live 2026-08-03 during a real Teams call:
        // com.microsoft.teams2.modulehost held the mic while
        // com.microsoft.teams2 held the windows. An exact-match implementation
        // misses Teams -- which is the original bug wearing a new costume.
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.microsoft.teams2.modulehost")
                == "com.microsoft.teams2")
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.google.Chrome.helper")
                == "com.google.Chrome")
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.microsoft.teams2")
                == "com.microsoft.teams2")
    }

    @Test("Zoom's helper processes all match, none of which are under us.zoom.xos")
    func zoomHelpersMatch() {
        // Enumerating the helper bundles inside zoom.us.app on 2026-08-04 found
        // that EVERY nested .app/.xpc sits outside "us.zoom.xos" -- including
        // aomhost, the audio module host most likely to hold the mic. Keying
        // Zoom on us.zoom.xos would have missed Zoom calls exactly the way the
        // title heuristic missed Teams, in the entry the old code trusted most.
        for helper in ["us.zoom.aomhost", "us.zoom.ZoomPhone", "us.zoom.CptHost",
                       "us.zoom.airhost", "us.zoom.zCCIMeetingHost", "us.zoom.xos"] {
            #expect(CallDetection.callAppBundleID(forAudioBundleID: helper) == "us.zoom",
                    "\(helper) should resolve to Zoom")
        }
    }

    @Test("Discord's PTB and Canary builds are siblings, not children")
    func discordVariantsMatch() {
        // com.hnc.DiscordPTB is NOT under "com.hnc.Discord." -- a base of
        // com.hnc.Discord silently misses both pre-release builds.
        for variant in ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"] {
            #expect(CallDetection.callAppBundleID(forAudioBundleID: variant) == "com.hnc",
                    "\(variant) should resolve to Discord")
        }
    }

    @Test("every caller entry resolves to itself")
    func everyEntryMatchesItsOwnBase() {
        // Catches a typo'd or duplicated key that can never match anything.
        for base in CallDetection.callerApps.keys {
            #expect(CallDetection.callAppBundleID(forAudioBundleID: base) == base,
                    "\(base) does not resolve to itself")
            #expect(CallDetection.isOwnProcess(base) == false,
                    "\(base) collides with our own bundle")
        }
    }

    @Test("a bundle ID that merely starts with a known one does not match")
    func siblingBundleIDsDoNotMatch() {
        // com.microsoft.teams2 must not match the com.microsoft.teams entry:
        // matching requires a dot boundary, not a bare string prefix.
        #expect(CallDetection.matchesBundle("com.microsoft.teams2", base: "com.microsoft.teams") == false)
        #expect(CallDetection.matchesBundle("com.microsoft.teams2.modulehost", base: "com.microsoft.teams") == false)
        #expect(CallDetection.matchesBundle("com.microsoft.teams.helper", base: "com.microsoft.teams"))
        #expect(CallDetection.matchesBundle("com.microsoft.teams", base: "com.microsoft.teams"))
    }

    @Test("our own audio process is never a call")
    func ownProcessIsNotACall() {
        // The live probe showed com.omwhisper.mac.dev input=YES beside Teams:
        // the recorder holds the mic for the whole meeting and dictation holds
        // it too, so without this the app detects itself as a call.
        #expect(CallDetection.isOwnProcess("com.omwhisper.mac"))
        #expect(CallDetection.isOwnProcess("com.omwhisper.mac.dev"))
        #expect(CallDetection.isOwnProcess("com.microsoft.teams2") == false)
    }

    @Test("apps that merely use the mic are not calls")
    func unknownBundleIDIsNotACall() {
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.apple.Music") == nil)
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.spotify.client") == nil)
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.apple.VoiceMemos") == nil)
    }

    @Test("browsers are matched by bundle, then gated on the page")
    func browsersAreMatchedByBundle() {
        // Bundle matching admits the browser; the URL check is what decides
        // whether it is actually a call.
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "company.thebrowser.Browser")
                == "company.thebrowser.Browser")
        #expect(CallDetection.callAppBundleID(forAudioBundleID: "com.apple.Safari") == "com.apple.Safari")
    }

    @Test func meetingURLsAreRecognized() {
        #expect(CallDetection.isMeetingURL("https://meet.google.com/abc-defg-hij"))
        #expect(CallDetection.isMeetingURL("https://zoom.us/j/1234567890"))
        #expect(CallDetection.isMeetingURL("https://teams.microsoft.com/l/meetup-join/xyz"))
    }

    @Test("an ordinary browser page is not a meeting")
    func ordinaryPagesAreNotMeetings() {
        // The control for browser detection. Any WebRTC page opens the mic, so
        // "a browser is capturing input" cannot mean "a call" on its own --
        // without this the app would prompt during a YouTube video.
        #expect(!CallDetection.isMeetingURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(!CallDetection.isMeetingURL("https://github.com/rockykusuma/omwhisper-native"))
        #expect(!CallDetection.isMeetingURL(nil))
        #expect(CallDetection.isMeetingURL("https://meet.google.com/abc-defg-hij"))
        #expect(CallDetection.isMeetingURL("https://teams.microsoft.com/l/meetup-join/xyz"))
    }

    @Test func nonMeetingURLsAreNotRecognized() {
        #expect(!CallDetection.isMeetingURL("https://github.com/rockykusuma/omwhisper-native"))
        #expect(!CallDetection.isMeetingURL(nil))
    }

    @Test func callLikeTitlesAreRecognized() {
        #expect(CallDetection.hasCallLikeTitle("Zoom Meeting"))
        #expect(CallDetection.hasCallLikeTitle("Calling John Appleseed"))
        #expect(CallDetection.hasCallLikeTitle("Huddle in #general"))
    }

    @Test func ordinaryTitlesAreNotCallLike() {
        #expect(!CallDetection.hasCallLikeTitle("Inbox — Slack"))
        #expect(!CallDetection.hasCallLikeTitle(""))
    }

    @Test func cleanedTitleTakesFirstSegmentOfBrowserTitle() {
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Q3 Planning - Google Meet - Google Chrome", appName: "Chrome") == "Q3 Planning")
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Weekly Sync – Zoom", appName: "Zoom") == "Weekly Sync")
    }

    @Test func cleanedTitleRejectsUselessTitles() {
        #expect(CallDetection.cleanedMeetingTitle(windowTitle: "Zoom", appName: "Zoom") == nil)
        #expect(CallDetection.cleanedMeetingTitle(windowTitle: "  ", appName: "Teams") == nil)
        #expect(CallDetection.cleanedMeetingTitle(windowTitle: "zoom - Meeting", appName: "Zoom") == nil)
    }

    @Test("Teams' pipe separator is stripped, using the real observed title")
    func cleanedTitleHandlesTeamsPipe() {
        // The actual title Memory captured during the 2026-08-03 call. Without
        // the " | " split the whole string becomes the meeting name.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "D-WHAS | Microsoft Teams", appName: "Teams") == "D-WHAS")
        // Changed 2026-08-06: "Microsoft Teams" is app chrome, not a meeting
        // name. It used to be kept, which filed calls under the product name.
        // Falls back to appName for display.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Microsoft Teams", appName: "Teams") == nil)
    }

    @Test func cleanedTitleKeepsPlainTitles() {
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Design review with hardware team", appName: "Teams")
            == "Design review with hardware team")
    }

    @Test("app chrome is rejected, real names are kept")
    func genericTitlesAreRejected() {
        #expect(CallDetection.isGenericTitle("Chat", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("chat", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("Activity", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("Microsoft Teams", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("Teams", appName: "Teams"))
        #expect(CallDetection.isGenericTitle("   ", appName: "Teams"))
        // Matched exactly, never by substring: these are real meeting names.
        #expect(!CallDetection.isGenericTitle("Chat app redesign", appName: "Teams"))
        #expect(!CallDetection.isGenericTitle("Calendar migration", appName: "Teams"))
        #expect(!CallDetection.isGenericTitle("D-WHAS", appName: "Teams"))
    }

    @Test("the call window wins over the longer nav window")
    func callWindowBeatsLongerNavWindow() {
        // The actual shape of the 2026-08-06 miss: the nav window's title is
        // LONGER than the call window's, so the old `titles.max(by: count)`
        // rule picked it. This test fails if that rule is restored.
        let titles = ["Chat | Microsoft Teams", "Radha Krishnan"]
        #expect(CallDetection.bestWindowTitle(titles, appName: "Teams") == "Radha Krishnan")
    }

    @Test("a call-like title still wins outright")
    func callLikeTitleWinsFirst() {
        // The first string must contain no call word at all -- an earlier
        // draft used "...not a call at all", which hasCallLikeTitle matched on
        // the word "call" and returned first. The fixture was wrong, not the
        // rule.
        let titles = ["Some very long window title about nothing in particular",
                      "Meeting with the hardware team"]
        #expect(CallDetection.bestWindowTitle(titles, appName: "Teams")
                == "Meeting with the hardware team")
    }

    @Test("longest still wins among specific titles")
    func longestWinsAmongSpecificTitles() {
        let titles = ["Q3", "Q3 Planning and budget review"]
        #expect(CallDetection.bestWindowTitle(titles, appName: "Teams")
                == "Q3 Planning and budget review")
    }

    @Test("all-chrome yields nothing rather than a bad title")
    func allChromeYieldsNil() {
        #expect(CallDetection.bestWindowTitle(["Chat | Microsoft Teams", "Activity"],
                                              appName: "Teams") == nil)
        #expect(CallDetection.bestWindowTitle([], appName: "Teams") == nil)
    }

    @Test("a call-like CHROME title does not beat the real call window")
    func callLikeChromeDoesNotWin() {
        // Teams' "Calls" nav tab contains "call", so it passed the call-like
        // branch and bypassed the chrome filter entirely -- selecting the nav
        // window over the person's-name window it was meant to lose to.
        #expect(CallDetection.bestWindowTitle(["Calls | Microsoft Teams", "Uday Venkat Madala"],
                                              appName: "Teams") == "Uday Venkat Madala")
        #expect(CallDetection.bestWindowTitle(["Calls | Microsoft Teams"], appName: "Teams") == nil)
    }

    @Test("a title that survives selection also survives cleaning")
    func selectedTitlesAreAlwaysCleanable() {
        // The invariant the title poll depends on: it stops the moment
        // callWindowTitle returns non-nil, so a title that passes selection
        // and is then rejected by cleaning would end the search having gained
        // nothing -- and the meeting would keep the app's name.
        let cases = [
            ["Calls | Microsoft Teams", "Uday Venkat Madala"],
            ["Calls | Microsoft Teams"],
            ["Chat | Microsoft Teams", "Activity"],
            ["Zoom Meeting", "Zoom"],
            ["Calendar | Microsoft Teams", "Q3 Planning"],
        ]
        for titles in cases {
            guard let picked = CallDetection.bestWindowTitle(titles, appName: "Teams") else { continue }
            #expect(CallDetection.cleanedMeetingTitle(windowTitle: picked, appName: "Teams") != nil,
                    "\(picked) was selected but cleans to nil")
        }
    }

    @Test("a generic title never becomes the meeting name")
    func cleanedTitleRejectsGenericSegments() {
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Chat | Microsoft Teams", appName: "Teams") == nil)
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Calls | Microsoft Teams", appName: "Teams") == nil)
    }

    @Test("Teams puts the meeting name in the SECOND segment before you join")
    func pipeSegmentOrderVaries() {
        // Observed live 2026-08-11 on a scheduled call. Teams uses BOTH orders,
        // so segment POSITION tells you nothing:
        //   pre-join window:  "Meeting join | CatchUp With Venkat"
        //   in-call window:   "CatchUp With Venkat"
        //   older main window: "D-WHAS | Microsoft Teams"
        // Taking the first segment stored "Meeting join" as the meeting name.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Meeting join | CatchUp With Venkat", appName: "Teams")
            == "CatchUp With Venkat")
        // The original case must not regress: here the name IS first and the
        // app name is second.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "D-WHAS | Microsoft Teams", appName: "Teams") == "D-WHAS")
    }

    @Test("with three segments the app name loses and the longest real one wins")
    func threeSegmentsPickTheName() {
        // A real row from the meetings store, previously filed under the UI
        // label rather than the people in the call.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Meeting compact view | Akhilesh Deepak Jichkar, Shalu Pradhan | Microsoft Teams",
            appName: "Teams") == "Akhilesh Deepak Jichkar, Shalu Pradhan")
    }

    @Test("an all-chrome pipe title still yields nothing")
    func allChromeSegmentsStillRejected() {
        // The half that keeps the model fallback reachable: if every segment is
        // chrome there is no name here, and inventing one from the longest
        // piece of furniture would be worse than asking the summarizer.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Chat | Microsoft Teams", appName: "Teams") == nil)
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Calls | Microsoft Teams", appName: "Teams") == nil)
    }

    @Test("dash separators keep first-segment semantics")
    func dashesAreUnchanged() {
        // Browser tabs are "Page - Site - Browser", so first-segment is right
        // there and must not be swept up in the pipe change.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Q3 Planning - Google Meet - Google Chrome", appName: "Chrome")
            == "Q3 Planning")
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Weekly Sync – Zoom", appName: "Zoom") == "Weekly Sync")
    }

    @Test("Teams' own UI labels and default meeting name are not meeting names")
    func teamsUiLabelsRejected() {
        // Observed across 12 real recordings, 11-14 Aug 2026. These arrive as
        // SINGLE-segment titles, so the pipe-splitting fix never engages and
        // they were stored verbatim:
        //   "Meeting compact view"   - the window in compact mode
        //   "Microsoft Teams meeting" - Teams' default name for an untitled meeting
        // Both meetings had rich summaries, so the model names them far better.
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Meeting compact view", appName: "Teams") == nil)
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Microsoft Teams meeting", appName: "Teams") == nil)
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Meeting join", appName: "Teams") == nil)
    }

    @Test("the real meeting names from those same recordings still survive")
    func realMeetingNamesSurvive() {
        // The half that makes the rejection safe. Every one of these came off a
        // Teams window in the same fortnight and is exactly what the user wants
        // to see; a broader rule would eat them.
        for title in ["F1 STAND-UP MEETING", "Auracast Slicing Plan (D13, F1 & Allure)",
                      "WSA Remote Mic", "Srikar Singaraju", "D-WHAS"] {
            #expect(CallDetection.cleanedMeetingTitle(windowTitle: title, appName: "Teams") == title,
                    "\(title) was wrongly rejected")
        }
    }
}
