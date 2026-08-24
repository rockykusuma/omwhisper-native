import Testing
import AppKit
@testable import OmWhisper

/// The tap reads CGEventFlags; every hotkey comparison is against
/// NSEvent.ModifierFlags. If that translation drifts, no shortcut matches and
/// nothing says why — so pin it, including the defaults that actually ship.
struct GlobalHotkeyFlagsTests {
    @Test func mapsEachModifierBit() {
        #expect(GlobalHotkey.modifierFlags(from: .maskCommand) == [.command])
        #expect(GlobalHotkey.modifierFlags(from: .maskShift) == [.shift])
        #expect(GlobalHotkey.modifierFlags(from: .maskAlternate) == [.option])
        #expect(GlobalHotkey.modifierFlags(from: .maskControl) == [.control])
    }

    @Test func mapsCombinations() {
        #expect(GlobalHotkey.modifierFlags(from: [.maskCommand, .maskShift]) == [.command, .shift])
        #expect(GlobalHotkey.modifierFlags(from: [.maskControl, .maskAlternate]) == [.control, .option])
    }

    /// CapsLock, Fn, numeric-pad and the device-dependent bits ride along on
    /// real keystrokes. They must not end up in the comparison, or a shortcut
    /// stops matching the moment CapsLock is on.
    @Test func ignoresIrrelevantFlags() {
        #expect(GlobalHotkey.modifierFlags(from: [.maskCommand, .maskAlphaShift]) == [.command])
        #expect(GlobalHotkey.modifierFlags(from: [.maskCommand, .maskSecondaryFn]) == [.command])
        #expect(GlobalHotkey.modifierFlags(from: [.maskShift, .maskNumericPad]) == [.shift])
        #expect(GlobalHotkey.modifierFlags(from: []) == [])
    }

    /// The shipped defaults must survive the round trip a real keystroke makes.
    // @MainActor only to read the static defaults; no AppState is constructed,
    // so this never opens the real stores.
    @MainActor @Test func shippedDefaultsRoundTrip() {
        let cases: [(CGEventFlags, KeyCombo)] = [
            ([.maskCommand, .maskShift], KeyCombo.defaultDictation),
            ([.maskCommand, .maskShift], AppState.defaultSmartDictation),
            ([.maskCommand, .maskShift], AppState.defaultPolishSelected),
        ]
        for (flags, combo) in cases {
            #expect(GlobalHotkey.modifierFlags(from: flags) == combo.flags,
                    "\(combo.display) would never match a real keystroke")
        }
    }
}
