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

private let memoryLog = Logger(subsystem: "com.omwhisper.mac", category: "MemoryCapture")

@MainActor
final class MemoryCapture {
    static let maxContentLength = 20_000
    private static let pruneInterval: TimeInterval = 86_400

    var store: MemoryStore?
    var isSuppressed: () -> Bool = { false }
    var captureIntervalSeconds: TimeInterval = 5
    var retentionDays: Int = 90
    var excludedDomains: [String] = []

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

    private func tick() {
        guard !isSuppressed(), let store else { return }
        // Silent nil here is the #1 reason "nothing was captured" -- most often a
        // missing Accessibility grant (captureFrontmost can't read other apps'
        // AX trees), which produces no error, just nil. Log it so the daemon is
        // observable (`log stream --predicate 'category == "MemoryCapture"'`).
        guard let snapshot = WindowSnapshotReader.captureFrontmost() else {
            memoryLog.debug("tick — no snapshot (no focused window, excluded, empty text, or missing Accessibility permission)")
            return
        }
        guard !Self.isDomainExcluded(url: snapshot.url, excludedDomains: excludedDomains) else {
            memoryLog.debug("tick — skipped excluded domain")
            return
        }

        let content = String(snapshot.content.prefix(Self.maxContentLength))
        do {
            try store.upsert(
                appName: snapshot.appName, bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle,
                content: content, url: snapshot.url ?? ""
            )
            memoryLog.debug("tick — captured \(snapshot.appName, privacy: .public)")
        } catch {
            memoryLog.error("tick — upsert failed: \(error)")
        }
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
