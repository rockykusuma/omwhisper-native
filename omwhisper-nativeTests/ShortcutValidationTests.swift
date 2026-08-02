//
//  ShortcutValidationTests.swift
//  omwhisper-nativeTests
//
//  Only conflicts OmWhisper can PROVE: duplicates among its own shortcuts and
//  reserved system combos. Another app's bindings are undetectable via NSEvent
//  monitors, so nothing here claims to know about them.
//

import AppKit
import Testing
@testable import OmWhisper

struct ShortcutValidationTests {
    private func combo(_ keyCode: UInt16, _ label: String,
                       _ mods: NSEvent.ModifierFlags = [.command, .shift]) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: mods.rawValue, label: label)
    }

    @Test("a combo held by another feature is rejected, naming the holder")
    func rejectsDuplicateAcrossFeatures() {
        let taken = combo(9, "V")
        let result = ShortcutValidation.conflict(
            for: taken, assigning: .polishSelected,
            current: [.dictation: taken])
        #expect(result == .alreadyUsed(by: .dictation))
        #expect(result?.message.contains("dictation") == true
                || result?.message.contains("Dictation") == true)
    }

    @Test("reassigning a feature to its OWN current combo is not a conflict")
    func ownComboIsNotAConflict() {
        // A naive "is this in use?" check gets this wrong and makes a shortcut
        // unsavable once set — you could never re-record the same keys.
        let mine = combo(35, "P")
        let result = ShortcutValidation.conflict(
            for: mine, assigning: .polishSelected,
            current: [.polishSelected: mine, .dictation: combo(9, "V")])
        #expect(result == nil)
    }

    @Test("two disabled features are not in conflict")
    func disabledFeaturesDoNotClash() {
        // Absent slots mean "disabled". A naive equality check over optionals
        // treats nil == nil as a duplicate and blocks disabling the second one.
        let proposed = combo(2, "D")
        let result = ShortcutValidation.conflict(
            for: proposed, assigning: .brainDump,
            current: [.dictation: combo(9, "V")])   // smartDictation & polishSelected absent
        #expect(result == nil)
    }

    @Test("reserved system combos are rejected")
    func rejectsReservedCombos() {
        for reserved in ShortcutValidation.reservedCombos {
            let result = ShortcutValidation.conflict(
                for: reserved, assigning: .brainDump, current: [:])
            #expect(result == .reserved, "should have reserved \(reserved.display)")
        }
        #expect(ShortcutValidation.reservedCombos.count >= 6)
    }

    @Test("an unused combo is accepted")
    func acceptsFreeCombo() {
        let result = ShortcutValidation.conflict(
            for: combo(17, "T", [.command, .control]),
            assigning: .brainDump,
            current: [.dictation: combo(9, "V"), .polishSelected: combo(35, "P")])
        #expect(result == nil)
    }

    @Test("same key, different modifiers, is a different shortcut")
    func modifiersDistinguishCombos() {
        let result = ShortcutValidation.conflict(
            for: combo(9, "V", [.command, .option]),
            assigning: .polishSelected,
            current: [.dictation: combo(9, "V", [.command, .shift])])
        #expect(result == nil)
    }
}
