//
//  ChronicleScheduler.swift
//  OmWhisper
//
//  Timer-driven daily trigger for Chronicler.generate(), mirroring
//  MemoryCapture's own pollTimer/pruneTimer + fire-once-at-start() shape.
//  Deliberately separate from Chronicler (pure logic) and MemoryCapture (raw
//  capture/prune) -- this owns the daily trigger only; which backend writes the
//  chronicle is AppState's decision, made when the timer fires.
//
//  @MainActor: a lightweight daily poll, not a real-time path -- matches
//  MemoryCapture's isolation.
//

import Foundation
import os

private let chronicleLog = Logger(subsystem: "com.omwhisper.mac", category: "ChronicleScheduler")

@MainActor
final class ChronicleScheduler {
    private static let interval: TimeInterval = 86_400

    var store: MemoryStore?
    /// Supplied by AppState, which picks a backend at CALL time. This used to be
    /// a `PolishBackend` assigned once when Memory was enabled -- so switching
    /// the polish backend afterwards changed nothing and the nightly chronicle
    /// kept failing against the backend captured at wiring time.
    var generate: ((String) async throws -> Void)?
    var isSuppressed: () -> Bool = { false }

    private var timer: Timer?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.generateIfNeeded() }
        }
        Task { @MainActor in await generateIfNeeded() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func generateIfNeeded() async {
        guard !isSuppressed(), let store, let generate else { return }
        let yesterday = Chronicler.dayString(daysAgo: 1)
        guard (try? store.getChronicle(day: yesterday)) == nil else { return }
        do {
            try await generate(yesterday)
        } catch {
            chronicleLog.error("generateIfNeeded — failed for \(yesterday): \(error)")
        }
    }
}
