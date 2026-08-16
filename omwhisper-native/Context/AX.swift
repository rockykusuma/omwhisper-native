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

    /// An application element that cannot hang forever, for any app but our own.
    ///
    /// **nil for our own process, and that is a deadlock guard, not tidiness.**
    /// An AX read against another app is Mach IPC, bounded by the timeout below.
    /// A read against OURSELVES short-circuits that entirely and runs AppKit's
    /// accessibility code *inline on the calling thread* -- so a background
    /// thread ends up driving a SwiftUI view-graph update, taking SwiftUI's
    /// global update lock, and (observed) calling -[NSView setFrameSize:]. The
    /// main thread then blocks forever in Update.locked waiting for that lock.
    ///
    /// Observed 2026-08-16: MemoryCapture, off MainActor since the freeze fix of
    /// 2026-08-02, snapshotted the hub window while it was frontmost and wedged
    /// the whole app. **`messagingTimeout` cannot save this** -- there is no
    /// Mach round trip to time out. Same symptom as the earlier AX hang,
    /// completely different mechanism.
    ///
    /// Refused HERE rather than at the eight call sites because every AX element
    /// in this app is created through this type (pinned by
    /// `AXTimeoutTests.noUnboundedElementCreation`), so this is the one place a
    /// pid-based caller cannot route around. Nothing here has ever wanted to
    /// read our own UI: every caller reads some *other* app the user is working
    /// in. Note the guarantee is **pid-based only** — see `systemWideElement()`,
    /// which has no pid to refuse and is safe today for a different reason.
    ///
    /// The timeout is also applied to the system-wide element once, because
    /// Apple documents that as the default for elements that carry no timeout
    /// of their own -- and it is not clearly specified whether a timeout set on
    /// an application element is inherited by the child elements a tree walk
    /// obtains from it. Setting both is cheap; guessing wrong is a wedged
    /// thread.
    static func appElement(pid: pid_t) -> AXUIElement? {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        installGlobalDefaultOnce()
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// The system-wide element, which **cannot carry the same guarantee** as
    /// `appElement(pid:)`.
    ///
    /// It resolves to whichever app holds focus, so a read of
    /// `kAXFocusedUIElementAttribute` through it lands on US whenever OmWhisper
    /// is frontmost — the exact inline-AppKit path the guard above exists to
    /// prevent — and there is no pid at creation time to refuse.
    ///
    /// Safe today only because its one caller (`ReplyContext.focusedElement`) is
    /// `@MainActor`, where servicing our own accessibility request cannot
    /// deadlock against the main thread. **A `nonisolated` caller would
    /// reintroduce the 2026-08-16 hang with every test still green.** If one is
    /// ever needed, it must either hop to MainActor or check
    /// `NSWorkspace.shared.frontmostApplication` against our own pid first.
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
