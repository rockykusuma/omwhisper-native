//
//  SingleInstance.swift
//  OmWhisper
//
//  Refuses to run a second copy of the app. Matching is by bundle ID, not by
//  path, because the case that actually happens is two *copies* of the bundle:
//  a beta tester running the one in ~/Downloads while /Applications' copy sits
//  in the menu bar, or Xcode's Run over an already-installed build. (Finder
//  double-clicks are deduped by LaunchServices already; these are not.)
//
//  Two live instances means two CGEventTaps fighting over one hotkey, two
//  processes grabbing the mic, and two memory/meeting daemons writing the same
//  SQLite files.
//
//  The --mcp subcommand is exempt by construction: main.swift only calls
//  enforce() on the GUI branch. That subprocess is *expected* to run alongside
//  a live app -- Claude Desktop spawns it on demand.
//

import AppKit

nonisolated enum SingleInstance {
    /// Cross-process ping the losing launch sends so the winner surfaces itself.
    /// A menu-bar app that just exits silently reads as "it didn't launch", which
    /// is exactly what makes someone launch it a third time.
    static let openHubNotification = Notification.Name("com.omwhisper.mac.openHub")

    /// First PID in `pids` that isn't us. Split out and tested because getting
    /// the self-exclusion wrong means the app refuses to ever launch again --
    /// a bug that would ship as "the app is broken", not "the guard is subtly off".
    static func otherInstancePID(among pids: [pid_t], myPID: pid_t) -> pid_t? {
        pids.first { $0 != myPID }
    }

    /// PID of an already-running copy of this bundle, if any.
    static func runningInstancePID() -> pid_t? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
        return otherInstancePID(among: pids, myPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Hand off to the copy that's already up, then step aside. No-op when
    /// nothing else is running.
    static func enforce() {
        // The test host IS the app (see isRunningUnderTests in AppState.swift), so
        // without this a suite run while the real app is open would exit itself.
        guard !isRunningUnderTests, let other = runningInstancePID() else { return }

        DistributedNotificationCenter.default().postNotificationName(
            openHubNotification, object: nil, userInfo: nil, deliverImmediately: true)
        NSLog("OmWhisper is already running (pid \(other)) — exiting this launch.")
        exit(0)
    }
}
