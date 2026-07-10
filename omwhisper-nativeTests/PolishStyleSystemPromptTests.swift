import Foundation
import Testing
@testable import OmWhisper

struct PolishStyleSystemPromptTests {
    @Test func nonTranslateReturnsPromptVerbatim() {
        let s = PolishStyle(id: UUID(), name: "Concise", prompt: "Make it concise.", isBuiltIn: true)
        #expect(s.systemPrompt(targetLanguage: "Spanish") == "Make it concise.")
        #expect(s.systemPrompt(targetLanguage: nil) == "Make it concise.")
    }

    @Test func translateSubstitutesLanguage() {
        let s = PolishStyle(id: UUID(), name: "Translate", prompt: "Translate to {language}.",
                            isBuiltIn: true, requiresTargetLanguage: true)
        #expect(s.systemPrompt(targetLanguage: "German") == "Translate to German.")
    }

    @Test func translateWithNilLanguageLeavesPlaceholder() {
        let s = PolishStyle(id: UUID(), name: "Translate", prompt: "Translate to {language}.",
                            isBuiltIn: true, requiresTargetLanguage: true)
        #expect(s.systemPrompt(targetLanguage: nil) == "Translate to {language}.")
    }
}
