//
//  DoubleTapDetector.swift
//  OmWhisper
//
//  Pure double-tap timing state machine, ported from smriti's AssistListener.swift
//  (same author, MIT, read-only reference). No AX/CGEvent/NSEvent dependency --
//  ReplyAssistMonitor decides WHEN to call tapDetected(at:)/interrupt(), this
//  type only tracks the timing window between two calls.
//

import Foundation

nonisolated struct DoubleTapDetector {
    let window: TimeInterval
    private var lastTapAt: TimeInterval?

    init(window: TimeInterval = 0.45) {
        self.window = window
    }

    /// Returns true if `time` completes a double-tap with the immediately
    /// preceding call. Consumes the pair on a fire, so a rapid triple-tap
    /// fires once (on the 2nd tap) and the 3rd tap becomes a fresh pending
    /// single rather than re-firing immediately.
    mutating func tapDetected(at time: TimeInterval) -> Bool {
        if let lastTapAt, time - lastTapAt <= window {
            self.lastTapAt = nil
            return true
        }
        lastTapAt = time
        return false
    }

    /// Clears any pending single tap -- called when a different key/modifier
    /// is pressed, so e.g. ⌥4→€ or a held Cmd/Ctrl/Shift never counts as part
    /// of a future double-tap pair.
    mutating func interrupt() {
        lastTapAt = nil
    }
}
