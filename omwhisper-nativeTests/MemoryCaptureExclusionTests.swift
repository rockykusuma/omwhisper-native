import Foundation
import GRDB
import Testing
import os
@testable import OmWhisper

@Suite("MemoryCapture domain exclusion")
struct MemoryCaptureExclusionTests {
    @Test("a snapshot with no url is never domain-excluded")
    func noURLNeverExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: nil, excludedDomains: ["example.com"]) == false)
    }

    @Test("an excluded domain is excluded")
    func excludedDomainExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://example.com/page", excludedDomains: ["example.com"]) == true)
    }

    @Test("a subdomain of an excluded domain is excluded")
    func subdomainExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://mail.example.com/inbox", excludedDomains: ["example.com"]) == true)
    }

    @Test("an unrelated domain is not excluded")
    func unrelatedNotExcluded() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://other.com/page", excludedDomains: ["example.com"]) == false)
    }

    @Test("an empty exclusion list excludes nothing")
    func emptyListExcludesNothing() {
        #expect(MemoryCapture.isDomainExcluded(url: "https://example.com/page", excludedDomains: []) == false)
    }
}


@Suite("Memory capture concurrency")
@MainActor
struct MemoryCaptureConcurrencyTests {
    /// A capture that blocks until released, so "a tick arrived while one was
    /// running" is a real state rather than a timing guess.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var callCount: Int { lock.withLock { $0 } }
        func enter() { lock.withLock { $0 += 1 }; semaphore.wait() }
        func release() { semaphore.signal() }
    }


    /// Polls until `condition` holds or the deadline passes. Fixed sleeps are
    /// timing guesses — this suite runs in parallel with 60+ others, so
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

    private func capture(store: MemoryStore) -> MemoryCapture {
        let capture = MemoryCapture()
        capture.store = store
        return capture
    }

    @Test("a tick arriving mid-capture is skipped, and the first still completes")
    func skipsOverlappingTick() async throws {
        let store = try MemoryStore(DatabaseQueue())
        let gate = Gate()
        let subject = capture(store: store)
        subject.performCapture = { _, _, _ in
            gate.enter()
            return MemoryCapture.Outcome(stored: 1, capturedNothing: false)
        }

        subject.tick()                                    // starts, blocks in the gate
        #expect(await waitUntil("capture starts") { subject.isCapturing },
                "first capture never started")

        subject.tick()                                    // must be skipped
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.callCount == 1, "second tick started a concurrent capture")

        gate.release()
        // Asserting only "the second returned early" would pass even if the
        // guard wedged permanently — so check the first finished and cleared.
        #expect(await waitUntil("flag clears") { !subject.isCapturing },
                "flag never cleared after completion")
    }

    @Test("the flag clears after completion, so later ticks run")
    func laterTickRunsAfterCompletion() async throws {
        let store = try MemoryStore(DatabaseQueue())
        let gate = Gate()
        let subject = capture(store: store)
        subject.performCapture = { _, _, _ in
            gate.enter()
            return MemoryCapture.Outcome(stored: 1, capturedNothing: false)
        }

        subject.tick()
        _ = await waitUntil("first capture starts") { subject.isCapturing }
        gate.release()
        #expect(await waitUntil("first completes") { !subject.isCapturing })

        subject.tick()
        #expect(await waitUntil("second capture runs") { gate.callCount == 2 },
                "a later tick did not run")
        gate.release()
        _ = await waitUntil("second completes") { !subject.isCapturing }
    }

    @Test("a capture that produces nothing still clears the flag")
    func flagClearsAfterEmptyCapture() async throws {
        // Without this, one failure stops capture forever — silently, which is
        // exactly the failure mode this codebase keeps paying for.
        let store = try MemoryStore(DatabaseQueue())
        let subject = capture(store: store)
        subject.performCapture = { _, _, _ in
            MemoryCapture.Outcome(stored: 0, capturedNothing: true)
        }

        subject.tick()
        #expect(await waitUntil("flag clears after a failing capture") { !subject.isCapturing },
                "flag stuck after a failing capture")
    }
}
