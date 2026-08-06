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

    /// Is there genuinely nothing to draft from?
    ///
    /// A `.reply` with no on-screen context asks the model to reply to a
    /// conversation it cannot see, and a model told to draft a reply drafts
    /// one -- inventing the conversation to reply to. Observed live on
    /// 2026-08-06: double-tapping in a terminal (which exposes no AX text at
    /// all, being GPU-rendered) produced a confident, fluent message about a
    /// "Bake Sheet" print bug that existed nowhere on screen. The writing-tone
    /// profile made it read like the user, which made it worse, not better.
    ///
    /// Same shape as MeetingSummarizer.answer speculating when every extract
    /// was discarded, fixed 2026-08-02. When the material is not there, say so.
    ///
    /// `.continueDraft` and `.rewrite` carry their own material in the field
    /// itself, so they are unaffected by a blank screen read.
    static func hasNothingToWorkFrom(mode: ReplyMode, conversation: String?) -> Bool {
        guard case .reply = mode else { return false }
        return conversation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    static func style(mode: ReplyMode,
                      appName: String?,
                      windowTitle: String?,
                      windowContext: String?,
                      tonePrefix: String?) -> PolishStyle {
        var instructions = "You draft a reply/message for the user, writing AS the user in first person. Respond with ONLY the drafted text -- no preamble, no quotes, no explanation.\n\n"

        switch mode {
        case .reply:
            instructions += "Draft a new reply appropriate to the conversation context below.\n"
            // The escape hatch. ReplyStreamTypist has listed NO_REPLY_CONTEXT
            // among its sentinels since it was written, and NOTHING has ever
            // told the model to emit it -- a refusal path with no way to reach
            // it. Without this clause a screen holding prose that merely looks
            // like a conversation (a terminal, a code editor, a document) gets
            // a confident invented reply instead: observed live 2026-08-06,
            // three times running, in a terminal.
            instructions += """
                If the context below is not a conversation awaiting a reply -- \
                for example terminal output, source code, a document, or a log -- \
                output exactly \(ReplyStreamTypist.noReplyContextSentinel) and nothing else.\n
                """
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
