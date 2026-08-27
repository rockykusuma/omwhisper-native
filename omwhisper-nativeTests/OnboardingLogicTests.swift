import Testing
@testable import OmWhisper

struct OnboardingStepTests {
    @Test func nextAdvancesThenStops() {
        #expect(OnboardingStep.welcome.next == .permissions)
        #expect(OnboardingStep.permissions.next == .tryIt)
        #expect(OnboardingStep.tryIt.next == .aiPolish)
        #expect(OnboardingStep.aiPolish.next == .done)
        #expect(OnboardingStep.done.next == .done)   // clamps at the last step
    }

    @Test func isLastOnlyForDone() {
        #expect(OnboardingStep.done.isLast)
        #expect(!OnboardingStep.welcome.isLast)
        #expect(!OnboardingStep.tryIt.isLast)
        #expect(!OnboardingStep.aiPolish.isLast)
    }

    @Test func allCasesInOrder() {
        #expect(OnboardingStep.allCases == [.welcome, .permissions, .tryIt, .aiPolish, .done])
    }
}

struct OnboardingWPMTests {
    @Test func normalCase() {
        // 30 words in 30 seconds = 60 wpm
        #expect(wordsPerMinute(wordCount: 30, seconds: 30) == 60)
    }

    @Test func zeroOrNegativeSecondsIsZero() {
        #expect(wordsPerMinute(wordCount: 12, seconds: 0) == 0)
        #expect(wordsPerMinute(wordCount: 12, seconds: -5) == 0)
    }

    @Test func rounds() {
        // 10 words in 7 seconds = 85.7 -> 86
        #expect(wordsPerMinute(wordCount: 10, seconds: 7) == 86)
    }

    @Test func neverNegative() {
        #expect(wordsPerMinute(wordCount: 0, seconds: 10) == 0)
    }
}
