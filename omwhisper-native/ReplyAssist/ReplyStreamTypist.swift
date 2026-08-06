//
//  ReplyStreamTypist.swift
//  OmWhisper
//
//  Streams drafted text into the currently-focused field as synthesized
//  Unicode keystrokes -- ported from smriti's StreamTypist (same author,
//  MIT), chosen there over AXSelectedText because "Electron fields accept it
//  and render nothing." Deliberately does NOT use PasteService.paste(), which
//  always writes through NSPasteboard.general -- a visible clipboard flash is
//  wrong for text that's meant to look like it's being typed live, and
//  PasteService's single-shot paste+restore model doesn't fit incremental
//  streaming anyway.
//
//  The first `bufferThreshold` characters are buffered and checked against
//  known failure sentinels before anything is typed -- bufferThreshold must
//  exceed the longest sentinel so a failure is always still fully buffered
//  when checked (enforced by ReplyStreamTypistSentinelTests).
//
//  cancel() drops only pending (not-yet-typed) text -- whatever's already
//  been typed stays, matching smriti's StreamTypistTests-verified contract.
//
//  chunkSize deviates from smriti's 20-UTF16-unit chunks: confirmed live,
//  posting 20 characters as one synthetic keyDown event via
//  keyboardSetUnicodeString produced real, scattered character corruption
//  ("been" -> "bn", "Thank" -> "Tha") typing into Claude's web chat input --
//  its input handling couldn't reliably absorb a 20-character burst as a
//  single event. Single-character chunks are slower but match how every text
//  field's input handling is built to expect keystrokes -- one at a time.
//

import AppKit

nonisolated enum StreamResult: Equatable {
    case typed
    case declinedSentinel(String)
    case cancelled
}

@MainActor
final class ReplyStreamTypist {
    /// Named, because the draft prompt has to instruct the model to emit this
    /// exact token and a second copy of the literal would drift from this one.
    nonisolated static let noReplyContextSentinel = "NO_REPLY_CONTEXT"

    nonisolated static let sentinels = [
        noReplyContextSentinel, "Not logged in", "Please run /login", "Invalid API key",
    ]
    nonisolated static let bufferThreshold = 24
    nonisolated static let chunkSize = 1

    private var cancelled = false

    nonisolated static func sentinelMatch(in prefix: String) -> String? {
        sentinels.first { prefix.contains($0) }
    }

    func cancel() {
        cancelled = true
    }

    func stream(_ text: String) async -> StreamResult {
        cancelled = false
        let prefix = String(text.prefix(Self.bufferThreshold))
        if let sentinel = Self.sentinelMatch(in: prefix) {
            return .declinedSentinel(sentinel)
        }

        let utf16 = Array(text.utf16)
        var index = 0
        let source = CGEventSource(stateID: .combinedSessionState)
        while index < utf16.count {
            if cancelled { return .cancelled }
            let chunk = Array(utf16[index..<min(index + Self.chunkSize, utf16.count)])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            index += Self.chunkSize
            try? await Task.sleep(for: .milliseconds(8))
        }
        return .typed
    }
}
