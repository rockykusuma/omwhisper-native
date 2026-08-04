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
