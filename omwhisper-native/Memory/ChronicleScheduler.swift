//
//  ChronicleScheduler.swift
//  OmWhisper
//
//  Timer-driven daily trigger for Chronicler.generate(), mirroring
//  MemoryCapture's own pollTimer/pruneTimer + fire-once-at-start() shape.
//  Deliberately separate from Chronicler (pure logic) and MemoryCapture (raw
//  capture/prune) -- this needs a PolishBackend, a different dependency than
//  either of those.
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
    var polish: PolishBackend?
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
        guard !isSuppressed(), let store, let polish else { return }
        let yesterday = Chronicler.dayString(daysAgo: 1)
        guard (try? store.getChronicle(day: yesterday)) == nil else { return }
        do {
            _ = try await Chronicler.generate(day: yesterday, store: store, polish: polish)
        } catch {
            chronicleLog.error("generateIfNeeded — failed for \(yesterday): \(error)")
        }
    }
}
