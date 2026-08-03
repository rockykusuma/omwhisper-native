//
//  MemoryCapture.swift
//  OmWhisper
//
//  Timer-driven background capture daemon, modeled directly on
//  MeetingWatcher's poll pattern (Timer.scheduledTimer, isSuppressed
//  closure, start()/stop() shape) -- NOT smriti's SIGUSR1 signal handler,
//  which is a workaround for smriti running as a separate launchd CLI
//  daemon with no other IPC channel. This app is a normal in-process
//  menu-bar app; pause is just a settings-backed flag isSuppressed reads.
//
//  Exclusions are checked before any write is attempted: bundle ID and
//  title exclusion happen inside WindowSnapshotReader.captureFrontmost()
//  (reusing ScreenContextReader.isExcluded), domain exclusion happens here
//  in tick() before store.upsert(...) is ever called.
//
//  @MainActor: a lightweight poll, not a real-time audio path -- matches
//  MeetingWatcher's isolation, not AudioCapture's nonisolated+lock pattern.
//

import Foundation
import os

private nonisolated let memoryLog = Logger(subsystem: "com.omwhisper.mac", category: "MemoryCapture")

@MainActor
final class MemoryCapture {
    nonisolated static let maxContentLength = 20_000
    private static let pruneInterval: TimeInterval = 86_400

    var store: MemoryStore?
    var isSuppressed: () -> Bool = { false }
    /// Fired after a snapshot is written, so the semantic indexer can catch up.
    /// A no-op by default, matching the other injected collaborators here.
    var onSnapshotStored: () -> Void = {}
    var captureIntervalSeconds: TimeInterval = 5
    var retentionDays: Int = 90
    var excludedDomains: [String] = []
    /// Fired when a tick captured nothing, so AppState can escalate. A no-op by
    /// default, matching the other injected collaborators here.
    var onDegradation: () -> Void = {}
    /// The user's app / window-title exclusions. Checked before the text walk,
    /// unlike excludedDomains above, which needs a URL and so runs after.
    var exclusions: MemoryExclusions = .none

    /// What one capture pass produced. Crosses the actor boundary, so it is a
    /// plain value type rather than anything referencing the store.
    nonisolated struct Outcome: Equatable {
        let stored: Int
        let capturedNothing: Bool
    }

    /// The capture pass itself. Injectable so the in-flight guard can be tested
    /// without real windows — the same collaborator-closure style as
    /// `isSuppressed` and `onSnapshotStored` above.
    nonisolated(unsafe) var performCapture: @Sendable (MemoryStore, MemoryExclusions, [String]) -> Outcome
        = { store, exclusions, domains in
            MemoryCapture.captureAndStore(store: store, exclusions: exclusions, excludedDomains: domains)
        }

    /// True while a capture is running. MainActor-isolated: set in `tick()` and
    /// cleared in the MainActor continuation, so there is no race and no lock.
    private(set) var isCapturing = false

    private var pollTimer: Timer?
    private var pruneTimer: Timer?

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: captureIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneNow() }
        }
        pruneNow()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    /// Pure: true when `url`'s domain matches (exactly or as a subdomain of)
    /// any entry in `excludedDomains`. A snapshot with no url is never
    /// domain-excluded -- non-browser apps have no url to check at all.
    nonisolated static func isDomainExcluded(url: String?, excludedDomains: [String]) -> Bool {
        guard let url, let domain = BrowserURL.domain(of: url) else { return false }
        return excludedDomains.contains { BrowserURL.domain(domain, matches: $0) }
    }

    /// MainActor: reads settings and dispatches. Does NO accessibility work
    /// itself — that used to block the main thread for up to 3s of every 5s
    /// poll, starving GlobalHotkey's monitors, push-to-talk and the UI, which
    /// all run here. The freeze looked like broken shortcuts.
    func tick() {
        guard !isSuppressed(), let store else { return }
        // The main-thread block used to serialise ticks by accident. Off-thread,
        // a slow tick would overlap the next one and stack concurrent AX sweeps.
        guard !isCapturing else {
            memoryLog.debug("tick — skipped, previous capture still running")
            return
        }
        isCapturing = true
        let exclusionsSnapshot = exclusions
        let domainsSnapshot = excludedDomains
        let capture = performCapture

        Task.detached(priority: .utility) { [weak self] in
            let outcome = capture(store, exclusionsSnapshot, domainsSnapshot)
            await MainActor.run {
                guard let self else { return }
                // Cleared FIRST and unconditionally: if this only ran on the
                // happy path, one failure would stop capture forever.
                self.isCapturing = false
                self.finish(outcome)
            }
        }
    }

    /// MainActor: the collaborator callbacks and Degradation, which is
    /// @MainActor and must not be touched from the background path.
    private func finish(_ outcome: Outcome) {
        if outcome.capturedNothing {
            memoryLog.debug("tick — no snapshots (no focused window, excluded, empty text, or missing Accessibility permission)")
            Degradation.record(.memoryCapture, reason: "nothing captured — check Accessibility permission")
            onDegradation()
            return
        }
        // Let the semantic indexer catch up. It works from "snapshots with no
        // passages yet", so this is just a nudge -- the same code path that
        // backfills, which means a missed nudge self-heals rather than leaving a
        // permanently unindexed snapshot.
        if outcome.stored > 0 {
            onSnapshotStored()
            Degradation.recordSuccess(.memoryCapture)
        }
    }

    /// The accessibility walk and the store writes. `nonisolated` and static so
    /// it cannot accidentally touch MainActor state — everything it uses
    /// (WindowSnapshotReader, MemoryStore) is already nonisolated by design.
    nonisolated static func captureAndStore(
        store: MemoryStore, exclusions: MemoryExclusions, excludedDomains: [String]
    ) -> Outcome {
        let snapshots = WindowSnapshotReader.captureVisible(exclusions: exclusions)
        guard !snapshots.isEmpty else { return Outcome(stored: 0, capturedNothing: true) }

        var stored = 0
        for snapshot in snapshots {
            // Per window, never per tick: a password manager or excluded domain on
            // the second display must be filtered independently of the first.
            guard !isDomainExcluded(url: snapshot.url, excludedDomains: excludedDomains) else {
                memoryLog.debug("tick — skipped excluded domain")
                continue
            }
            let content = String(snapshot.content.prefix(maxContentLength))
            do {
                try store.upsert(
                    appName: snapshot.appName, bundleID: snapshot.bundleID,
                    windowTitle: snapshot.windowTitle, content: content, url: snapshot.url ?? ""
                )
                stored += 1
                memoryLog.debug("tick — captured \(snapshot.appName, privacy: .public)")
            } catch {
                memoryLog.error("tick — upsert failed: \(error)")
            }
        }
        return Outcome(stored: stored, capturedNothing: false)
    }

    private func pruneNow() {
        guard let store else { return }
        do {
            try store.prune(olderThanDays: retentionDays)
        } catch {
            memoryLog.error("pruneNow — failed: \(error)")
        }
    }
}
