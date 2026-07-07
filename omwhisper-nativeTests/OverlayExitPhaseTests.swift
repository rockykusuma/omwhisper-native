//
//  OverlayExitPhaseTests.swift
//  omwhisper-nativeTests
//
//  Covers AppState.exitPhase(heldFor:text:hadPartial:) — the one real branch
//  of decision logic behind the Om Orb overlay's exit flourish. Pure/nonisolated,
//  so testable with no actor/timer/UI setup.
//

import Testing
@testable import OmWhisper

struct OverlayExitPhaseTests {
    @Test func shortHoldEmptyTextCancels() {
        let phase = AppState.exitPhase(heldFor: .milliseconds(200), text: "", hadPartial: false)
        #expect(phase == .cancelled)
    }

    @Test func shortHoldWithTextStillPastes() {
        // A genuine quick utterance shouldn't be cancelled just because the hold was brief.
        let phase = AppState.exitPhase(heldFor: .milliseconds(200), text: "hi", hadPartial: false)
        #expect(phase == .pasting)
    }

    @Test func exactlyAtThresholdDoesNotCancel() {
        // heldFor < 500ms cancels; exactly 500ms does not (boundary is exclusive).
        let phase = AppState.exitPhase(heldFor: .milliseconds(500), text: "", hadPartial: false)
        #expect(phase == .error(label: "NOTHING HEARD"))
    }

    @Test func longHoldEmptyTextIsNothingHeard() {
        let phase = AppState.exitPhase(heldFor: .milliseconds(600), text: "", hadPartial: false)
        #expect(phase == .error(label: "NOTHING HEARD"))
    }

    @Test func longHoldEmptyTextWithEngineErrorIsSomethingBroke() {
        let phase = AppState.exitPhase(heldFor: .milliseconds(600), text: "", hadPartial: true)
        #expect(phase == .error(label: "SOMETHING BROKE — TEXT COPIED"))
    }

    @Test func toggleStopHasNoHoldConcept() {
        // Toggle-triggered stops pass heldFor: nil — cancel is PTT-only.
        #expect(AppState.exitPhase(heldFor: nil, text: "", hadPartial: false) == .error(label: "NOTHING HEARD"))
        #expect(AppState.exitPhase(heldFor: nil, text: "hello", hadPartial: false) == .pasting)
    }

    @Test func anyNonEmptyTextPastesRegardlessOfHoldOrError() {
        #expect(AppState.exitPhase(heldFor: .milliseconds(50), text: "word", hadPartial: true) == .pasting)
        #expect(AppState.exitPhase(heldFor: .seconds(5), text: "word", hadPartial: false) == .pasting)
    }
}
