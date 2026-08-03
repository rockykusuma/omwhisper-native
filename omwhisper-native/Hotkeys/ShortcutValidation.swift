//
//  ShortcutValidation.swift
//  OmWhisper
//
//  Whether a proposed shortcut can be assigned. Guards ONLY what is provable:
//  a duplicate among OmWhisper's own shortcuts, and reserved system combos.
//
//  It deliberately does NOT try to detect other applications' shortcuts.
//  GlobalHotkey uses NSEvent.addGlobalMonitorForEvents, which observes rather
//  than owns -- it never fails because another app holds a combo, and there is
//  no supported API to enumerate what other apps have bound. A false
//  "no conflict" would be a promise the app cannot keep.
//

import AppKit

nonisolated enum ShortcutSlot: String, CaseIterable, Identifiable {
    case dictation, smartDictation, polishSelected, brainDump

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Toggle dictation"
        case .smartDictation: "Smart Dictation"
        case .polishSelected: "Polish Selected Text"
        case .brainDump: "Brain-dump"
        }
    }
}

nonisolated enum ShortcutValidation {
    enum Conflict: Equatable {
        case alreadyUsed(by: ShortcutSlot)
        case reserved

        var message: String {
            switch self {
            case .alreadyUsed(let slot):
                "Already used by \(slot.title)."
            case .reserved:
                "That combination is reserved by macOS."
            }
        }
    }

    /// Combos macOS itself owns. Assigning these would either never fire or
    /// break something the user needs more than a dictation shortcut.
    static let reservedCombos: [KeyCombo] = [
        KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "Space"),
        KeyCombo(keyCode: 48, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "Tab"),
        KeyCombo(keyCode: 12, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "Q"),
        KeyCombo(keyCode: 13, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "W"),
        KeyCombo(keyCode: 4, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "H"),
        KeyCombo(keyCode: 46, modifiers: NSEvent.ModifierFlags.command.rawValue, label: "M"),
    ]

    /// nil when `combo` may be assigned to `slot`.
    ///
    /// `current` holds only the slots that HAVE a shortcut -- an absent slot is
    /// a disabled feature, so two disabled features can never collide.
    static func conflict(
        for combo: KeyCombo,
        assigning slot: ShortcutSlot,
        current: [ShortcutSlot: KeyCombo]
    ) -> Conflict? {
        if reservedCombos.contains(where: { sameBinding($0, combo) }) { return .reserved }
        // Skip the slot being assigned: re-recording the keys a feature already
        // has is not a conflict with itself.
        for (other, assigned) in current where other != slot {
            if sameBinding(assigned, combo) { return .alreadyUsed(by: other) }
        }
        return nil
    }

    /// Same key AND same modifiers. `label` is display-only and is deliberately
    /// ignored: the same physical key can be captured with a different label
    /// under a different keyboard layout.
    private static func sameBinding(_ a: KeyCombo, _ b: KeyCombo) -> Bool {
        a.keyCode == b.keyCode
            && a.flags.intersection(KeyCombo.relevantMask) == b.flags.intersection(KeyCombo.relevantMask)
    }
}
