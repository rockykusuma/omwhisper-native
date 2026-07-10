# M4.2 — CloudEngine (AssemblyAI streaming) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third `TranscriptionEngine` backed by AssemblyAI's Universal Streaming WebSocket API, selectable from the Transcription Settings tab, with the API key stored in Keychain (never `UserDefaults`) and S2's auto-extracted screen terms excluded from what's sent to the cloud.

**Architecture:** `Keychain.swift` (new, generic Security-framework wrapper scoped to one named item) → `CloudEngine.swift` (new, a stateless `struct` conforming to `TranscriptionEngine`, mirroring `AppleEngine`'s shape — pure keyterm-capping/URL-building/message-parsing helpers, wired into an effectful `transcribe()` that opens a `URLSessionWebSocketTask`) → `AppState` wiring (`activeEngine`'s `.cloud` case, a pure `mergeEngineVocabulary` helper replacing the inline screen-term merge) → `TranscriptionSettingsView.swift` extension (enable the Cloud radio row, add the API key UI).

**Tech Stack:** Swift 6, `URLSessionWebSocketTask` (Foundation, native — no new SPM dependency), Security framework (native Keychain), Swift Testing.

## Global Constraints

- `CloudEngine` is a stateless `struct` — no persistent connection or loaded state kept between dictation sessions, unlike `ParakeetEngine`.
- No new SPM dependency — `URLSessionWebSocketTask` handles the WebSocket; `Keychain.swift` wraps the native Security framework.
- The API key never touches `UserDefaults` or any other plaintext storage — Keychain only, read fresh each time `CloudEngine.transcribe()` is called.
- Every WebSocket connection uses AssemblyAI's ephemeral-token flow (`GET https://streaming.assemblyai.com/v3/token`), never the permanent key directly on the streaming connection.
- When `engineKind == .cloud`, S2's auto-extracted screen terms are excluded from the vocabulary sent as keyterms — only the user's own explicitly-configured `customVocabulary` goes to the cloud provider. This is conditional on the active engine, not a global change to vocabulary handling for Apple/Parakeet.
- Keyterms sent to AssemblyAI are capped at the provider's own documented limits: 100 terms max, each truncated to 50 characters — a hard external constraint, not a design choice of this app's.
- Cloud must never be silently selectable without the warning copy being visible in the same view as the radio button.
- New declarations in this project default to `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — anything that must run off MainActor (transcription work, Keychain I/O, WebSocket handling) needs an explicit `nonisolated`, matching `AppleEngine`/`ParakeetEngine`'s established pattern.
- `AVAudioPCMBuffer`/`AVAudioFormat`/`AVAudioConverter` aren't `Sendable` — files that touch them import `AVFoundation` with `@preconcurrency`, matching `AppleEngine.swift`/`BufferConverter.swift`.

## Reference: verified AssemblyAI API details (fetched live, not assumed)

- **Token endpoint:** `GET https://streaming.assemblyai.com/v3/token?expires_in_seconds=60`, header `Authorization: Bearer <permanent-api-key>` (this one endpoint *does* use the `Bearer` prefix). Response: `{"token": "...", "expires_in_seconds": 60}`.
- **WebSocket URL:** `wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&encoding=pcm_s16le&format_turns=true[&keyterms_prompt=<JSON array>]`. Connect with header `Authorization: <ephemeral-token>` (no `Bearer` prefix on this one).
- **Audio:** binary WebSocket frames of raw `pcm_s16le` mono samples at 16kHz.
- **Turn message (received):** `{"type": "Turn", "end_of_turn": bool, "transcript": "...", ...}` — `end_of_turn` maps to `.final`/`.partial` directly.
- **Session end:** send `{"type": "Terminate"}` as a text frame; server replies with `{"type": "Termination", ...}` before closing.
- **Keyterms:** `keyterms_prompt` query param, JSON-encoded array of strings, max 100 terms, 50 chars each (over-length terms are server-ignored; this app truncates instead of dropping, per the design spec).

## Task 1: Keychain wrapper

**Files:**
- Create: `omwhisper-native/Transcription/Keychain.swift`
- Test: `omwhisper-nativeTests/KeychainTests.swift`

**Interfaces:**
- Produces: `enum Keychain { static func loadAssemblyAIKey() -> String?; static func saveAssemblyAIKey(_ key: String) throws; static func deleteAssemblyAIKey() throws }` — used by `CloudEngine.swift` (Task 3) and `TranscriptionSettingsView.swift` (Task 5).

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/KeychainTests.swift`:

```swift
import Testing
@testable import OmWhisper

@Suite("Keychain", .serialized)
struct KeychainTests {
    init() throws {
        try? Keychain.deleteAssemblyAIKey()
    }

    @Test("round-trips a saved key")
    func roundTrip() throws {
        try Keychain.saveAssemblyAIKey("test-key-123")
        #expect(Keychain.loadAssemblyAIKey() == "test-key-123")
        try Keychain.deleteAssemblyAIKey()
    }

    @Test("load returns nil when nothing is saved")
    func loadWhenEmpty() {
        #expect(Keychain.loadAssemblyAIKey() == nil)
    }

    @Test("save overwrites an existing key")
    func overwrite() throws {
        try Keychain.saveAssemblyAIKey("first")
        try Keychain.saveAssemblyAIKey("second")
        #expect(Keychain.loadAssemblyAIKey() == "second")
        try Keychain.deleteAssemblyAIKey()
    }

    @Test("delete is a no-op when nothing is saved")
    func deleteWhenEmpty() throws {
        try Keychain.deleteAssemblyAIKey()
    }
}
```

`.serialized` on the suite prevents the four tests (which all share the one Keychain item) from racing each other under Swift Testing's default parallel execution.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/KeychainTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — "Cannot find 'Keychain' in scope"

- [ ] **Step 3: Write the implementation**

Create `omwhisper-native/Transcription/Keychain.swift`:

```swift
//
//  Keychain.swift
//  OmWhisper
//
//  Minimal wrapper over the Security framework, scoped to exactly one named
//  generic-password item: the user's AssemblyAI API key (CloudEngine, M4.2).
//  The API key must never touch UserDefaults or any other plaintext store.
//

import Foundation
import Security

nonisolated enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.omwhisper.mac"
    private static let assemblyAIAccount = "assemblyai-api-key"

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let status): return "Couldn't access the Keychain (status \(status))."
            }
        }
    }

    static func loadAssemblyAIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAssemblyAIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount,
        ]
        if loadAssemblyAIKey() != nil {
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        } else {
            var attributes = query
            attributes[kSecValueData as String] = data
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        }
    }

    static func deleteAssemblyAIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/KeychainTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS (4/4)

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Transcription/Keychain.swift omwhisper-nativeTests/KeychainTests.swift
git commit -m "feat(cloud): add Keychain wrapper for the AssemblyAI API key"
```

## Task 2: CloudEngine pure helpers

**Files:**
- Create: `omwhisper-native/Transcription/CloudEngine.swift` (helpers + `EngineError` + `kind` only in this task — `transcribe()` body is a stub that throws `EngineError.missingAPIKey` unconditionally, replaced for real in Task 3)
- Test: `omwhisper-nativeTests/CloudEngineTests.swift`

**Interfaces:**
- Consumes: `TranscriptionEngine` protocol, `TranscriptEvent`/`EngineKind` (`omwhisper-native/Transcription/TranscriptionEngine.swift`).
- Produces: `struct CloudEngine: TranscriptionEngine` with `static func cappedKeyterms(_ vocabulary: [String]) -> [String]`, `static func connectionURL(keyterms: [String]) -> URL`, `static func parseServerMessage(_ data: Data) -> TranscriptEvent?` — all used internally by Task 3's `transcribe()` and directly by this task's tests.

- [ ] **Step 1: Write the failing tests**

Create `omwhisper-nativeTests/CloudEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import OmWhisper

@Suite("CloudEngine")
struct CloudEngineTests {
    @Test("keeps vocabulary under the 100-term cap")
    func capsTermCount() {
        let vocabulary = (1...150).map { "term\($0)" }
        #expect(CloudEngine.cappedKeyterms(vocabulary).count == 100)
    }

    @Test("truncates a term longer than 50 characters")
    func truncatesLongTerm() {
        let longTerm = String(repeating: "a", count: 80)
        let result = CloudEngine.cappedKeyterms([longTerm])
        #expect(result == [String(repeating: "a", count: 50)])
    }

    @Test("passes short terms through unchanged")
    func passesShortTermsThrough() {
        #expect(CloudEngine.cappedKeyterms(["OmWhisper", "Parakeet"]) == ["OmWhisper", "Parakeet"])
    }

    @Test("empty vocabulary produces an empty list")
    func emptyVocabulary() {
        #expect(CloudEngine.cappedKeyterms([]) == [])
    }

    @Test("connection URL always carries sample_rate, encoding, and format_turns")
    func connectionURLBaseParams() {
        let url = CloudEngine.connectionURL(keyterms: [])
        let query = url.query ?? ""
        #expect(url.absoluteString.hasPrefix("wss://streaming.assemblyai.com/v3/ws?"))
        #expect(query.contains("sample_rate=16000"))
        #expect(query.contains("encoding=pcm_s16le"))
        #expect(query.contains("format_turns=true"))
        #expect(!query.contains("keyterms_prompt"))
    }

    @Test("connection URL includes keyterms_prompt as a JSON array when non-empty")
    func connectionURLWithKeyterms() {
        let url = CloudEngine.connectionURL(keyterms: ["OmWhisper", "Parakeet"])
        let query = url.query ?? ""
        #expect(query.contains("keyterms_prompt="))
        #expect(query.contains("OmWhisper"))
        #expect(query.contains("Parakeet"))
    }

    @Test("a Turn message with end_of_turn true maps to .final")
    func finalTurnMapsToFinal() {
        let json = """
        {"type": "Turn", "end_of_turn": true, "transcript": "hello world"}
        """
        let data = Data(json.utf8)
        #expect(CloudEngine.parseServerMessage(data) == .final("hello world"))
    }

    @Test("a Turn message with end_of_turn false maps to .partial")
    func partialTurnMapsToPartial() {
        let json = """
        {"type": "Turn", "end_of_turn": false, "transcript": "hello wor"}
        """
        let data = Data(json.utf8)
        #expect(CloudEngine.parseServerMessage(data) == .partial("hello wor"))
    }

    @Test("a Begin message produces no event")
    func beginMessageProducesNoEvent() {
        let json = """
        {"type": "Begin", "id": "abc-123", "expires_at": 1234567890}
        """
        let data = Data(json.utf8)
        #expect(CloudEngine.parseServerMessage(data) == nil)
    }

    @Test("a Termination message produces no event")
    func terminationMessageProducesNoEvent() {
        let json = """
        {"type": "Termination", "audio_duration_seconds": 12, "session_duration_seconds": 13}
        """
        let data = Data(json.utf8)
        #expect(CloudEngine.parseServerMessage(data) == nil)
    }

    @Test("malformed JSON produces no event")
    func malformedJSONProducesNoEvent() {
        let data = Data("not json".utf8)
        #expect(CloudEngine.parseServerMessage(data) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/CloudEngineTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — "Cannot find 'CloudEngine' in scope"

- [ ] **Step 3: Write the implementation (helpers + stub transcribe)**

Create `omwhisper-native/Transcription/CloudEngine.swift`:

```swift
//
//  CloudEngine.swift
//  OmWhisper
//
//  Third TranscriptionEngine backend: AssemblyAI Universal Streaming over a
//  WebSocket. Stateless like AppleEngine -- a streaming connection has no
//  warm-up cost worth persisting across dictation sessions, unlike
//  ParakeetEngine's CoreML model load. API details verified live against
//  AssemblyAI's docs -- see docs/superpowers/plans/2026-07-10-m4-2-cloud-engine.md.
//

// @preconcurrency: AVAudioPCMBuffer/AVAudioConverter aren't Sendable; see the
// note in AppleEngine.swift/BufferConverter.swift.
@preconcurrency import AVFoundation
import Foundation

struct CloudEngine: TranscriptionEngine {
    let kind: EngineKind = .cloud

    enum EngineError: Error, LocalizedError {
        case missingAPIKey
        case tokenRequestFailed
        case connectionFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "Add your AssemblyAI API key in Settings → Transcription to use Cloud."
            case .tokenRequestFailed: "Couldn't authenticate with AssemblyAI."
            case .connectionFailed: "Couldn't connect to AssemblyAI."
            }
        }
    }

    private static let sampleRate = 16000

    // MARK: Pure helpers (unit-tested directly, no network involved)

    /// AssemblyAI's own documented limits: 100 keyterms max, 50 chars each.
    /// Over-length terms are silently ignored server-side -- truncating here
    /// keeps them usable rather than dropping the whole term.
    nonisolated static func cappedKeyterms(_ vocabulary: [String]) -> [String] {
        vocabulary.prefix(100).map { String($0.prefix(50)) }
    }

    nonisolated static func connectionURL(keyterms: [String]) -> URL {
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
        ]
        if !keyterms.isEmpty,
           let data = try? JSONEncoder().encode(keyterms),
           let json = String(data: data, encoding: .utf8) {
            components.queryItems?.append(URLQueryItem(name: "keyterms_prompt", value: json))
        }
        return components.url!
    }

    private struct TurnMessage: Decodable {
        let type: String
        let endOfTurn: Bool?
        let transcript: String?

        enum CodingKeys: String, CodingKey {
            case type
            case endOfTurn = "end_of_turn"
            case transcript
        }
    }

    /// nil for every server message type this engine doesn't act on
    /// (Begin/SpeechStarted/Termination/SpeakerRevision/etc) or malformed JSON.
    nonisolated static func parseServerMessage(_ data: Data) -> TranscriptEvent? {
        guard let turn = try? JSONDecoder().decode(TurnMessage.self, from: data),
              turn.type == "Turn", let transcript = turn.transcript else { return nil }
        return (turn.endOfTurn ?? false) ? .final(transcript) : .partial(transcript)
    }

    // MARK: TranscriptionEngine

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        continuation.finish(throwing: EngineError.missingAPIKey)
        return stream
    }
}
```

This stub compiles and lets Task 2's tests pass in isolation; Task 3 replaces the `transcribe()` body with the real WebSocket implementation.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/CloudEngineTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS (11/11)

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Transcription/CloudEngine.swift omwhisper-nativeTests/CloudEngineTests.swift
git commit -m "feat(cloud): add CloudEngine pure helpers (keyterm capping, URL building, Turn parsing)"
```

## Task 3: CloudEngine WebSocket implementation

**Files:**
- Modify: `omwhisper-native/Transcription/CloudEngine.swift` (replace the stub `transcribe()` body)

**Interfaces:**
- Consumes: `Keychain.loadAssemblyAIKey()` (Task 1); `CloudEngine.cappedKeyterms`/`connectionURL`/`parseServerMessage` (Task 2); `BufferConverter.convertBuffer(_:to:)` (`omwhisper-native/Transcription/BufferConverter.swift`, existing).
- Produces: the real `transcribe()` behavior other tasks and live testing depend on. No new unit tests -- per the design spec's Testing section, live WebSocket/network behavior isn't unit-testable (no AssemblyAI sandbox/mock); this task is verified by a clean build plus later live testing (Task 6).

- [ ] **Step 1: Replace the stub `transcribe()` with the real implementation**

In `omwhisper-native/Transcription/CloudEngine.swift`, replace:

```swift
    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        continuation.finish(throwing: EngineError.missingAPIKey)
        return stream
    }
```

with:

```swift
    private struct TokenResponse: Decodable {
        let token: String
    }

    nonisolated private static func requestEphemeralToken(apiKey: String) async throws -> String {
        var components = URLComponents(string: "https://streaming.assemblyai.com/v3/token")!
        components.queryItems = [URLQueryItem(name: "expires_in_seconds", value: "60")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw EngineError.tokenRequestFailed
        }
        return decoded.token
    }

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()

        let task = Task {
            do {
                guard let apiKey = Keychain.loadAssemblyAIKey(), !apiKey.isEmpty else {
                    throw EngineError.missingAPIKey
                }
                let token = try await Self.requestEphemeralToken(apiKey: apiKey)
                let keyterms = Self.cappedKeyterms(vocabulary)
                let url = Self.connectionURL(keyterms: keyterms)

                guard let pcmFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(Self.sampleRate),
                    channels: 1,
                    interleaved: true
                ) else {
                    throw EngineError.connectionFailed
                }

                var request = URLRequest(url: url)
                request.setValue(token, forHTTPHeaderField: "Authorization")
                let urlSession = URLSession(configuration: .default)
                let socket = urlSession.webSocketTask(with: request)
                socket.resume()

                // Drains Turn messages concurrently with feeding audio in below --
                // mirrors AppleEngine's resultsTask/audio-feed split.
                let receiveTask = Task {
                    while true {
                        guard let message = try? await socket.receive() else { return }
                        switch message {
                        case .data(let data):
                            if let event = Self.parseServerMessage(data) {
                                continuation.yield(event)
                            }
                        case .string(let text):
                            if let data = text.data(using: .utf8), let event = Self.parseServerMessage(data) {
                                continuation.yield(event)
                            }
                        @unknown default:
                            break
                        }
                    }
                }

                let converter = BufferConverter()
                for await buffer in audio {
                    guard let converted = try? converter.convertBuffer(buffer, to: pcmFormat),
                          let channelData = converted.int16ChannelData else { continue }
                    let frameCount = Int(converted.frameLength)
                    let bytes = Data(bytes: channelData[0], count: frameCount * MemoryLayout<Int16>.size)
                    try? await socket.send(.data(bytes))
                }

                // Mic stream ended (recording stopped) -- tell AssemblyAI to close out
                // the session so the last Turn settles into a final one, mirroring
                // AppleEngine's finalizeAndFinishThroughEndOfInput() flush.
                if let terminateJSON = String(data: try JSONEncoder().encode(["type": "Terminate"]), encoding: .utf8) {
                    try? await socket.send(.string(terminateJSON))
                }
                // ponytail: fixed 1s wait for the final Turn + Termination to arrive
                // rather than awaiting the Termination message specifically -- revisit
                // if live testing shows the last words getting cut off.
                try? await Task.sleep(for: .seconds(1))
                receiveTask.cancel()
                socket.cancel(with: .normalClosure, reason: nil)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Run the full test suite to confirm nothing regressed**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: all tests pass (existing count + the 4 Keychain + 11 CloudEngine tests from Tasks 1-2)

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/Transcription/CloudEngine.swift
git commit -m "feat(cloud): implement CloudEngine's WebSocket streaming transcribe()"
```

## Task 4: AppState wiring (activeEngine + vocabulary exclusion)

**Files:**
- Modify: `omwhisper-native/Vocabulary/VocabularyProcessing.swift` (add `mergeEngineVocabulary`)
- Modify: `omwhisper-nativeTests/VocabularyProcessingTests.swift` (add tests)
- Modify: `omwhisper-native/AppState.swift` (wire `.cloud` into `activeEngine`; replace the inline screen-term merge with `mergeEngineVocabulary`)

**Interfaces:**
- Consumes: `EngineKind` (`TranscriptionEngine.swift`); `CloudEngine()` (Task 3).
- Produces: `nonisolated func mergeEngineVocabulary(customTerms: [String], screenTerms: [String], engineKind: EngineKind) -> [String]`, used at `AppState.swift`'s `engineVocabulary` call site.

- [ ] **Step 1: Write the failing tests**

Add to `omwhisper-nativeTests/VocabularyProcessingTests.swift` (append a new `struct` after the existing ones -- open the file first to confirm exact insertion point, then add):

```swift
struct EngineVocabularyMergeTests {
    @Test func appleEngineMergesScreenTermsNotAlreadyPresent() {
        let result = mergeEngineVocabulary(
            customTerms: ["OmWhisper"],
            screenTerms: ["Xcode", "OmWhisper"],
            engineKind: .apple
        )
        #expect(result == ["OmWhisper", "Xcode"])
    }

    @Test func parakeetEngineAlsoMergesScreenTerms() {
        let result = mergeEngineVocabulary(
            customTerms: ["Parakeet"],
            screenTerms: ["FluidAudio"],
            engineKind: .parakeet
        )
        #expect(result == ["Parakeet", "FluidAudio"])
    }

    @Test func cloudEngineExcludesScreenTermsEntirely() {
        let result = mergeEngineVocabulary(
            customTerms: ["OmWhisper"],
            screenTerms: ["Xcode", "SecretProjectName"],
            engineKind: .cloud
        )
        #expect(result == ["OmWhisper"])
    }

    @Test func cloudEngineWithNoCustomTermsSendsNothing() {
        let result = mergeEngineVocabulary(
            customTerms: [],
            screenTerms: ["Xcode"],
            engineKind: .cloud
        )
        #expect(result.isEmpty)
    }

    @Test func caseInsensitiveDedupeStillAppliesForNonCloudEngines() {
        let result = mergeEngineVocabulary(
            customTerms: ["OmWhisper"],
            screenTerms: ["omwhisper", "Xcode"],
            engineKind: .apple
        )
        #expect(result == ["OmWhisper", "Xcode"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/EngineVocabularyMergeTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — "Cannot find 'mergeEngineVocabulary' in scope"

- [ ] **Step 3: Implement `mergeEngineVocabulary`**

In `omwhisper-native/Vocabulary/VocabularyProcessing.swift`, add after `fuzzyCorrect` (before the `private` helper functions at the bottom):

```swift
/// Assembles the vocabulary handed to a TranscriptionEngine for biasing.
/// Apple/Parakeet get the user's custom terms plus S2's auto-extracted
/// screen terms (deduped case-insensitively); Cloud gets only the user's
/// own explicitly-typed terms -- screen terms were never reviewed or
/// approved by the user, and shouldn't leave the device just because
/// Cloud was selected. See docs/superpowers/specs/2026-07-09-m4-2-cloud-engine-design.md.
nonisolated func mergeEngineVocabulary(customTerms: [String], screenTerms: [String], engineKind: EngineKind) -> [String] {
    guard engineKind != .cloud else { return customTerms }
    return customTerms + screenTerms.filter { term in
        !customTerms.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' -only-testing:omwhisper-nativeTests/EngineVocabularyMergeTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS (5/5)

- [ ] **Step 5: Wire `activeEngine`'s `.cloud` case**

In `omwhisper-native/AppState.swift`, find (around line 361-371):

```swift
    // MARK: Core loop collaborators
    private let audioCapture = AudioCapture()
    private let appleEngine: TranscriptionEngine = AppleEngine()
    let parakeetEngine = ParakeetEngine()
    private var activeEngine: TranscriptionEngine {
        switch engineKind {
        case .apple: appleEngine
        case .parakeet: parakeetEngine
        case .cloud: appleEngine  // M4.2 not shipped yet; falls back silently
        }
    }
```

Replace with:

```swift
    // MARK: Core loop collaborators
    private let audioCapture = AudioCapture()
    private let appleEngine: TranscriptionEngine = AppleEngine()
    let parakeetEngine = ParakeetEngine()
    private let cloudEngine: TranscriptionEngine = CloudEngine()
    private var activeEngine: TranscriptionEngine {
        switch engineKind {
        case .apple: appleEngine
        case .parakeet: parakeetEngine
        case .cloud: cloudEngine
        }
    }
```

- [ ] **Step 6: Replace the inline screen-term merge with `mergeEngineVocabulary`**

In `omwhisper-native/AppState.swift`, find (around line 663-671):

```swift
            // Screen-extracted terms (S2) feed engine biasing only — never
            // vocabSnapshot itself, which also doubles as fuzzyCorrect's
            // post-hoc snap-to-nearest-term dictionary below. Mixing noisy
            // auto-extracted terms into that harder rewrite is a different
            // risk profile than soft engine biasing.
            let screenTerms = await contextCaptureTask?.value ?? []
            let engineVocabulary = vocabSnapshot + screenTerms.filter { term in
                !vocabSnapshot.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
            }
```

Replace with:

```swift
            // Screen-extracted terms (S2) feed engine biasing only — never
            // vocabSnapshot itself, which also doubles as fuzzyCorrect's
            // post-hoc snap-to-nearest-term dictionary below. Mixing noisy
            // auto-extracted terms into that harder rewrite is a different
            // risk profile than soft engine biasing. Cloud excludes screen
            // terms entirely -- see mergeEngineVocabulary.
            let screenTerms = await contextCaptureTask?.value ?? []
            let engineVocabulary = mergeEngineVocabulary(
                customTerms: vocabSnapshot,
                screenTerms: screenTerms,
                engineKind: engineKind
            )
            if engineKind == .cloud, !screenTerms.isEmpty {
                log.debug("cloud engine active: excluding \(screenTerms.count) screen term(s) from vocabulary")
            }
```

- [ ] **Step 7: Build and run the full test suite**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED, all tests pass

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/Vocabulary/VocabularyProcessing.swift omwhisper-nativeTests/VocabularyProcessingTests.swift omwhisper-native/AppState.swift
git commit -m "feat(cloud): wire CloudEngine into activeEngine, exclude screen terms from cloud vocabulary"
```

## Task 5: Transcription Settings UI

**Files:**
- Modify: `omwhisper-native/UI/TranscriptionSettingsView.swift`

**Interfaces:**
- Consumes: `Keychain.loadAssemblyAIKey()/saveAssemblyAIKey(_:)/deleteAssemblyAIKey()` (Task 1); `AppState.engineKind` (existing).

- [ ] **Step 1: Enable the Cloud radio row and add the API key section**

Replace the full contents of `omwhisper-native/UI/TranscriptionSettingsView.swift` with:

```swift
//
//  TranscriptionSettingsView.swift
//  OmWhisper
//
//  Engine picker (Apple / Parakeet / Cloud) + Parakeet's model download flow
//  + Cloud's AssemblyAI API key management. downloadProgress/downloadError/
//  apiKeyInput/hasSavedKey/keychainError are local @State (not AppState-
//  observed) -- ParakeetEngine and Keychain are plain, non-Observable types,
//  same pattern HistoryView/MemoryView already use for their own stores.
//

import SwiftUI
import FluidAudio

struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var downloadProgress: Double?
    @State private var downloadError: String?
    @State private var isReady = false
    @State private var apiKeyInput = ""
    @State private var hasSavedKey = false
    @State private var keychainError: String?

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Engine") {
                Picker("Transcription engine", selection: $state.engineKind) {
                    Text("Apple (on-device, default)").tag(EngineKind.apple)
                    Text("Parakeet (local CoreML)").tag(EngineKind.parakeet)
                    Text("Cloud (AssemblyAI)").tag(EngineKind.cloud)
                }
                .pickerStyle(.radioGroup)
            }

            if state.engineKind == .parakeet {
                Section("Parakeet Model") {
                    if isReady {
                        Text("Ready.")
                            .foregroundStyle(.secondary)
                    } else if let downloadProgress {
                        ProgressView(value: downloadProgress)
                        Text("Downloading… \(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Download Parakeet Model", action: downloadModel)
                        if let downloadError {
                            Text(downloadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if state.engineKind == .cloud {
                Section("AssemblyAI API Key") {
                    Text("Streams your voice live to AssemblyAI (a third-party service) while dictating. Requires your own API key — see assemblyai.com for pricing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("API key", text: $apiKeyInput)
                    HStack {
                        Button("Save", action: saveKey)
                            .disabled(apiKeyInput.isEmpty)
                        Button("Clear", action: clearKey)
                            .disabled(!hasSavedKey)
                    }
                    Text(hasSavedKey ? "Key saved." : "No key saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let keychainError {
                        Text(keychainError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            isReady = appState.parakeetEngine.isReady
            hasSavedKey = Keychain.loadAssemblyAIKey() != nil
        }
    }

    private func downloadModel() {
        downloadError = nil
        downloadProgress = 0
        Task {
            do {
                try await appState.parakeetEngine.ensureModelsLoaded { progress in
                    Task { @MainActor in
                        downloadProgress = progress.fractionCompleted
                    }
                }
                await MainActor.run {
                    downloadProgress = nil
                    isReady = true
                }
            } catch {
                await MainActor.run {
                    downloadProgress = nil
                    downloadError = error.localizedDescription
                }
            }
        }
    }

    private func saveKey() {
        keychainError = nil
        do {
            try Keychain.saveAssemblyAIKey(apiKeyInput)
            apiKeyInput = ""
            hasSavedKey = true
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func clearKey() {
        keychainError = nil
        do {
            try Keychain.deleteAssemblyAIKey()
            hasSavedKey = false
        } catch {
            keychainError = error.localizedDescription
        }
    }
}

#Preview {
    TranscriptionSettingsView().environment(AppState())
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/UI/TranscriptionSettingsView.swift
git commit -m "feat(cloud): enable Cloud engine selection + API key UI in Transcription settings"
```

## Task 6: Docs update + full verification pass

**Files:**
- Modify: `CLAUDE.md` (M4 milestone row)

**Interfaces:** None — this task is documentation plus a final full build/test run, no new production code.

- [ ] **Step 1: Run the full test suite one more time**

Run: `xcodebuild test -project omwhisper-native.xcodeproj -scheme omwhisper-native -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED, all tests pass (existing suite + 4 Keychain + 11 CloudEngine + 5 EngineVocabularyMerge = 20 new tests)

- [ ] **Step 2: Update the M4 row in `CLAUDE.md`'s Progress Tracker**

Open `CLAUDE.md`, find the M4 row (`| M4 — Backend flexibility | 🔶 M4.1 shipped, M4.2 (CloudEngine) not started | ...`) and update the status cell to `✅ M4.1 + M4.2 shipped` (M4 is now fully complete — this was the last sub-project). Append a new paragraph to that row's notes cell (after the existing M4.1 paragraph) covering: M4.2 shipped 2026-07-10 per `docs/superpowers/specs/2026-07-09-m4-2-cloud-engine-design.md` and `docs/superpowers/plans/2026-07-10-m4-2-cloud-engine.md`; `CloudEngine.swift` (stateless struct, AssemblyAI Universal Streaming WebSocket, verified live against AssemblyAI's docs rather than assumed — exact token-endpoint/WS-URL/Turn-message/Terminate-message shapes); `Keychain.swift` (new, first Keychain usage in this codebase, generic-password item scoped to one account); `mergeEngineVocabulary` in `VocabularyProcessing.swift` (Cloud excludes S2's auto-extracted screen terms, only the user's own `customVocabulary` reaches AssemblyAI as keyterms); `TranscriptionSettingsView.swift` extended with the Cloud radio row (previously disabled) and an API key SecureField/Save/Clear UI with an upfront privacy/cost warning. Note live verification status honestly: unit tests cover every pure piece (keyterm capping/truncation, URL construction, Turn-message parsing, vocabulary-exclusion logic, Keychain round-trip), but the actual WebSocket connection against AssemblyAI's real servers has **not been live-verified** in this pass — that requires a real AssemblyAI account and API key from the user, which wasn't available during implementation; flag this as the one remaining verification step before M4 is considered fully done.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: mark M4.2 (CloudEngine) shipped, M4 complete pending live verification"
```
