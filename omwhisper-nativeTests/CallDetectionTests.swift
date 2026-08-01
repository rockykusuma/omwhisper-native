import Testing
@testable import OmWhisper

struct CallDetectionTests {
    @Test func zoomIsRecognizedWithoutVerification() {
        // Zoom doesn't need verification (it's essentially only mic-active during a call).
        let result = CallDetection.recognizedApp(bundleID: "us.zoom.xos", isFrontmost: false, hasCallLikeWindowTitle: false)
        #expect(result == "Zoom")
    }

    @Test func slackNeedsFrontmostOrCallLikeTitle() {
        // Slack runs persistently outside calls -> needs verification.
        let notInCall = CallDetection.recognizedApp(bundleID: "com.tinyspeck.slackmacgap", isFrontmost: false, hasCallLikeWindowTitle: false)
        #expect(notInCall == nil)

        let frontmost = CallDetection.recognizedApp(bundleID: "com.tinyspeck.slackmacgap", isFrontmost: true, hasCallLikeWindowTitle: false)
        #expect(frontmost == "Slack")

        let callLikeTitle = CallDetection.recognizedApp(bundleID: "com.tinyspeck.slackmacgap", isFrontmost: false, hasCallLikeWindowTitle: true)
        #expect(callLikeTitle == "Slack")
    }

    @Test func unrecognizedBundleIDReturnsNil() {
        let result = CallDetection.recognizedApp(bundleID: "com.omwhisper.mac", isFrontmost: true, hasCallLikeWindowTitle: false)
        #expect(result == nil)
    }

    @Test func meetingURLsAreRecognized() {
        #expect(CallDetection.isMeetingURL("https://meet.google.com/abc-defg-hij"))
        #expect(CallDetection.isMeetingURL("https://zoom.us/j/1234567890"))
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
