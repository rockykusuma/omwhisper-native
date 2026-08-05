//
//  ReplyDraftPrompt.swift
//  OmWhisper
//
//  Assembles the Reply Assist draft prompt. Pure and free of AppState on
//  purpose: this used to be a private static on AppState, which no test can
//  construct (its initialiser opens the real history and memory stores), so the
//  prompt's most important properties -- that the newest on-screen text
//  survives the cap, and that a rewrite and a continuation truncate from
//  opposite ends -- went unasserted.
//

import Foundation

nonisolated enum ReplyDraftPrompt {
    /// ScreenContextReader can return up to 50,000 characters, and the AX-read
    /// draft/selection is equally uncapped -- a focused "field" that is a
    /// document editor yields the whole document. Both are capped because
    /// including that much text tripped SystemLLM's 5s timeout on every draft
    /// (confirmed live: "Polish timed out" against a text-heavy markdown file
    /// in a background window).
    static let contextCap = 2_000
    static let fieldTextCap = 2_000

    static func style(mode: ReplyMode,
                      appName: String?,
                      windowTitle: String?,
                      windowContext: String?,
                      tonePrefix: String?) -> PolishStyle {
        var instructions = "You draft a reply/message for the user, writing AS the user in first person. Respond with ONLY the drafted text -- no preamble, no quotes, no explanation.\n\n"

        switch mode {
        case .reply:
            instructions += "Draft a new reply appropriate to the conversation context below.\n"
        case .continueDraft(let draft):
            // suffix, not prefix -- continuing a draft cares about its most
            // recent tail, not however it started.
            instructions += "Continue this unfinished draft naturally, in the same voice:\n\(draft.suffix(fieldTextCap))\n"
        case .rewrite(let selection):
            instructions += "Rewrite this selected text, keeping its meaning:\n\(selection.prefix(fieldTextCap))\n"
        }

        // Where the user is. Register differs between a team chat and an email
        // thread, and the model cannot tell them apart from body text alone.
        if let appName, !appName.isEmpty { instructions += "\nApp: \(appName)\n" }
        if let windowTitle, !windowTitle.isEmpty { instructions += "Window: \(windowTitle)\n" }

        if let windowContext, !windowContext.isEmpty {
            // suffix, not prefix -- the conversation is read top-down, so the
            // newest message (what you're replying to) is at the BOTTOM.
            // Keeping the head fed the model the oldest scrollback and
            // truncated away the live message.
            instructions += "\nOn-screen context:\n\(windowContext.suffix(contextCap))\n"
        }
        if let tonePrefix, !tonePrefix.isEmpty {
            instructions += "\nWriting tone to match:\n\(tonePrefix)\n"
        }

        return PolishStyle(
            id: UUID(uuidString: "7610B7A2-5DAA-4017-A135-45B67089A0FB")!,
            name: "Reply Draft",
            prompt: instructions,
            isBuiltIn: true
        )
    }
}
