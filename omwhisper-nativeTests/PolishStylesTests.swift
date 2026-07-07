import Foundation
import Testing
@testable import OmWhisper

struct PolishStylesTests {
    @Test func builtInCatalogHasSevenStyles() {
        #expect(PolishStyles.builtIns.count == 7)
    }

    @Test func builtInNamesAreCorrect() {
        let names = Set(PolishStyles.builtIns.map(\.name))
        #expect(names == ["Professional", "Casual", "Concise", "Translate", "Email Format", "Meeting Notes", "Smart Correct"])
    }

    @Test func allBuiltInsAreMarkedBuiltIn() {
        #expect(PolishStyles.builtIns.allSatisfy { $0.isBuiltIn })
    }

    @Test func onlyTranslateRequiresTargetLanguage() {
        let flagged = PolishStyles.builtIns.filter(\.requiresTargetLanguage)
        #expect(flagged.count == 1)
        #expect(flagged.first?.name == "Translate")
    }

    @Test func builtInIDsAreStableAcrossCalls() {
        // Fixed UUIDs, not regenerated per call — activePolishStyleID must survive relaunches.
        let first = PolishStyles.builtIns.map(\.id)
        let second = PolishStyles.builtIns.map(\.id)
        #expect(first == second)
    }

    @Test func allMergesBuiltInsAndCustomStyles() {
        let custom = PolishStyle(id: UUID(), name: "My Style", prompt: "Do the thing.", isBuiltIn: false)
        let merged = PolishStyles.all(customStyles: [custom])
        #expect(merged.count == 8)
        #expect(merged.contains { $0.id == custom.id })
    }

    @Test func styleLookupFindsBuiltIn() {
        let professional = PolishStyles.builtIns.first { $0.name == "Professional" }!
        #expect(PolishStyles.style(id: professional.id, customStyles: []) == professional)
    }

    @Test func styleLookupFindsCustom() {
        let custom = PolishStyle(id: UUID(), name: "Mine", prompt: "x", isBuiltIn: false)
        #expect(PolishStyles.style(id: custom.id, customStyles: [custom]) == custom)
    }

    @Test func styleLookupReturnsNilForUnknownID() {
        #expect(PolishStyles.style(id: UUID(), customStyles: []) == nil)
    }
}
