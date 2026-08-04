import Foundation
import Testing
import os
@testable import OmWhisper

@Suite("Meeting detection concurrency")
@MainActor
struct MeetingWatcherConcurrencyTests {
    /// A detection sweep that blocks until released, so "a tick arrived while
    /// one was running" is a real state rather than a timing guess.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var callCount: Int { lock.withLock { $0 } }
        func enter() { lock.withLock { $0 += 1 }; semaphore.wait() }
        func release() { semaphore.signal() }
    }

    /// Polls until `condition` holds or the deadline passes. Fixed sleeps are
    /// timing guesses -- this suite runs in parallel with 68 others, so
    /// MainActor contention makes any single duration wrong sometimes.
    private func waitUntil(
        _ description: String, timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("a tick arriving during a sweep is skipped, and the first still finishes")
    func overlappingTickIsSkipped() async throws {
        let gate = Gate()
        let watcher = MeetingWatcher()
        watcher.performDetection = { gate.enter(); return nil }

        watcher.startForTesting()
        #expect(await waitUntil("sweep starts") { watcher.isDetecting },
                "first sweep never started")

        watcher.startForTesting()                          // must be skipped
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.callCount == 1, "second tick started a concurrent sweep")

        gate.release()
        // Asserting only "the second returned early" would pass even if the
        // guard wedged permanently -- so check the first finished and cleared.
        #expect(await waitUntil("flag clears") { !watcher.isDetecting },
                "flag never cleared after completion")
    }

    @Test("the flag clears after completion, so later ticks run")
    func laterTickRunsAfterCompletion() async throws {
        let gate = Gate()
        let watcher = MeetingWatcher()
        watcher.performDetection = { gate.enter(); return nil }

        watcher.startForTesting()
        #expect(await waitUntil("first sweep starts") { watcher.isDetecting })
        gate.release()
        #expect(await waitUntil("first sweep ends") { !watcher.isDetecting })

        watcher.startForTesting()
        #expect(await waitUntil("second sweep starts") { watcher.isDetecting },
                "a later tick was blocked by a stale in-flight flag")
        gate.release()
        #expect(await waitUntil("second sweep ends") { !watcher.isDetecting })
    }

    @Test("a detected call advances the state machine off the sweep")
    func detectionReachesTheStateMachine() async {
        // The guard tests above would both pass if apply() were never called at
        // all -- they only watch a flag. This one proves the sweep's RESULT
        // reaches the state machine, which is the point of the hop back.
        let watcher = MeetingWatcher()
        watcher.performDetection = { MeetingWatcher.DetectedCall(name: "Teams", pid: 4242) }

        watcher.startForTesting()
        #expect(await waitUntil("state advances") { watcher.state == .detecting },
                "detection never reached the state machine")
    }
}
