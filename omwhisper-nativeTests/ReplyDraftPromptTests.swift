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

@Suite("Reply Assist refuses rather than inventing")
struct ReplyDraftNothingToWorkFromTests {
    @Test("a reply with no on-screen context is refused")
    func replyWithNoContextIsRefused() {
        // Observed live 2026-08-06: double-tapping in a terminal, which exposes
        // no AX text at all, produced a fluent invented message about a "Bake
        // Sheet" print bug that was nowhere on screen. The prompt said "draft a
        // reply appropriate to the conversation context below" and then
        // included no context, so the model invented the conversation.
        #expect(ReplyDraftPrompt.hasNothingToWorkFrom(mode: .reply, conversation: nil))
        #expect(ReplyDraftPrompt.hasNothingToWorkFrom(mode: .reply, conversation: ""))
        #expect(ReplyDraftPrompt.hasNothingToWorkFrom(mode: .reply, conversation: "   \n\t "))
    }

    @Test("a reply WITH context still drafts")
    func replyWithContextProceeds() {
        // The half that makes this a real check: a guard that refuses
        // everything would pass the test above.
        #expect(!ReplyDraftPrompt.hasNothingToWorkFrom(
            mode: .reply, conversation: "Alice: can you ship by Friday?"))
    }

    @Test("continue and rewrite carry their own material")
    func fieldModesAreUnaffectedByABlankScreen() {
        // These do not need the screen -- the text is in the field. Refusing
        // them on a blank read would break rewriting a selection in any app
        // whose surrounding window is not AX-readable.
        #expect(!ReplyDraftPrompt.hasNothingToWorkFrom(
            mode: .continueDraft("Thanks for the update, I"), conversation: nil))
        #expect(!ReplyDraftPrompt.hasNothingToWorkFrom(
            mode: .rewrite("make this sound better"), conversation: nil))
    }
}

@Suite("Reply Assist diagnostics and refusal")
struct ReplyAssistRefusalTests {
    @Test("the log names the mode and its size, never its content")
    func logDescriptionIsUsefulAndContentFree() {
        // The first version was String(describing:).prefix(14), which printed
        // exactly "continueDraft(" — it stopped where the interesting part
        // starts, and could not distinguish an empty compose box
        // misclassified as a continuation from a real half-written draft.
        #expect(ReplyMode.reply.logDescription == "reply")
        #expect(ReplyMode.continueDraft("Thanks Christian").logDescription == "continue(16 chars)")
        #expect(ReplyMode.rewrite("make it shorter").logDescription == "rewrite(15 chars)")
        let secret = "the merge is blocked on Christian's 7.0.215 tag"
        #expect(!ReplyMode.continueDraft(secret).logDescription.contains("Christian"))
    }

    @Test("the reply prompt tells the model how to refuse")
    func replyPromptCarriesTheRefusalToken() {
        // ReplyStreamTypist has listed NO_REPLY_CONTEXT among its sentinels
        // since it was written, and no prompt ever asked for it — a refusal
        // path with no way to reach it. This pins the two together.
        let style = ReplyDraftPrompt.style(mode: .reply, appName: "Orca", windowTitle: nil,
                                           windowContext: "$ git status", tonePrefix: nil)
        #expect(style.prompt.contains(ReplyStreamTypist.noReplyContextSentinel))
    }

    @Test("continue and rewrite are never told to refuse")
    func fieldModesAreNotOfferedTheEscapeHatch() {
        // Their material is the user's own text. A model refusing to rewrite
        // a selection because the surrounding window is not a chat would be
        // a regression, not a safeguard.
        for mode in [ReplyMode.continueDraft("half a sentence"), .rewrite("some text")] {
            let style = ReplyDraftPrompt.style(mode: mode, appName: nil, windowTitle: nil,
                                               windowContext: "$ git status", tonePrefix: nil)
            #expect(!style.prompt.contains(ReplyStreamTypist.noReplyContextSentinel),
                    "\(mode) was offered the refusal token")
        }
    }

    @Test("the sentinel is short enough to be caught before anything is typed")
    func sentinelFitsTheBuffer() {
        // The typist buffers bufferThreshold characters and checks them before
        // the first keystroke. A sentinel longer than that would be half-typed
        // into the user's field before being recognised.
        #expect(ReplyStreamTypist.noReplyContextSentinel.count < ReplyStreamTypist.bufferThreshold)
    }
}
