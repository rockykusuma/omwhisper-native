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

import AppKit

nonisolated enum StreamResult: Equatable {
    case typed
    case declinedSentinel(String)
    case cancelled
}

@MainActor
final class ReplyStreamTypist {
    nonisolated static let sentinels = [
        "NO_REPLY_CONTEXT", "Not logged in", "Please run /login", "Invalid API key",
    ]
    nonisolated static let bufferThreshold = 24

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
            let chunk = Array(utf16[index..<min(index + 20, utf16.count)])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            index += 20
            try? await Task.sleep(for: .milliseconds(8))
        }
        return .typed
    }
}
