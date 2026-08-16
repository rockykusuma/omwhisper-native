import Foundation
import Testing
@testable import OmWhisper

/// Why source-level rather than behavioural: constructing `AppState` in a test
/// opens the real history and memory stores, which is why no test in this suite
/// does it. The bug being pinned is an ORDERING of MainActor side effects —
/// clear-then-show versus show-then-clear — with no pure piece to extract, so
/// the invariant is enforced structurally: one preamble, and it clears.
@Suite("Dictation session preamble")
struct SessionPreambleTests {
    private static func appStateSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // omwhisper-nativeTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("omwhisper-native/AppState.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The load-bearing one. Until 2026-08-16 the transcripts were cleared
    /// inside `startDictation()`, which runs in a Task behind two awaited
    /// permission checks, while `overlay.show` ran synchronously — so holding Fn
    /// flashed the PREVIOUS dictation's text for about a second. Clearing in the
    /// synchronous preamble is the fix; this fails if it moves back.
    @Test("the preamble clears both transcripts before showing the overlay")
    func preambleClearsBeforeShowing() throws {
        let source = try Self.appStateSource()
        let start = try #require(source.range(of: "private func beginSession() {"),
                                 "beginSession() is the shared preamble — renaming it needs this test updated")
        let body = try #require(source.range(of: "\n    }", range: start.upperBound ..< source.endIndex))
        let preamble = String(source[start.upperBound ..< body.lowerBound])

        let finalized = try #require(preamble.range(of: #"finalizedTranscript = """#),
                                     "beginSession() must clear finalizedTranscript")
        let volatileRange = try #require(preamble.range(of: #"volatileTranscript = """#),
                                         "beginSession() must clear volatileTranscript")
        let show = try #require(preamble.range(of: "overlay.show"),
                                "beginSession() must show the overlay")

        // Order is the whole point: clearing after the show still flashes.
        #expect(finalized.lowerBound < show.lowerBound,
                "finalizedTranscript must be cleared BEFORE overlay.show, or the last sentence flashes")
        #expect(volatileRange.lowerBound < show.lowerBound,
                "volatileTranscript must be cleared BEFORE overlay.show, or the last sentence flashes")
    }

    /// Catches the NEXT entry point rather than today's two. A new way to start
    /// dictating that open-codes the preamble would reintroduce the flash
    /// silently; routing every one through beginSession() is what makes the
    /// clear unskippable.
    @Test("only the shared preamble claims the .starting state")
    func onlyPreambleClaimsStarting() throws {
        // Comment lines are stripped first: the doc comment on beginSession()
        // names this assignment in prose, and counting that as a call site made
        // the test fail on its own explanation.
        let code = try Self.appStateSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        var offenders = 0
        var cursor = code.startIndex
        while let hit = code.range(of: "dictation = .starting", range: cursor ..< code.endIndex) {
            offenders += 1
            cursor = hit.upperBound
        }
        #expect(offenders == 1,
                "dictation = .starting is assigned \(offenders) times; every dictation entry point must go through beginSession() so the transcript clear cannot be skipped")
    }
}
