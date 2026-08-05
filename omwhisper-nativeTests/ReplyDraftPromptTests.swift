import Foundation
import Testing
@testable import OmWhisper

@Suite("Reply draft prompt")
struct ReplyDraftPromptTests {
    /// Longer than the cap, with a known marker at the very end.
    private func longContext(endingWith marker: String) -> String {
        String(repeating: "old scrollback line. ", count: 400) + marker
    }

    @Test("the newest on-screen text survives the cap")
    func newestContextSurvivesTheCap() {
        // The message being replied to is the LAST thing on screen. A test that
        // only checked "the prompt contains the context" would pass while
        // truncating exactly that away, which is the bug this guards.
        let marker = "MOST-RECENT-MESSAGE-a7f3"
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: "Slack", windowTitle: "#general",
            windowContext: longContext(endingWith: marker), tonePrefix: nil)
        #expect(style.prompt.contains(marker))
    }

    @Test("a continuation keeps the draft's tail, not its head")
    func continuationKeepsTheTail() {
        // Continuing cares about where the sentence got to, not how it opened.
        let draft = String(repeating: "earlier words ", count: 400) + "TAIL-b2c1"
        let style = ReplyDraftPrompt.style(
            mode: .continueDraft(draft), appName: "Mail", windowTitle: "Re: pricing",
            windowContext: nil, tonePrefix: nil)
        #expect(style.prompt.contains("TAIL-b2c1"))
    }

    @Test("a rewrite keeps the selection's head, not its tail")
    func rewriteKeepsTheHead() {
        // Opposite of a continuation, and easy to transpose. A rewrite starts
        // from the beginning of what was selected.
        let selection = "HEAD-d4e5 " + String(repeating: "selected words ", count: 400)
        let style = ReplyDraftPrompt.style(
            mode: .rewrite(selection), appName: "Notes", windowTitle: "Ideas",
            windowContext: nil, tonePrefix: nil)
        #expect(style.prompt.contains("HEAD-d4e5"))
    }

    @Test("the prompt says which app and window it is in")
    func namesTheAppAndWindow() {
        // A reply in Slack and one in Mail should not be framed identically.
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: "Slack", windowTitle: "#eng-releases",
            windowContext: "hey, can you review this?", tonePrefix: nil)
        #expect(style.prompt.contains("Slack"))
        #expect(style.prompt.contains("#eng-releases"))
    }

    @Test("absent app, title and tone render no empty lines")
    func absentFieldsAreOmitted() {
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: nil, windowTitle: nil,
            windowContext: nil, tonePrefix: nil)
        #expect(!style.prompt.contains("App:"))
        #expect(!style.prompt.contains("Window:"))
        #expect(!style.prompt.contains("Writing tone"))
        #expect(!style.prompt.contains("On-screen context"))
    }

    @Test("tone is included when present")
    func toneIncludedWhenPresent() {
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: nil, windowTitle: nil,
            windowContext: nil, tonePrefix: "Short sentences. No exclamation marks.")
        #expect(style.prompt.contains("No exclamation marks"))
    }

    @Test("the style id is stable so stored defaults keep resolving")
    func styleIDIsUnchanged() {
        // Same fixed UUID the inline draftStyle used — hidden styles are
        // referenced by id elsewhere, and changing it would orphan them.
        let style = ReplyDraftPrompt.style(
            mode: .reply, appName: nil, windowTitle: nil,
            windowContext: nil, tonePrefix: nil)
        #expect(style.id == UUID(uuidString: "7610B7A2-5DAA-4017-A135-45B67089A0FB")!)
    }
}
