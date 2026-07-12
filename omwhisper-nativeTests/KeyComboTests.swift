import Testing
import AppKit
@testable import OmWhisper

struct KeyComboTests {
    @Test func displayOrdersModifiersThenLabel() {
        let c = KeyCombo(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, label: "V")
        #expect(c.display == "⇧⌘V")
    }

    @Test func displayFullModifierOrder() {
        let c = KeyCombo(keyCode: 0, modifiers: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue, label: "A")
        #expect(c.display == "⌃⌥⇧⌘A")
    }

    @Test func requiresCommandControlOrOption() {
        let shiftOnly = KeyCombo(keyCode: 9, modifiers: NSEvent.ModifierFlags([.shift]).rawValue, label: "V")
        #expect(shiftOnly.hasRequiredModifier == false)
        let withCmd = KeyCombo(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command]).rawValue, label: "V")
        #expect(withCmd.hasRequiredModifier == true)
    }

    @Test func defaultIsCommandShiftV() {
        #expect(KeyCombo.defaultDictation.display == "⇧⌘V")
    }

    @Test func fnPressStateReadsFunctionFlag() {
        #expect(PTTKey.fn.pressState(keyCode: 999, flags: [.function]) == true)
        #expect(PTTKey.fn.pressState(keyCode: 999, flags: []) == false)
    }

    @Test func rightModifierPressStateMatchesKeyCodeAndFlag() {
        #expect(PTTKey.rightCommand.pressState(keyCode: 54, flags: [.command]) == true)
        #expect(PTTKey.rightCommand.pressState(keyCode: 54, flags: []) == false)
        // A different modifier's event (e.g. shift, keyCode 60) is not this key.
        #expect(PTTKey.rightCommand.pressState(keyCode: 60, flags: [.command]) == nil)
    }
}
