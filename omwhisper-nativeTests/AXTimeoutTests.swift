import ApplicationServices
import Foundation
import Testing
@testable import OmWhisper

@Suite("Accessibility messaging timeout")
struct AXTimeoutTests {
    @Test("the timeout is bounded and non-zero")
    func timeoutIsSane() {
        // 0 means "use the default", which is what caused the hang — so zero
        // is not merely unhelpful here, it is the bug.
        #expect(AX.messagingTimeout > 0)
        #expect(AX.messagingTimeout <= 5)
    }

    @Test("an element is refused for our own process")
    func refusesOwnProcess() {
        // The deadlock guard, and the reason it is a guard rather than tidiness:
        // an AX read against ANOTHER app is Mach IPC, bounded by
        // messagingTimeout above. A read against ourselves short-circuits that
        // and runs AppKit's accessibility code inline on the calling thread, so
        // a background thread drives a SwiftUI view-graph update and takes
        // SwiftUI's global update lock while the main thread waits for it in
        // Update.locked. Observed 2026-08-16: MemoryCapture snapshotting the hub
        // window wedged the whole app.
        let own = ProcessInfo.processInfo.processIdentifier
        #expect(AX.appElement(pid: own) == nil)

        // Another process still resolves, or the guard would have disabled every
        // feature that reads another app's UI rather than fixing one of them.
        // pid 1 is launchd — always alive, and its AX tree is never walked here.
        #expect(AX.appElement(pid: 1) != nil)
    }

    @Test("no AX element is created outside the helper")
    func noUnboundedElementCreation() throws {
        // The test that matters, and the only one that can catch the NEXT
        // unbounded call site. On 2026-08-16 two cooperative-pool threads were
        // found blocked forever in _AXXMIGCopyAttributeValue — Mach IPC into
        // apps that never replied — because AXUIElementSetMessagingTimeout was
        // called nowhere in the codebase. A unit test cannot hang a foreign
        // app, so it pins the invariant instead: every element is created
        // through AX, which sets a timeout.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // omwhisper-nativeTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("omwhisper-native")

        let enumerator = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // The helper itself is the one place allowed to call these.
            guard url.lastPathComponent != "AX.swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for symbol in ["AXUIElementCreateApplication", "AXUIElementCreateSystemWide"]
            where text.contains(symbol) {
                offenders.append("\(url.lastPathComponent): \(symbol)")
            }
        }

        #expect(offenders.isEmpty,
                "these create an AX element without a messaging timeout: \(offenders.joined(separator: ", "))")
    }
}
