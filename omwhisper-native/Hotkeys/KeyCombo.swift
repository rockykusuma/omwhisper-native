//
//  KeyCombo.swift
//  OmWhisper
//
//  User-configurable dictation trigger data: a recorded keyboard combo for the
//  toggle shortcut, and a curated push-to-talk modifier key. Pure value types —
//  the GlobalHotkey / PushToTalkMonitor monitors consume these.
//

import AppKit

nonisolated struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt   // NSEvent.ModifierFlags rawValue, masked to relevantMask
    var label: String     // base key captured at record time, e.g. "V"

    static let relevantMask: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    static let defaultDictation = KeyCombo(
        keyCode: 9,
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        label: "V")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// A shortcut needs at least one of ⌘/⌃/⌥ — a ⇧-only or bare key would fire
    /// during normal typing.
    var hasRequiredModifier: Bool {
        !flags.intersection([.command, .control, .option]).isEmpty
    }

    /// Canonical glyph order ⌃⌥⇧⌘ + the base key.
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + label
    }
}

nonisolated enum PTTKey: String, CaseIterable, Identifiable {
    case fn, rightCommand, rightOption, rightControl

    var id: String { rawValue }

    var display: String {
        switch self {
        case .fn: "Fn / Globe"
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        }
    }

    /// keyCode + flag for the right-modifier variants; nil for .fn (flag-only —
    /// Fn has no reliable keyCode).
    private var keyCodeAndFlag: (UInt16, NSEvent.ModifierFlags)? {
        switch self {
        case .fn: nil
        case .rightCommand: (54, .command)
        case .rightOption: (61, .option)
        case .rightControl: (62, .control)
        }
    }

    /// Given a `.flagsChanged` event's keyCode + flags, is this PTT key now down?
    /// Returns nil when the event isn't about this key (so the caller ignores it).
    func pressState(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard let (kc, flag) = keyCodeAndFlag else {
            return flags.contains(.function)   // .fn: read the flag every event
        }
        guard keyCode == kc else { return nil }
        return flags.contains(flag)
    }
}
