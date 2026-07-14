# Sarvam Saaras Cross-Lingual Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When cross-lingual dictation is on and a Sarvam key is saved, route dictation to Sarvam Saaras (`mode=translate`) — Indic speech → English in one call, no LLM, no polish backend needed.

**Architecture:** A new stateless `SarvamEngine: TranscriptionEngine` reuses the existing batch machinery (`BatchCloudTranscriber.pcmToWav`/`multipartBody`/`post`) with a Sarvam `Config`. `AppState.activeEngine` auto-selects it when `crossLingualEnabled` and a Sarvam key exists; `polishedText` pastes its English output verbatim (no cross-lingual LLM step). Otherwise the current Whisper+LLM path is untouched.

**Tech Stack:** Swift 6 (MainActor-by-default), Foundation URLSession, Keychain, Swift Testing.

## Global Constraints

- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Anything callable off-MainActor or from tests must be `nonisolated`.
- Swift Testing (`import Testing`, `@Test`, `#expect`), `@testable import OmWhisper`. No XCUITest.
- Build/test: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test`. Swift Testing summary is `Test run with N tests…` (ignore the `Executed 0 tests` XCTest shim). Full suite is **311 tests** on `main` today.
- SourceKit false positives ("No such module 'WhisperKit'/'FluidAudio'", "cannot find X") are noise — trust `** BUILD SUCCEEDED **`.
- `@Observable` computed settings over `UserDefaults` need `access(keyPath:)`/`withMutation(keyPath:)` (N/A here — key presence, not a UserDefaults flag, is the switch).
- UI: Porcelain tokens, native controls, `.tint(Color.Porcelain.emerald)`, calm copy (omwhisper-design).
- **Verified API facts** (from docs/search 2026-07-14; the exact response field is confirmed in Task 1 before Task 2 encodes it): endpoint `POST https://api.sarvam.ai/speech-to-text`; auth header `api-subscription-key: <key>` (raw, NOT Bearer); `multipart/form-data` fields `model=saaras:v3`, `mode=translate`, `file=<wav>`; `language_code` optional (omit → auto-detect); response JSON output text field **expected `transcript`** (Task 1 confirms).
- Privacy: `SarvamEngine` sends **dictation audio** to Sarvam. Meetings stay on-device — do NOT touch `MeetingRecorder`/`MeetingTranscriber`.

## File Structure

- **Modify** `omwhisper-native/Transcription/BatchCloudTranscriber.swift` — add `extraFields` to `Config` (emitted by `multipartBody`) + a `sarvam()` config factory.
- **Create** `omwhisper-native/Transcription/SarvamEngine.swift` — the `TranscriptionEngine`.
- **Modify** `omwhisper-native/Transcription/Keychain.swift` — Sarvam key accessors.
- **Modify** `omwhisper-native/AppState.swift` — `activeEngine` (Sarvam branch) + `polishedText` (Sarvam skip).
- **Modify** `omwhisper-native/UI/TranscriptionSettingsView.swift` — Sarvam key field + status in the Cross-Lingual section.
- **Modify** `omwhisper-nativeTests/CloudEngineTests.swift` (or a new `SarvamTests.swift`) — pure config/multipart/parse tests.

---

### Task 1: Verify the Sarvam API against a real key (gate — no code)

**Files:** none (verification).

**Purpose:** Confirm the endpoint, request fields, auth header, and — critically — the **response field name** before Task 2 encodes them. The docs are a JS SPA that couldn't be scraped; this is the "unverified API = live failure" gate.

- [ ] **Step 1: Run the curl (user, own terminal — key stays out of chat)**

A 16 kHz test WAV was generated at:
`/private/tmp/claude-502/-Users-rakeshkusuma-Documents-PersonalProjects-omwhisper-native/7fef6c6e-c9c4-462b-b8fd-bd0452e7cdb7/scratchpad/sarvam_test.wav`
(regenerate if missing: `say -o /tmp/sarvam_test.wav --data-format=LEI16@16000 "short test"`)

Run, substituting your real key:

```bash
curl -s -X POST https://api.sarvam.ai/speech-to-text \
  -H "api-subscription-key: YOUR_SARVAM_KEY" \
  -F "model=saaras:v3" \
  -F "mode=translate" \
  -F "file=@/tmp/sarvam_test.wav;type=audio/wav" | python3 -m json.tool
```

- [ ] **Step 2: Record the confirmed facts**

From the JSON response and HTTP status, confirm and note for Task 2:
- The exact **output text field name** (expected `transcript` — could be `transcript`, `text`, or nested).
- That HTTP 200 + `api-subscription-key` auth worked (else the endpoint/header differs).
- Any detected-language field name (informational).

If the endpoint 404s, try the legacy `POST https://api.sarvam.ai/speech-to-text-translate` (same fields minus `mode`). Whatever works becomes the values Task 2 encodes.

- [ ] **Step 3: No commit** (verification only).

---

### Task 2: BatchCloudTranscriber — `extraFields` + `sarvam()` config

**Files:**
- Modify: `omwhisper-native/Transcription/BatchCloudTranscriber.swift`
- Test: `omwhisper-nativeTests/CloudEngineTests.swift`

**Interfaces:**
- Produces: `BatchCloudTranscriber.Config.extraFields: [String: String]`; `BatchCloudTranscriber.sarvam() -> Config`.
- Consumes: existing `pcmToWav`, `multipartBody`, `post`, `parseText`.

- [ ] **Step 1: Write the failing tests**

Add to `CloudEngineTests.swift` (inside its existing `struct`/suite; if it uses `import Testing` already, don't re-add):

```swift
    @Test func sarvamConfigShape() {
        let c = BatchCloudTranscriber.sarvam()
        #expect(c.url.absoluteString == "https://api.sarvam.ai/speech-to-text")
        #expect(c.authHeader == "api-subscription-key")
        #expect(c.authBearer == false)
        #expect(c.model == "saaras:v3")
        #expect(c.extraFields["mode"] == "translate")
        #expect(c.responseKey == "transcript")   // confirmed in Task 1
    }

    @Test func multipartEmitsExtraFields() {
        let wav = BatchCloudTranscriber.pcmToWav(int16: [0, 0, 0], sampleRate: 16000)
        let body = BatchCloudTranscriber.multipartBody(
            wav: wav, config: BatchCloudTranscriber.sarvam(), language: nil, boundary: "B")
        let s = String(decoding: body, as: UTF8.self)
        #expect(s.contains("name=\"model\""))
        #expect(s.contains("saaras:v3"))
        #expect(s.contains("name=\"mode\""))
        #expect(s.contains("translate"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "cannot find|no exact matches|BUILD FAILED" | head -3`
Expected: build failure — `sarvam()` / `extraFields` don't exist yet.

- [ ] **Step 3: Add `extraFields` to Config + emit it, and the `sarvam()` factory**

In `BatchCloudTranscriber.swift`, add a field to `struct Config` (after `responseKey`):

```swift
        let responseKey: String  // "text" / "transcript"
        var extraFields: [String: String] = [:]  // provider-specific form fields (e.g. Sarvam's mode=translate)
```

In `multipartBody`, emit them right after the model field (before the `language` field):

```swift
        field(config.modelField, config.model)
        for (name, value) in config.extraFields.sorted(by: { $0.key < $1.key }) { field(name, value) }
        if let lf = config.languageField, let language, language != "auto" { field(lf, language) }
```

Add the factory next to `elevenLabs()`:

```swift
    static func sarvam() -> Config {
        Config(url: URL(string: "https://api.sarvam.ai/speech-to-text")!,
               authHeader: "api-subscription-key", authBearer: false,
               modelField: "model", model: "saaras:v3",
               languageField: "language_code", responseKey: "transcript",
               extraFields: ["mode": "translate"])
    }
```

(If Task 1 showed a different response field or endpoint, use those exact values here and in the test.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "error:|Test run with|BUILD FAILED" | tail -4`
Expected: `Test run with 313 tests…` (311 + 2), no errors.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Transcription/BatchCloudTranscriber.swift omwhisper-nativeTests/CloudEngineTests.swift
git commit -m "✨ feat(sarvam): BatchCloudTranscriber extraFields + Saaras config"
```

---

### Task 3: Keychain — Sarvam key accessors

**Files:**
- Modify: `omwhisper-native/Transcription/Keychain.swift`
- Test: `omwhisper-nativeTests/KeychainTests.swift`

**Interfaces:**
- Produces: `Keychain.loadSarvamKey() -> String?`, `Keychain.saveSarvamKey(_:) throws`, `Keychain.deleteSarvamKey() throws`.
- Consumes: existing private `load(account:)`/`save(_:account:)`/`delete(account:)`.

- [ ] **Step 1: Write the failing test**

Add to `KeychainTests.swift`:

```swift
    @Test func sarvamKeyRoundTrip() throws {
        try? Keychain.deleteSarvamKey()
        #expect(Keychain.loadSarvamKey() == nil)
        try Keychain.saveSarvamKey("sarvam-test-123")
        #expect(Keychain.loadSarvamKey() == "sarvam-test-123")
        try Keychain.deleteSarvamKey()
        #expect(Keychain.loadSarvamKey() == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "cannot find 'Keychain'|loadSarvamKey|BUILD FAILED" | head -3`
Expected: build failure — `loadSarvamKey` not found.

- [ ] **Step 3: Add the accessors**

In `Keychain.swift`, add the account constant next to `cloudLLMAccount` (line ~18):

```swift
    private static let sarvamAccount = "sarvam-api-key"
```

and the methods next to the AssemblyAI/CloudLLM ones (line ~39):

```swift
    static func loadSarvamKey() -> String? { load(account: sarvamAccount) }
    static func saveSarvamKey(_ key: String) throws { try save(key, account: sarvamAccount) }
    static func deleteSarvamKey() throws { try delete(account: sarvamAccount) }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "error:|KeychainTests.*(passed|failed)|Test run with|BUILD FAILED" | tail -4`
Expected: `KeychainTests` passes; `Test run with 314 tests…`.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Transcription/Keychain.swift omwhisper-nativeTests/KeychainTests.swift
git commit -m "✨ feat(sarvam): Keychain accessors for the Sarvam API key"
```

---

### Task 4: SarvamEngine

**Files:**
- Create: `omwhisper-native/Transcription/SarvamEngine.swift`

**Interfaces:**
- Consumes: `BatchCloudTranscriber.sarvam()`/`post` (Task 2), `Keychain.loadSarvamKey()` (Task 3), existing `BufferConverter`, `EngineKind`, `TranscriptionEngine`/`TranscriptEvent`.
- Produces: `SarvamEngine` (a `TranscriptionEngine`).

No new unit test: it needs a live network call + the mic stream (effectful, like `CloudEngine`); the pure pieces are already tested in Task 2. Build-verified; live-verified in Task 7.

- [ ] **Step 1: Create the engine**

Create `omwhisper-native/Transcription/SarvamEngine.swift`:

```swift
//
//  SarvamEngine.swift
//  OmWhisper
//
//  Cross-lingual cloud engine: sends dictation audio to Sarvam's Saaras
//  speech-to-text in mode=translate → English text in one call (code-switch
//  aware). Auto-selected by AppState when crossLingual is on and a Sarvam key
//  is saved. Reuses the batch machinery (BatchCloudTranscriber). Stateless like
//  AppleEngine/CloudEngine. Sends the user's dictation AUDIO to Sarvam — see the
//  privacy note in the design spec; meetings are unaffected.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated struct SarvamEngine: TranscriptionEngine {
    let kind: EngineKind = .cloud   // it is a cloud engine; never user-picked, only auto-selected

    enum EngineError: Error, LocalizedError {
        case missingKey
        var errorDescription: String? { "Add your Sarvam API key in Settings → Transcription." }
    }

    nonisolated func transcribe(
        _ audio: sending AsyncStream<AVAudioPCMBuffer>,
        vocabulary: [String]
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let task = Task {
            do {
                guard let apiKey = Keychain.loadSarvamKey(), !apiKey.isEmpty else {
                    throw EngineError.missingKey
                }
                guard let pcmFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
                ) else { throw EngineError.missingKey }
                let converter = BufferConverter()
                var samples: [Int16] = []
                for await buffer in audio {
                    guard let converted = try? converter.convertBuffer(buffer, to: pcmFormat),
                          let ch = converted.int16ChannelData else { continue }
                    samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))
                }
                // Saaras auto-detects the language (built for mixed Indic+English),
                // so no language field is sent.
                let english = try await BatchCloudTranscriber.post(
                    samples: samples, config: BatchCloudTranscriber.sarvam(), apiKey: apiKey, language: nil)
                if !english.isEmpty { continuation.yield(.final(english)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/Transcription/SarvamEngine.swift
git commit -m "✨ feat(sarvam): SarvamEngine — speech→English via Saaras translate"
```

---

### Task 5: AppState wiring — auto-select Sarvam + skip the LLM step

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `SarvamEngine` (Task 4), `Keychain.loadSarvamKey()` (Task 3).

No new unit test (wiring; the pure pieces are tested in Tasks 2-3; suite stays green as regression proof; live-verified in Task 7).

- [ ] **Step 1: Auto-select Sarvam in `activeEngine`**

Replace `activeEngine` (currently the `switch CrossLingual.engineKind(...)`):

```swift
    private var activeEngine: TranscriptionEngine {
        // Cross-lingual + a Sarvam key → Saaras does speech→English directly.
        if crossLingualEnabled, Keychain.loadSarvamKey() != nil {
            return SarvamEngine()
        }
        switch CrossLingual.engineKind(base: engineKind, crossLingual: crossLingualEnabled) {
        case .apple: appleEngine
        case .parakeet: parakeetEngine
        case .cloud: CloudEngine(provider: cloudProvider)   // stateless; built per session
        case .whisper: whisperEngine
        }
    }
```

- [ ] **Step 2: Skip the cross-lingual LLM step for Sarvam output**

In `polishedText(for:)`, add the guard as the FIRST line of the body (before the Foundation-Models nudge), so Sarvam's already-English output is pasted verbatim with no backend needed:

```swift
    private func polishedText(for original: String) async -> String {
        // Sarvam already produced English (cross-lingual + key) — paste as-is; never
        // run the translate/polish prompt on it, and no polish backend is required.
        if crossLingualEnabled, Keychain.loadSarvamKey() != nil { return original }
        // The one-time nudge fires only when System is selected but off — not for
        // Disabled or an unconfigured Ollama, which are deliberate "no polish" states.
        if polishBackend == .system, !SystemLLM.isAvailable() {
```

(Leave the rest of `polishedText` unchanged.)

- [ ] **Step 3: Build + run the suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj test 2>&1 | grep -iE "error:|Test run with|BUILD FAILED" | tail -4`
Expected: `Test run with 314 tests…`, no errors.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(sarvam): auto-select Sarvam for cross-lingual; skip LLM on its output"
```

---

### Task 6: Settings UI — Sarvam key field in the Cross-Lingual section

**Files:**
- Modify: `omwhisper-native/UI/TranscriptionSettingsView.swift`

**Interfaces:**
- Consumes: `Keychain.loadSarvamKey`/`saveSarvamKey`/`deleteSarvamKey` (Task 3).

No new unit test (SwiftUI, verified live).

- [ ] **Step 1: Add local state for the Sarvam key field**

Near the other `@State` in `TranscriptionSettingsView` (e.g. after `apiKeyInput`):

```swift
    @State private var sarvamKeyInput = ""
    @State private var sarvamKeySaved = Keychain.loadSarvamKey() != nil
    @State private var sarvamKeyError: String?
```

- [ ] **Step 2: Extend the Cross-Lingual section**

Replace the explainer `Text(...)` at the end of the `PorcelainSection(eyebrow: "Cross-Lingual")` block with the key field + status + note:

```swift
                Text("Dictate in your language; polished English comes out.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)

                Divider().padding(.vertical, 2)

                if sarvamKeySaved {
                    Label("Sarvam key saved — using Sarvam (Saaras) for translation",
                          systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.Porcelain.emerald)
                    Button("Clear Sarvam key") {
                        try? Keychain.deleteSarvamKey(); sarvamKeySaved = false; sarvamKeyInput = ""
                    }
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.mint)
                } else {
                    Text("Best for Indic languages (Telugu, Hindi, …): add a Sarvam key and speech goes straight to English via Sarvam — no Whisper model or polish backend needed. Without a key, cross-lingual uses on-device Whisper + your polish backend.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    HStack {
                        SecureField("Sarvam API key", text: $sarvamKeyInput)
                            .porcelainField()
                        Button("Save") {
                            do { try Keychain.saveSarvamKey(sarvamKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                                 sarvamKeySaved = true; sarvamKeyInput = ""; sarvamKeyError = nil }
                            catch { sarvamKeyError = "Couldn't save to Keychain." }
                        }
                        .disabled(sarvamKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let sarvamKeyError {
                        Text(sarvamKeyError).font(.caption).foregroundStyle(.red)
                    }
                }
                Text("Your dictation audio is sent to Sarvam (sarvam.ai) to transcribe-and-translate. Recorded meetings stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(Color.Porcelain.dim)
```

(This whole block sits inside the existing `PorcelainSection(eyebrow: "Cross-Lingual") { … }`. The `SecureField`/`Save`/`Clear`/`porcelainField()` mirror the existing Cloud provider key field in the same file — check that file's `porcelainField()` usage and match it.)

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/UI/TranscriptionSettingsView.swift
git commit -m "✨ feat(sarvam): Sarvam key field + status in the Cross-Lingual settings"
```

---

### Task 7: Live verification (manual — user)

Not automated. Needs a real Sarvam key.

- [ ] Settings → Transcription → Cross-Lingual: toggle ON, paste your **Sarvam key** → Save (status shows "using Sarvam").
- [ ] Put the cursor in a text field, hold Fn / ⌘⇧V, speak a **Telugu / Tenglish** sentence → clean **English** pastes, in one round-trip, with **no polish backend set** (AI Polish can be Disabled).
- [ ] Confirm speed is one network call (no Whisper load, no LLM) — much faster than the Whisper+Ollama path.
- [ ] **Clear Sarvam key** → cross-lingual falls back to Whisper + your polish backend (unchanged behavior).
- [ ] Record a meeting and confirm it still transcribes on-device (Sarvam untouched there).

---

## Self-Review

**1. Spec coverage:**
- SarvamEngine (speech→English via Saaras translate) → Task 4. ✓
- Auto-selected by cross-lingual + key → Task 5 Step 1. ✓
- No LLM step / no polish backend needed → Task 5 Step 2 (`polishedText` early return). ✓
- Auto-detect language → Task 4 (`language: nil`). ✓
- Key in Cross-Lingual settings block, Keychain-stored → Tasks 3 + 6. ✓
- Privacy note (audio egress; meetings on-device) → Task 6 Step 2 copy. ✓
- Verify-first API → Task 1 gate before Task 2 encodes values. ✓
- Reuse batch machinery (pcmToWav/multipart/post) → Task 2 (`extraFields` + `sarvam()`), Task 4 (`post`). ✓
- Pure tests (request build + parse) → Task 2 (`multipartEmitsExtraFields`, `sarvamConfigShape`); parse reuses tested `parseText`. Keychain round-trip → Task 3. ✓
- No new `EngineKind` case (Sarvam never user-picked) → Task 4 (`kind = .cloud`), Task 5 (returned before the switch). ✓
- Out of scope (general provider, tone-polish, streaming, language mapping) → not implemented. ✓

**2. Placeholder scan:** No TBD/TODO. The one unconfirmed value (`responseKey`) is gated by Task 1 with an explicit "use the confirmed value" instruction — the spec's verify-first design, not a placeholder.

**3. Type consistency:** `Config.extraFields` / `sarvam()` defined Task 2, used Tasks 2/4. `loadSarvamKey`/`saveSarvamKey`/`deleteSarvamKey` defined Task 3, used Tasks 4/5/6. `SarvamEngine()` defined Task 4, used Task 5. `BatchCloudTranscriber.post(samples:config:apiKey:language:)` is the existing signature (verified). Test counts: 311 → 313 (Task 2) → 314 (Task 3); Tasks 4-6 add none.
