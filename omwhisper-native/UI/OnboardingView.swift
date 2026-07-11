//
//  OnboardingView.swift
//  OmWhisper
//
//  First-run flow. Dark identity only (see CLAUDE.md scope rule). The "Try it"
//  step runs a REAL dictation session with onboardingDemoActive set, so nothing
//  is pasted or written to history — the field just mirrors the live transcript.
//

import SwiftUI

nonisolated enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, tryIt, done

    /// Advances to the following step; clamps at `.done`.
    var next: OnboardingStep { OnboardingStep(rawValue: rawValue + 1) ?? self }
    var isLast: Bool { self == .done }
}

/// Words-per-minute for the try-it readout. Pure so it's unit-testable.
nonisolated func wordsPerMinute(wordCount: Int, seconds: Double) -> Int {
    guard seconds > 0 else { return 0 }
    return max(0, Int((Double(wordCount) / (seconds / 60)).rounded()))
}
