//
//  DegradationTests.swift
//  omwhisper-nativeTests
//
//  The mechanism exists because Apple Intelligence never worked on an en-IN
//  Mac and polish silently pasted raw text for months. These tests pin the
//  behaviour that would have caught it.
//

import Testing
@testable import OmWhisper

@MainActor
struct DegradationTests {
    @Test("nine failures escalate nothing; the tenth escalates")
    func escalatesAtTheThresholdAndNotBefore() {
        // The test that fails if the mechanism always fires or never fires.
        // "Does it escalate?" alone passes in both broken directions.
        for streak in 1..<10 {
            #expect(!Degradation.shouldEscalate(streak: streak, threshold: 10, alreadyWarned: false),
                    "escalated early at \(streak)")
        }
        #expect(Degradation.shouldEscalate(streak: 10, threshold: 10, alreadyWarned: false))
    }

    @Test("escalation happens once, not on every later failure")
    func escalatesOnlyOnce() {
        #expect(!Degradation.shouldEscalate(streak: 11, threshold: 10, alreadyWarned: true))
        #expect(!Degradation.shouldEscalate(streak: 50, threshold: 10, alreadyWarned: true))
    }

    @Test("thresholds are per feature")
    func perFeatureThresholds() {
        #expect(Degradation.Feature.polish.threshold == 10)
        // Capture ticks every 5s, so 10 would be under a minute of ordinary
        // window-switching. 120 is roughly ten minutes of capturing nothing.
        #expect(Degradation.Feature.memoryCapture.threshold == 120)
        #expect(!Degradation.shouldEscalate(streak: 10, threshold: 120, alreadyWarned: false))
    }

    @Test("recording accumulates, and a success resets it")
    func recordAndReset() {
        Degradation.reset(.polish)
        Degradation.record(.polish, reason: "model unavailable")
        Degradation.record(.polish, reason: "model unavailable")
        #expect(Degradation.state(.polish).streak == 2)
        #expect(Degradation.state(.polish).reason == "model unavailable")

        Degradation.recordSuccess(.polish)
        #expect(Degradation.state(.polish).streak == 0)
    }

    @Test("a success re-arms escalation for a later streak")
    func successReArmsTheWarning() {
        Degradation.reset(.polish)
        for _ in 0..<10 { Degradation.record(.polish, reason: "timed out") }
        #expect(Degradation.escalationMessage(.polish) != nil, "first streak should escalate")
        #expect(Degradation.escalationMessage(.polish) == nil, "must not re-fire for the same streak")

        Degradation.recordSuccess(.polish)
        for _ in 0..<10 { Degradation.record(.polish, reason: "timed out") }
        #expect(Degradation.escalationMessage(.polish) != nil, "a later streak should escalate again")
        Degradation.reset(.polish)
    }

    @Test("the message names the feature and the reason")
    func messageIsActionable() {
        Degradation.reset(.polish)
        for _ in 0..<10 { Degradation.record(.polish, reason: "Apple Intelligence doesn't support en-IN") }
        let message = Degradation.escalationMessage(.polish)
        #expect(message?.contains("en-IN") == true, "the real cause must survive into the message")
        #expect(message?.contains("10") == true, "say how many times, so it reads as a pattern")
        Degradation.reset(.polish)
    }

    @Test("features are independent")
    func featuresDoNotShareCounters() {
        Degradation.reset(.polish)
        Degradation.reset(.memoryCapture)
        for _ in 0..<10 { Degradation.record(.polish, reason: "x") }
        #expect(Degradation.state(.memoryCapture).streak == 0)
        Degradation.reset(.polish)
    }
}
