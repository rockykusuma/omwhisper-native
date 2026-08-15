//
//  AX.swift
//  OmWhisper
//
//  The one place an AXUIElement is created, so every accessibility read is
//  bounded.
//
//  Every AX read -- AXUIElementCopyAttributeValue and friends -- is SYNCHRONOUS
//  Mach IPC into the target application. If that app does not reply, the call
//  does not return. Until 2026-08-16 nothing in this codebase called
//  AXUIElementSetMessagingTimeout, so an unresponsive app blocked the calling
//  thread indefinitely.
//
//  That was observed, not theorised: a sample of a wedged build found TWO
//  cooperative-pool threads stuck for the whole sample in
//  _AXXMIGCopyAttributeValue -- one under Memory's WindowSnapshotReader.capture,
//  one under meeting detection's BrowserURL.findWebArea. The main thread was
//  healthy and idle the entire time, so nothing looked frozen; what actually
//  happened is that Swift's cooperative pool does NOT spawn replacement threads
//  when its threads block, so async work queued behind them, and both capture
//  loops stopped for good (their in-flight guards skip every later tick).
//
//  Note what did NOT help: both call paths already had time budgets. Those
//  check elapsed time BETWEEN reads and cannot interrupt a read already in
//  flight -- a budget bounds how much work is attempted, never how long one
//  call may hang. Same shape as the MemoryCapture freeze, where a budget said
//  nothing about which thread paid for it.
//

import ApplicationServices
import Foundation

nonisolated enum AX {
    /// Per-call, not per-walk. A responsive app answers an attribute read in
    /// milliseconds; anything approaching a second is already pathological.
    /// The existing deadline checks still bound the total walk, so a single
    /// slow app costs one second and then the walk gives up on its own.
    static let messagingTimeout: Float = 1.0

    /// An application element that cannot hang forever.
    ///
    /// The timeout is also applied to the system-wide element once, because
    /// Apple documents that as the default for elements that carry no timeout
    /// of their own -- and it is not clearly specified whether a timeout set on
    /// an application element is inherited by the child elements a tree walk
    /// obtains from it. Setting both is cheap; guessing wrong is a wedged
    /// thread.
    static func appElement(pid: pid_t) -> AXUIElement {
        installGlobalDefaultOnce()
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func systemWideElement() -> AXUIElement {
        installGlobalDefaultOnce()
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static let installGlobalDefault: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }()

    private static func installGlobalDefaultOnce() { _ = installGlobalDefault }
}
