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

    @Test func cleanedTitleKeepsPlainTitles() {
        #expect(CallDetection.cleanedMeetingTitle(
            windowTitle: "Design review with hardware team", appName: "Teams")
            == "Design review with hardware team")
    }
}
