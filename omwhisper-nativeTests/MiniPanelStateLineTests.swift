import Testing
@testable import OmWhisper

@Suite("miniPanelStateLine")
struct MiniPanelStateLineTests {
    @Test("idle reads Ready")
    func idleReadsReady() {
        #expect(miniPanelStateLine(for: .idle) == "Ready")
    }

    @Test("starting reads Starting")
    func startingReadsStarting() {
        #expect(miniPanelStateLine(for: .starting) == "Starting…")
    }

    @Test("recording reads Listening")
    func recordingReadsListening() {
        #expect(miniPanelStateLine(for: .recording) == "Listening…")
    }

    @Test("finalizing reads Finishing")
    func finalizingReadsFinishing() {
        #expect(miniPanelStateLine(for: .finalizing) == "Finishing…")
    }
}
