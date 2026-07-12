# Cloud Multi-Provider Transcription — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Turn the AssemblyAI-only CloudEngine into a dispatcher over 5 providers (AssemblyAI + Deepgram streaming; ElevenLabs + OpenAI + Groq batch), each with its own Keychain key + a Settings provider picker.

**Architecture:** `CloudProviderKind` (pure enum) drives `CloudEngine.transcribe()` to a streaming provider (WebSocket) or the shared batch transcriber (accumulate → WAV → multipart POST → one `.final`). Contract (`TranscriptionEngine`) unchanged.

## Global Constraints

- Verified provider API shapes are in the spec's table (`docs/superpowers/specs/2026-07-12-cloud-multi-provider-design.md`) — use them verbatim. Deepgram: `wss://api.deepgram.com/v1/listen`, `Authorization: Token <key>`, linear16 PCM, `channel.alternatives[0].transcript` + `is_final`, close with `{"type":"CloseStream"}`.
- All networking types stay `nonisolated` (the `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` gotcha). WebSocket/batch code guards non-Sendable AV types with `@preconcurrency import AVFoundation`.
- **AssemblyAI behavior preserved**: the existing `CloudEngineTests` (`cappedKeyterms`/`connectionURL`/`parseServerMessage`) must stay green after the refactor — the regression proof.
- Keys in Keychain only, one account per provider. Default `cloudProvider = .assemblyAI` (no change for existing users).
- Redaction is polish-only; cloud transcription shows a per-provider "your voice goes to `<provider>`" note — no redaction of audio.
- Build: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`. Suite currently 281.

---

### Task 1: `CloudProviderKind` + Keychain per-provider accounts

**Files:** Create `Transcription/CloudProviderKind.swift`; Modify `Transcription/Keychain.swift`; Test `omwhisper-nativeTests/CloudEngineTests.swift`.

- [ ] **Step 1 — `CloudProviderKind.swift`:**
```swift
import Foundation

/// User-selectable cloud transcription provider. Pure (no networking) so it backs
/// a UserDefaults setting and is unit-testable.
nonisolated enum CloudProviderKind: String, CaseIterable, Identifiable, Sendable {
    case assemblyAI, deepgram, elevenLabs, openAI, groq

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .assemblyAI: "AssemblyAI"
        case .deepgram: "Deepgram"
        case .elevenLabs: "ElevenLabs Scribe"
        case .openAI: "OpenAI"
        case .groq: "Groq (Whisper)"
        }
    }

    /// Live partials (streaming WS) vs. text-on-release (batch POST).
    var isStreaming: Bool {
        switch self {
        case .assemblyAI, .deepgram: true
        case .elevenLabs, .openAI, .groq: false
        }
    }

    /// Distinct Keychain generic-password account per provider. assemblyAI keeps
    /// its existing account string for back-compat with M4.2-saved keys.
    var keychainAccount: String {
        switch self {
        case .assemblyAI: "assemblyai-api-key"
        case .deepgram: "deepgram-api-key"
        case .elevenLabs: "elevenlabs-api-key"
        case .openAI: "cloud-stt-openai-api-key"
        case .groq: "groq-api-key"
        }
    }

    var signupHint: String {
        switch self {
        case .assemblyAI: "assemblyai.com"
        case .deepgram: "deepgram.com"
        case .elevenLabs: "elevenlabs.io"
        case .openAI: "platform.openai.com"
        case .groq: "console.groq.com"
        }
    }

    var privacyNote: String {
        "Streams your voice \(isStreaming ? "live " : "")to \(displayName) (a third-party service) while dictating. Requires your own API key from \(signupHint)."
    }
}
```

- [ ] **Step 2 — Keychain:** change `load(account:)`/`save(_:account:)`/`delete(account:)` from `private` to `static` (internal). Add convenience:
```swift
    // MARK: Cloud transcription providers (multi-provider)
    static func loadSTTKey(_ provider: CloudProviderKind) -> String? { load(account: provider.keychainAccount) }
    static func saveSTTKey(_ key: String, provider: CloudProviderKind) throws { try save(key, account: provider.keychainAccount) }
    static func deleteSTTKey(_ provider: CloudProviderKind) throws { try delete(account: provider.keychainAccount) }
```
(Keep the existing `loadAssemblyAIKey` etc. — `.assemblyAI`'s account matches, so old keys load either way.)

- [ ] **Step 3 — tests** (append to `CloudEngineTests`):
```swift
    @Test("CloudProviderKind rawValues round-trip and accounts are unique")
    func providerKinds() {
        #expect(CloudProviderKind(rawValue: "deepgram") == .deepgram)
        #expect(CloudProviderKind.allCases.count == 5)
        let accounts = Set(CloudProviderKind.allCases.map(\.keychainAccount))
        #expect(accounts.count == 5)   // no collisions
        #expect(CloudProviderKind.assemblyAI.keychainAccount == "assemblyai-api-key")  // back-compat
        #expect(CloudProviderKind.assemblyAI.isStreaming && !CloudProviderKind.groq.isStreaming)
    }
```

- [ ] **Step 4:** build test → 282. Commit `feat(cloud): CloudProviderKind + per-provider Keychain accounts`.

---

### Task 2: WAV encoder + `BatchCloudTranscriber` (ElevenLabs/OpenAI/Groq)

**Files:** Create `Transcription/BatchCloudTranscriber.swift`; Test `CloudEngineTests`.

**Interfaces produced:** `BatchCloudTranscriber` with a `Config` (endpoint/auth/model/language/responseKey) and per-provider config factories; `pcmToWav(int16:sampleRate:) -> Data`; effectful `transcribe(audio:apiKey:language:) async throws -> String`; `testConnection(config:apiKey:) async -> String?`.

- [ ] **Step 1 — implement** `Transcription/BatchCloudTranscriber.swift`:
```swift
@preconcurrency import AVFoundation
import Foundation

nonisolated struct BatchCloudTranscriber {
    struct Config: Sendable {
        let url: URL
        let authHeader: String       // "Authorization" or "xi-api-key"
        let authValue: (String) -> String   // key -> header value ("Bearer \(k)" or raw)
        let modelField: String       // "model" or "model_id"
        let model: String
        let languageField: String?   // "language" (OpenAI/Groq) / "language_code" (11L) / nil
        let responseKey: String      // "text"
    }

    static func openAI() -> Config {
        Config(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
               authHeader: "Authorization", authValue: { "Bearer \($0)" },
               modelField: "model", model: "gpt-4o-transcribe",
               languageField: "language", responseKey: "text")
    }
    static func groq() -> Config {
        Config(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
               authHeader: "Authorization", authValue: { "Bearer \($0)" },
               modelField: "model", model: "whisper-large-v3-turbo",
               languageField: "language", responseKey: "text")
    }
    static func elevenLabs() -> Config {
        Config(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
               authHeader: "xi-api-key", authValue: { $0 },
               modelField: "model_id", model: "scribe_v1",
               languageField: "language_code", responseKey: "text")
    }
    static func config(for provider: CloudProviderKind) -> Config? {
        switch provider {
        case .openAI: openAI()
        case .groq: groq()
        case .elevenLabs: elevenLabs()
        case .assemblyAI, .deepgram: nil   // streaming, not batch
        }
    }

    /// Minimal 16-bit mono PCM → WAV container (44-byte header + samples).
    nonisolated static func pcmToWav(int16 samples: [Int16], sampleRate: Int) -> Data {
        let byteRate = sampleRate * 2, dataSize = samples.count * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(2); u16(16)
        str("data"); u32(UInt32(dataSize))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    nonisolated static func multipartBody(wav: Data, config: Config, language: String?, boundary: String) -> Data {
        var d = Data()
        func field(_ name: String, _ value: String) {
            d.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        field(config.modelField, config.model)
        if let lf = config.languageField, let language, language != "auto" { field(lf, language) }
        d.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        d.append(wav)
        d.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return d
    }

    nonisolated static func parseText(_ data: Data, key: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }
}
```
Plus the effectful `transcribe(audio:config:apiKey:language:)`: accumulate mic buffers → 16 kHz mono Int16 (reuse the AssemblyAI conversion) → `[Int16]` → `pcmToWav` → build `URLRequest` (POST, auth header, `Content-Type: multipart/form-data; boundary=…`, body from `multipartBody`) → `URLSession.data(for:)` → `parseText`. And `testConnection(config:apiKey:)` posting a ~0.1 s silence WAV, returning nil on 200 / a message on 401/other.

- [ ] **Step 2 — tests:** `pcmToWav` header bytes ("RIFF"/"WAVE"/"data", size fields, 44-byte header); `multipartBody` contains the model field + filename; `parseText` extracts `.text`; `config(for:)` returns nil for streaming providers, correct URL/model/header for each batch provider.
- [ ] **Step 3:** build test. Commit `feat(cloud): WAV encoder + batch transcriber (ElevenLabs/OpenAI/Groq)`.

---

### Task 3: `DeepgramProvider` (streaming)

**Files:** Create `Transcription/DeepgramProvider.swift`; Test `CloudEngineTests`.

- [ ] **Step 1 — implement** (mirror the AssemblyAI WS path in the current CloudEngine, with Deepgram's shapes):
  - `connectionURL(language:) -> URL`: `wss://api.deepgram.com/v1/listen` + `model=nova-3`, `encoding=linear16`, `sample_rate=16000`, `channels=1`, `interim_results=true`, `smart_format=true`, and `language` only when not "auto".
  - `parseResult(_ data: Data) -> TranscriptEvent?`: decode `{channel:{alternatives:[{transcript}]}, is_final}`; empty transcript → nil; `is_final==true` → `.final`, else `.partial`.
  - `transcribe(audio:apiKey:language:)`: `URLRequest` with header `Authorization: Token \(apiKey)`; open WS; receive loop → `parseResult`; feed 16 kHz mono Int16 binary frames (reuse the conversion); on mic-end send `{"type":"CloseStream"}`, drain ~1 s (ponytail, like AssemblyAI), cancel, finish.
  - `testConnection(apiKey:)`: `GET https://api.deepgram.com/v1/projects` with `Authorization: Token <key>` → 200 nil / 401 "Invalid API key".
- [ ] **Step 2 — tests:** `connectionURL` host/path + params (and language omitted when "auto"); `parseResult` final/partial/empty/malformed.
- [ ] **Step 3:** build test. Commit `feat(cloud): Deepgram streaming provider`.

---

### Task 4: refactor `CloudEngine` into a provider dispatcher

**Files:** Modify `Transcription/CloudEngine.swift` (extract AssemblyAI to `AssemblyAIProvider`; add `provider` + dispatch).

- [ ] **Step 1:** move the AssemblyAI-specific pure helpers (`cappedKeyterms`/`connectionURL`/`parseServerMessage`/`testConnection`) and the WS `transcribe` body into a new `nonisolated struct AssemblyAIProvider` **without changing their signatures/behavior** (so `CloudEngineTests`' existing `CloudEngine.connectionURL(...)` calls either move to `AssemblyAIProvider.connectionURL` — update those 3 tests — or `CloudEngine` re-exposes them as thin forwarders; pick forwarders to keep the tests untouched **only if trivial**, else update the tests).
- [ ] **Step 2:** `CloudEngine` gains `let provider: CloudProviderKind` (default `.assemblyAI`) and its `transcribe` dispatches:
```swift
    nonisolated func transcribe(_ audio: sending AsyncStream<AVAudioPCMBuffer>, vocabulary: [String]) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let provider = self.provider
        let task = Task {
            do {
                guard let apiKey = Keychain.loadSTTKey(provider), !apiKey.isEmpty else { throw EngineError.missingAPIKey(provider) }
                switch provider {
                case .assemblyAI: try await AssemblyAIProvider.run(audio: audio, apiKey: apiKey, vocabulary: vocabulary, into: continuation)
                case .deepgram:   try await DeepgramProvider.run(audio: audio, apiKey: apiKey, language: "auto", into: continuation)
                default:
                    guard let config = BatchCloudTranscriber.config(for: provider) else { throw EngineError.connectionFailed }
                    let text = try await BatchCloudTranscriber.transcribe(audio: audio, config: config, apiKey: apiKey, language: "auto")
                    if !text.isEmpty { continuation.yield(.final(text)) }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
```
  (Adapt each provider's `run(...)`/`transcribe(...)` to yield into the shared `continuation`; `EngineError.missingAPIKey(CloudProviderKind)` gives a provider-named message.)
- [ ] **Step 3:** build test — the moved AssemblyAI tests pass = regression proof. Commit `refactor(cloud): CloudEngine dispatches over CloudProviderKind`.

---

### Task 5: AppState + Settings UI

**Files:** Modify `AppState.swift`, `UI/TranscriptionSettingsView.swift`.

- [ ] **Step 1 — AppState:** `cloudProvider: CloudProviderKind` setting (access/withMutation, default `.assemblyAI`) + `SettingsKeys.cloudProvider`. In `activeEngine`, `case .cloud: CloudEngine(provider: cloudProvider)`.
- [ ] **Step 2 — Settings:** in the `engineKind == .cloud` section, add a provider `Picker` (`$state.cloudProvider`, `CloudProviderKind.allCases`), then replace the AssemblyAI-hardcoded key UI with per-selected-provider UI: `provider.privacyNote`, a streaming/on-release note, a `SecureField` + Save/Clear/Test bound to `Keychain.loadSTTKey/saveSTTKey/deleteSTTKey(provider)`, saved-status line. `Test Connection` dispatches to the provider's `testConnection` (AssemblyAI/Deepgram/batch). Local `@State` for the key input/hasSavedKey/test result, re-read on `.onChange(of: state.cloudProvider)`.
- [ ] **Step 3:** build test → suite green. Commit `feat(cloud): provider picker + per-provider key UI`.

## Live Verification Owed (per provider, needs real keys)

Every pure helper is unit-tested; the real network round-trip per provider is verified separately (M4.2/M3-2b precedent). For each of Deepgram/ElevenLabs/OpenAI/Groq: save a key, Test Connection passes, a real dictation transcribes (streaming shows partials for Deepgram; batch shows text on release), a bad key surfaces a clear error, and switching back to AssemblyAI still works.

## Self-Review

- Coverage: enum+keys (T1), batch+WAV (T2), Deepgram (T3), dispatcher+AssemblyAI-preservation (T4), setting+UI (T5). All spec sections covered.
- The AssemblyAI extraction (T4) is the one regression risk — its existing tests are the guard.
- No per-provider model picker / no audio redaction / no cloud language picker (all Non-Goals).
