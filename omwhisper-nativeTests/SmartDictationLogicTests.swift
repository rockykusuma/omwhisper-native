import Testing
@testable import OmWhisper

struct SmartDictationLogicTests {
    @Test func emptyTextFailsMinWordsGuard() {
        #expect(AppState.tooShortForPolish(""))
    }

    @Test func oneWordFailsMinWordsGuard() {
        #expect(AppState.tooShortForPolish("Hello"))
    }

    @Test func twoWordsFailsMinWordsGuard() {
        #expect(AppState.tooShortForPolish("Hello there"))
    }

    @Test func threeWordsPassesMinWordsGuard() {
        #expect(!AppState.tooShortForPolish("Hello there friend"))
    }

    @Test func extraWhitespaceDoesNotInflateWordCount() {
        #expect(AppState.tooShortForPolish("  Hello   there  "))
    }
}
