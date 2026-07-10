# M3 Sub-project 2b — Cloud (OpenAI-compatible) Polish Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hosted OpenAI-compatible LLM as a selectable polish backend, with a ported
redactor that scrubs secrets/PII before egress and re-hydrates on return (fail-closed).

**Architecture:** New `Redactor.swift` (faithful port of the old app's `redactor.rs`) + new
`CloudLLM: PolishBackend` (redact → `/chat/completions` → `stripLLMWrapper` → rehydrate), a
generalized `Keychain` holding the cloud key, and a `.cloud` case added to the `activePolishBackend()`
dispatch built in 2a (so dictation polish AND Reply Assist get Cloud, redacted, for free).

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), `URLSession`, `NSRegularExpression`, `Security`
(Keychain), the existing `PolishBackend`/`PolishStyle.systemPrompt`/`stripLLMWrapper` from 2a.

**Spec:** `docs/superpowers/specs/2026-07-10-m3-2b-cloud-polish-backend-design.md`.

## Global Constraints

- **`nonisolated`** on every new type/free function (`Redaction`, `redact`, the validators,
  `CloudLLM`) — the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` will otherwise pin them
  and break the `PolishBackend` conformance / pure-function tests (the recurring gotcha).
- **Redaction is cloud-only and unconditional**: `CloudLLM.polish` calls `redact` as its first
  step, always. System/Ollama are on-device and never redacted. No `prepare_outbound` gate (one
  cloud call site).
- **Fail-safe preserved**: any polish failure → `AppState.polishedText`/`draftAndStream` return
  the original text (already true via `activePolishBackend()`); no key saved → `.cloud` returns
  nil → raw fallback.
- **Key never touches UserDefaults** — Keychain only, like the M4.2 AssemblyAI key.
- **`stripLLMWrapper` (from 2a) is reused** on Cloud output; do not re-port it.
- **UI uses `Color.Porcelain.*`, `PorcelainSection`, `.porcelainField()`** — no native
  `Form`/`.roundedBorder`.
- Run `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test` after
  every task; must end `** TEST SUCCEEDED **`. Baseline **234**; count grows as tasks add tests.

---

### Task 1: `Redactor.swift` — port `redactor.rs`

**Files:**
- Create: `omwhisper-native/Polish/Redactor.swift`
- Test: `omwhisper-nativeTests/RedactorTests.swift` (create)

**Interfaces:**
- Produces: `redact(_ text: String) -> Redaction`; `Redaction { text: String; mapping: [String: String]; func rehydrate(_:) -> String }`.

- [ ] **Step 1: Write the failing tests (ported from `redactor.rs`)**

Create `omwhisper-nativeTests/RedactorTests.swift`:

```swift
import Foundation
import Testing
@testable import OmWhisper

struct RedactorTests {
    @Test func catchesEmail() {
        let r = redact("ping me at jane.doe@example.com ok")
        #expect(!r.text.contains("jane.doe@example.com"))
        #expect(r.text.contains("[REDACTED_EMAIL_1]"))
        #expect(r.mapping["[REDACTED_EMAIL_1]"] == "jane.doe@example.com")
    }

    @Test func catchesOpenAIKey() {
        let key = ["sk-", "proj-ABCdef0123456789ABCdef0123"].joined()
        let r = redact("my key is \(key) thanks")
        #expect(!r.text.contains(key))
        #expect(r.text.contains("[REDACTED_API_KEY_1]"))
        #expect(r.mapping["[REDACTED_API_KEY_1]"] == key)
    }

    @Test func catchesBearerToken() {
        let r = redact("Authorization: Bearer abcDEF123456ghiJKL")
        #expect(!r.text.contains("abcDEF123456ghiJKL"))
        #expect(r.text.contains("[REDACTED_BEARER_TOKEN_1]"))
    }

    @Test func catchesProviderKeys() {
        let cases: [(String, String)] = [
            (["xox", "b-1234567890-abcdefghijklmno"].joined(), "SLACK_TOKEN"),
            (["AKIA", "IOSFODNN7EXAMPLE"].joined(), "AWS_KEY"),
            (["ghp", "_0123456789abcdefABCDEFghijklmnopqrs"].joined(), "GITHUB_TOKEN"),
            (["AIza", "SyA1234567890abcdefghijklmnopqrstuv"].joined(), "GOOGLE_API_KEY"),
        ]
        for (secret, kind) in cases {
            let r = redact("value \(secret) end")
            #expect(!r.text.contains(secret), "\(kind) leaked")
            #expect(r.text.contains("[REDACTED_\(kind)_1]"), "expected \(kind) placeholder, got \(r.text)")
        }
    }

    @Test func catchesPrivateKeyBlock() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIBmabc123\nDEF456ghi==\n-----END RSA PRIVATE KEY-----"
        let r = redact("here:\n\(pem)\ndone")
        #expect(!r.text.contains("MIIBmabc123"))
        #expect(r.text.contains("[REDACTED_PRIVATE_KEY_1]"))
    }

    @Test func catchesLuhnValidCardOnly() {
        let r = redact("card 4111 1111 1111 1111 not 1234 5678 9012 3456")
        #expect(!r.text.contains("4111 1111 1111 1111"))
        #expect(r.text.contains("[REDACTED_CARD_1]"))
        #expect(r.text.contains("1234 5678 9012 3456"))  // Luhn-invalid → left alone
    }

    @Test func catchesPhoneButNotYearRange() {
        let r = redact("call +1 (555) 123-4567 during 2020-2021")
        #expect(r.text.contains("[REDACTED_PHONE_1]"))
        #expect(!r.text.contains("555) 123-4567"))
        #expect(r.text.contains("2020-2021"))
    }

    @Test func catchesHighEntropySecretButNotPlainWord() {
        let secret = "Zx9Kq2Lm7Pw4Rt6Yv1Bn8Cd3Fg5Hj0"
        let r = redact("token=\(secret)")
        #expect(!r.text.contains(secret))
        #expect(r.text.contains("[REDACTED_SECRET_1]"))
        let plain = redact("supercalifragilisticexpialidocioussentence")
        #expect(plain.mapping.isEmpty, "plain word wrongly redacted: \(plain.text)")
    }

    @Test func placeholdersAreTypedAndStable() {
        let r = redact("mail a@x.com, again a@x.com, and b@y.com")
        #expect(r.text.contains("[REDACTED_EMAIL_1]"))
        #expect(r.text.contains("[REDACTED_EMAIL_2]"))
        #expect(r.text.components(separatedBy: "[REDACTED_EMAIL_1]").count - 1 == 2)  // reused for a@x.com
        #expect(r.mapping["[REDACTED_EMAIL_1]"] == "a@x.com")
        #expect(r.mapping["[REDACTED_EMAIL_2]"] == "b@y.com")
    }

    @Test func rehydrateRestoresOriginals() {
        let key = ["sk-", "ABCdef0123456789ABCdef"].joined()
        let r = redact("email a@x.com and key \(key)")
        let cloudResponse = "Sure — contact [REDACTED_EMAIL_1] using [REDACTED_API_KEY_1]."
        let restored = r.rehydrate(cloudResponse)
        #expect(restored.contains("a@x.com"))
        #expect(restored.contains(key))
        #expect(!restored.contains("[REDACTED_"))
    }

    @Test func cleanTextUnchanged() {
        let text = "Let's meet tomorrow at noon to review the roadmap."
        let r = redact(text)
        #expect(r.text == text)
        #expect(r.mapping.isEmpty)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'redact'`)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|cannot find 'redact'"`
Expected: `cannot find 'redact' in scope`.

- [ ] **Step 3: Implement `Redactor.swift`**

Create `omwhisper-native/Polish/Redactor.swift`:

```swift
//
//  Redactor.swift
//  OmWhisper
//
//  Scrubs secrets/PII from text before it is sent to a cloud API, and re-hydrates
//  the placeholders a cloud response echoes back. Faithful port of the old Tauri
//  app's src-tauri/src/ai/redactor.rs. Cloud is the ONLY egress for polish text
//  (System/Ollama are on-device), so CloudLLM.polish calls redact() unconditionally
//  as its first step — no separate is-cloud gate. The placeholder->original mapping
//  is in-memory, per-request, and never logged or persisted.
//

import Foundation

nonisolated struct Redaction {
    /// Input with each sensitive span replaced by a typed placeholder.
    let text: String
    /// placeholder -> original. In-memory only; never log or persist.
    let mapping: [String: String]

    /// Restore any placeholders the cloud response echoed back. Order-independent:
    /// placeholders are bracket-delimited, so `[REDACTED_EMAIL_1]` (ending in `]`)
    /// is never a substring of `[REDACTED_EMAIL_11]`.
    func rehydrate(_ input: String) -> String {
        var out = input
        for (placeholder, original) in mapping where out.contains(placeholder) {
            out = out.replacingOccurrences(of: placeholder, with: original)
        }
        return out
    }
}

private nonisolated struct Detector {
    let kind: String
    let regex: NSRegularExpression
    let validate: (@Sendable (String) -> Bool)?
}

private nonisolated func makeRegex(_ pattern: String, dotAll: Bool = false) -> NSRegularExpression {
    // Patterns are fixed literals ported from the working Rust; try! is a build-time
    // assertion they compile, not runtime input handling.
    try! NSRegularExpression(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : [])
}

private enum RedactorRegistry {
    // Highest priority first (index 0 wins overlap ties). Built once; NSRegularExpression
    // is safe for concurrent matching, so nonisolated(unsafe) on the immutable literal.
    nonisolated(unsafe) static let detectors: [Detector] = [
        Detector(kind: "PRIVATE_KEY",
                 regex: makeRegex(#"-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----.*?-----END[A-Z0-9 ]*PRIVATE KEY-----"#, dotAll: true),
                 validate: nil),
        Detector(kind: "AWS_KEY",        regex: makeRegex(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),      validate: nil),
        Detector(kind: "SLACK_TOKEN",    regex: makeRegex(#"\bxox[baprs]-[0-9A-Za-z-]{10,}"#),     validate: nil),
        Detector(kind: "GITHUB_TOKEN",   regex: makeRegex(#"\bgh[posru]_[0-9A-Za-z]{20,}"#),       validate: nil),
        Detector(kind: "GOOGLE_API_KEY", regex: makeRegex(#"\bAIza[0-9A-Za-z_\-]{35}"#),           validate: nil),
        Detector(kind: "API_KEY",        regex: makeRegex(#"\bsk-(?:proj-)?[0-9A-Za-z_\-]{16,}"#), validate: nil),
        Detector(kind: "BEARER_TOKEN",   regex: makeRegex(#"\bBearer\s+[0-9A-Za-z._\-]{12,}"#),    validate: nil),
        Detector(kind: "EMAIL",          regex: makeRegex(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#), validate: nil),
        Detector(kind: "CARD",           regex: makeRegex(#"\b\d(?:[ \-]?\d){12,18}\b"#),          validate: luhnValid),
        Detector(kind: "PHONE",          regex: makeRegex(#"\+?\d[\d\s().\-]{5,}\d"#),             validate: isPhone),
        Detector(kind: "SECRET",         regex: makeRegex(#"[A-Za-z0-9]{28,}"#),                   validate: isHighEntropySecret),
    ]
}

nonisolated func redact(_ text: String) -> Redaction {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)

    struct Candidate { let start: Int; let end: Int; let priority: Int; let kind: String; let value: String }
    var candidates: [Candidate] = []
    for (priority, det) in RedactorRegistry.detectors.enumerated() {
        for m in det.regex.matches(in: text, range: full) {
            let value = ns.substring(with: m.range)
            if det.validate?(value) ?? true {
                candidates.append(Candidate(start: m.range.location,
                                            end: m.range.location + m.range.length,
                                            priority: priority, kind: det.kind, value: value))
            }
        }
    }
    // Earliest start wins; ties by detector priority (lower index = higher). Greedy keep.
    candidates.sort { $0.start != $1.start ? $0.start < $1.start : $0.priority < $1.priority }
    var accepted: [Candidate] = []
    var lastEnd = 0
    for c in candidates where c.start >= lastEnd {
        lastEnd = c.end
        accepted.append(c)
    }
    // Stable typed placeholders; build output in one pass over NSString ranges.
    var mapping: [String: String] = [:]
    var placeholderFor: [String: String] = [:]
    var counters: [String: Int] = [:]
    var out = ""
    var cursor = 0
    for m in accepted {
        let placeholder: String
        if let existing = placeholderFor[m.value] {
            placeholder = existing
        } else {
            let n = (counters[m.kind] ?? 0) + 1
            counters[m.kind] = n
            placeholder = "[REDACTED_\(m.kind)_\(n)]"
            placeholderFor[m.value] = placeholder
            mapping[placeholder] = m.value
        }
        out += ns.substring(with: NSRange(location: cursor, length: m.start - cursor))
        out += placeholder
        cursor = m.end
    }
    out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
    return Redaction(text: out, mapping: mapping)
}

// MARK: Validators (ported line-for-line)

private nonisolated func luhnValid(_ s: String) -> Bool {
    let digits = s.unicodeScalars.compactMap { ("0"..."9").contains($0) ? Int($0.value - 48) : nil }
    guard (13...19).contains(digits.count) else { return false }
    var sum = 0, double = false
    for d in digits.reversed() {
        var x = d
        if double { x *= 2; if x > 9 { x -= 9 } }
        sum += x
        double.toggle()
    }
    return sum % 10 == 0
}

private nonisolated func isPhone(_ s: String) -> Bool {
    let digitCount = s.filter { $0.isASCII && $0.isNumber }.count
    guard (7...15).contains(digitCount) else { return false }
    let plus = s.drop(while: { $0.isWhitespace }).first == "+"
    let seps = s.filter { " -().".contains($0) }.count
    return (plus && digitCount >= 8) || (seps >= 1 && digitCount >= 10)
}

private nonisolated func isHighEntropySecret(_ s: String) -> Bool {
    guard s.count >= 28 else { return false }
    let hasDigit = s.contains { $0.isASCII && $0.isNumber }
    let hasAlpha = s.contains { $0.isASCII && $0.isLetter }
    return hasDigit && hasAlpha && shannonEntropy(s) >= 3.2
}

private nonisolated func shannonEntropy(_ s: String) -> Double {
    let bytes = Array(s.utf8)
    guard !bytes.isEmpty else { return 0 }
    var counts = [Int](repeating: 0, count: 256)
    for b in bytes { counts[Int(b)] += 1 }
    let len = Double(bytes.count)
    return counts.filter { $0 > 0 }.reduce(0.0) { acc, c in
        let p = Double(c) / len
        return acc - p * log2(p)
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 245 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Polish/Redactor.swift omwhisper-nativeTests/RedactorTests.swift
git commit -m "feat(polish): port the redactor (secret/PII scrub + rehydrate)"
```

---

### Task 2: Generalize `Keychain` for the cloud-LLM key

**Files:**
- Modify: `omwhisper-native/Transcription/Keychain.swift`
- Test: `omwhisper-nativeTests/KeychainTests.swift` (append)

**Interfaces:**
- Produces: `Keychain.loadCloudLLMKey()`/`saveCloudLLMKey(_:)`/`deleteCloudLLMKey()`.
- The M4.2 `loadAssemblyAIKey`/`save`/`delete` keep working (delegate to the new private core).

- [ ] **Step 1: Write the failing test (append to `KeychainTests.swift`)**

Add a test method to the existing `KeychainTests` suite:

```swift
    @Test func cloudLLMKeyRoundTrip() throws {
        try Keychain.deleteCloudLLMKey()
        #expect(Keychain.loadCloudLLMKey() == nil)
        try Keychain.saveCloudLLMKey("sk-test-123")
        #expect(Keychain.loadCloudLLMKey() == "sk-test-123")
        try Keychain.saveCloudLLMKey("sk-test-456")   // overwrite
        #expect(Keychain.loadCloudLLMKey() == "sk-test-456")
        try Keychain.deleteCloudLLMKey()
        #expect(Keychain.loadCloudLLMKey() == nil)
    }
```

(If `KeychainTests` is a `struct`, add the method inside it. Match the existing file's import
and suite declaration.)

- [ ] **Step 2: Run — expect FAIL** (`cannot find … loadCloudLLMKey`)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|loadCloudLLMKey"`
Expected: a compile error about the missing cloud-key members.

- [ ] **Step 3: Refactor `Keychain.swift` to a generic core + delegators**

Replace the body of `enum Keychain` so the AssemblyAI methods delegate to a private
account-parameterized core, and add the cloud-LLM methods:

```swift
nonisolated enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.omwhisper.mac"
    private static let assemblyAIAccount = "assemblyai-api-key"
    private static let cloudLLMAccount = "cloud-llm-api-key"

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let status): return "Couldn't access the Keychain (status \(status))."
            }
        }
    }

    // MARK: AssemblyAI (M4.2 CloudEngine)
    static func loadAssemblyAIKey() -> String? { load(account: assemblyAIAccount) }
    static func saveAssemblyAIKey(_ key: String) throws { try save(key, account: assemblyAIAccount) }
    static func deleteAssemblyAIKey() throws { try delete(account: assemblyAIAccount) }

    // MARK: Cloud polish LLM (M3-2b)
    static func loadCloudLLMKey() -> String? { load(account: cloudLLMAccount) }
    static func saveCloudLLMKey(_ key: String) throws { try save(key, account: cloudLLMAccount) }
    static func deleteCloudLLMKey() throws { try delete(account: cloudLLMAccount) }

    // MARK: Generic core

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if load(account: account) != nil {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        } else {
            var attributes = query
            attributes[kSecValueData as String] = data
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        }
    }

    private static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
```

(Keep the file's existing `import Foundation` / `import Security`.)

- [ ] **Step 4: Run — expect PASS + M4.2 KeychainTests still green**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 246 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Transcription/Keychain.swift omwhisper-nativeTests/KeychainTests.swift
git commit -m "refactor(keychain): generic account core + cloud-LLM key (M4.2 path unchanged)"
```

---

### Task 3: `CloudLLM` backend

**Files:**
- Create: `omwhisper-native/Polish/CloudLLM.swift`
- Test: `omwhisper-nativeTests/CloudLLMTests.swift` (create)

**Interfaces:**
- Consumes: `PolishBackend`, `PolishStyle.systemPrompt` (2a), `stripLLMWrapper` (2a), `redact` (Task 1).
- Produces: `CloudLLM(apiURL:model:apiKey:)`, `CloudLLM.testConnection(apiURL:model:apiKey:)`, and
  static helpers `completionsURL`/`requestBody`/`parseContent`/`placeholderInstruction`.

- [ ] **Step 1: Write the failing test (pure helpers — no network)**

Create `omwhisper-nativeTests/CloudLLMTests.swift`:

```swift
import Foundation
import Testing
@testable import OmWhisper

struct CloudLLMTests {
    @Test func buildsCompletionsURLTrimmingTrailingSlash() {
        #expect(CloudLLM.completionsURL(apiURL: "https://api.openai.com/v1")?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(CloudLLM.completionsURL(apiURL: "https://api.openai.com/v1/")?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test func requestBodyHasTemperatureAndSystemUserMessages() throws {
        let data = CloudLLM.requestBody(model: "gpt-4o-mini", systemPrompt: "Be concise.", userText: "hi there")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["model"] as? String == "gpt-4o-mini")
        #expect((obj["temperature"] as? Double) == 0.3)
        let messages = obj["messages"] as! [[String: String]]
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "Be concise.")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "hi there")
    }

    @Test func parsesContentTrimmed() {
        let data = Data(#"{"choices":[{"message":{"content":"  polished  "}}]}"#.utf8)
        #expect(CloudLLM.parseContent(data) == "polished")
    }

    @Test func parseContentNilOnMalformedOrEmptyChoices() {
        #expect(CloudLLM.parseContent(Data("nope".utf8)) == nil)
        #expect(CloudLLM.parseContent(Data(#"{"choices":[]}"#.utf8)) == nil)
    }

    @Test func placeholderInstructionAppendsOnlyWhenRedacted() {
        #expect(CloudLLM.placeholderInstruction("Base.", redactedAny: false) == "Base.")
        let withClause = CloudLLM.placeholderInstruction("Base.", redactedAny: true)
        #expect(withClause.hasPrefix("Base."))
        #expect(withClause.contains("[REDACTED_TYPE_N]"))
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'CloudLLM'`)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|cannot find 'CloudLLM'"`
Expected: `cannot find 'CloudLLM' in scope`.

- [ ] **Step 3: Implement `CloudLLM.swift`**

Create `omwhisper-native/Polish/CloudLLM.swift`:

```swift
//
//  CloudLLM.swift
//  OmWhisper
//
//  PolishBackend backed by an OpenAI-compatible hosted API (POST /chat/completions).
//  The ONE place polish text leaves the device — so polish() redacts (Redactor.swift)
//  before egress and re-hydrates the response, unconditionally and fail-closed. Pure
//  helpers are unit-tested; the network round-trip is verified live. See
//  docs/superpowers/specs/2026-07-10-m3-2b-cloud-polish-backend-design.md.
//
//  nonisolated: the MainActor-by-default project setting would otherwise pin the type,
//  breaking `nonisolated func polish` and the pure-function tests.
//

import Foundation

nonisolated struct CloudLLM: PolishBackend {
    var apiURL: String
    var model: String
    var apiKey: String

    private static let timeout: TimeInterval = 30

    enum CloudLLMError: Error, LocalizedError {
        case badURL, unreachable, httpStatus(Int), emptyResponse
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid API URL."
            case .unreachable: return "Couldn't reach the API. Check the URL and your connection."
            case .httpStatus(let code): return "The API returned HTTP \(code)."
            case .emptyResponse: return "The API returned an empty response."
            }
        }
    }

    // MARK: Pure helpers (unit-tested)

    static func completionsURL(apiURL: String) -> URL? {
        var base = apiURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/chat/completions")
    }

    private struct ChatMessage: Codable { let role: String; let content: String }
    private struct ChatRequest: Codable { let model: String; let messages: [ChatMessage]; let temperature: Double }
    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }

    static func requestBody(model: String, systemPrompt: String, userText: String) -> Data {
        let req = ChatRequest(model: model, messages: [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userText),
        ], temperature: 0.3)
        return (try? JSONEncoder().encode(req)) ?? Data()
    }

    static func parseContent(_ data: Data) -> String? {
        guard let resp = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = resp.choices.first?.message.content else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func placeholderInstruction(_ base: String, redactedAny: Bool) -> String {
        guard redactedAny else { return base }
        return base + "\n\nSome values in the text are placeholders of the form [REDACTED_TYPE_N]. "
            + "Keep every such placeholder exactly as-is in your output — do not alter, translate, "
            + "remove, or comment on them."
    }

    // MARK: PolishBackend

    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        let redaction = redact(text)   // scrub first, always
        let system = Self.placeholderInstruction(
            style.systemPrompt(targetLanguage: targetLanguage),
            redactedAny: !redaction.mapping.isEmpty
        )
        let content = try await complete(system: system, user: redaction.text, timeout: Self.timeout)
        return redaction.rehydrate(stripLLMWrapper(content))
    }

    private func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        guard let url = Self.completionsURL(apiURL: apiURL) else { throw CloudLLMError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = Self.requestBody(model: model, systemPrompt: system, userText: user)
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudLLMError.unreachable
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudLLMError.httpStatus(http.statusCode)
        }
        guard let content = Self.parseContent(data), !content.isEmpty else {
            throw CloudLLMError.emptyResponse
        }
        return content
    }

    // MARK: Settings test-connection

    /// nil on success; a human-readable error string on failure. Sends a tiny probe
    /// (no redaction needed — "Hello." has nothing to scrub).
    static func testConnection(apiURL: String, model: String, apiKey: String) async -> String? {
        do {
            _ = try await CloudLLM(apiURL: apiURL, model: model, apiKey: apiKey)
                .complete(system: "Reply with exactly: OK", user: "Hello.", timeout: 10)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 251 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Polish/CloudLLM.swift omwhisper-nativeTests/CloudLLMTests.swift
git commit -m "feat(polish): add CloudLLM backend (redact → chat/completions → rehydrate)"
```

---

### Task 4: Wire `.cloud` into `AppState`

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `CloudLLM` (Task 3), `Keychain.loadCloudLLMKey` (Task 2).
- Produces: `PolishBackendKind.cloud`, `AppState.cloudAPIURL`, `AppState.cloudModel`.

- [ ] **Step 1: Add the enum case + settings keys**

Change the enum:
```swift
nonisolated enum PolishBackendKind: String, Codable, CaseIterable {
    case disabled, system, ollama, cloud
}
```

In `SettingsKeys`, add:
```swift
    static let cloudAPIURL = "cloudAPIURL"
    static let cloudModel = "cloudModel"
```

- [ ] **Step 2: Add the two settings (after `ollamaModel`)**

```swift
    var cloudAPIURL: String {
        get {
            access(keyPath: \.cloudAPIURL)
            return UserDefaults.standard.string(forKey: SettingsKeys.cloudAPIURL) ?? "https://api.openai.com/v1"
        }
        set {
            withMutation(keyPath: \.cloudAPIURL) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.cloudAPIURL)
            }
        }
    }
    var cloudModel: String {
        get {
            access(keyPath: \.cloudModel)
            return UserDefaults.standard.string(forKey: SettingsKeys.cloudModel) ?? "gpt-4o-mini"
        }
        set {
            withMutation(keyPath: \.cloudModel) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.cloudModel)
            }
        }
    }
```

- [ ] **Step 3: Add the `.cloud` case to `activePolishBackend()`**

In `activePolishBackend()`, add the case (keychain read on demand; no key → nil → raw fallback):
```swift
        case .cloud:
            guard let key = Keychain.loadCloudLLMKey(), !key.isEmpty else { return nil }
            return CloudLLM(apiURL: cloudAPIURL, model: cloudModel, apiKey: key)
```

(`polishedText(for:)` and `draftAndStream(...)` are unchanged — they already route through
`activePolishBackend()`.)

- [ ] **Step 4: Build + full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 251 tests (no new tests; build-green + suite-green is the
regression proof, matching how prior settings were added).

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "feat(polish): add Cloud backend to activePolishBackend dispatch"
```

---

### Task 5: Cloud config UI in the AI Polish settings

**Files:**
- Modify: `omwhisper-native/UI/AISettingsView.swift`

**Interfaces:**
- Consumes: `CloudLLM.testConnection` (Task 3), `Keychain.*CloudLLMKey` (Task 2),
  `AppState.cloudAPIURL`/`cloudModel`.

- [ ] **Step 1: Add local state for the key + test**

Below the Ollama `@State` in `AISettingsView`:
```swift
    @State private var cloudKeyInput = ""
    @State private var cloudHasSavedKey = false
    @State private var cloudTesting = false
    @State private var cloudTestResult: String?
```

- [ ] **Step 2: Add the Cloud radio tag**

In the Backend `Picker`, after the Ollama row:
```swift
                    Text("Cloud (OpenAI-compatible)").tag(PolishBackendKind.cloud)
```

- [ ] **Step 3: Add the reveal section**

After the `if state.polishBackend == .ollama { … }` block, add:
```swift
            if state.polishBackend == .cloud {
                PorcelainSection(eyebrow: "Cloud") {
                    Text("Your dictated text is sent to this provider while polishing. Secrets and PII (emails, keys, cards) are redacted before it leaves your Mac. Requires your own API key.")
                        .font(.caption)
                        .foregroundStyle(Color.Porcelain.dim)
                    TextField("API URL", text: $state.cloudAPIURL).porcelainField()
                    TextField("Model", text: $state.cloudModel).porcelainField()
                    SecureField("API key", text: $cloudKeyInput).porcelainField()
                    HStack {
                        Button("Save", action: saveCloudKey).disabled(cloudKeyInput.isEmpty)
                        Button("Clear", action: clearCloudKey).disabled(!cloudHasSavedKey)
                        Button(cloudTesting ? "Testing…" : "Test Connection", action: testCloud)
                            .disabled(cloudTesting || !cloudHasSavedKey)
                    }
                    Text(cloudHasSavedKey ? "Key saved." : "No key saved yet.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    if let cloudTestResult {
                        Text(cloudTestResult)
                            .font(.caption)
                            .foregroundStyle(cloudTestResult == "Connected." ? Color.Porcelain.dim : .red)
                    }
                }
            }
```

- [ ] **Step 4: Add the helpers + load saved-state**

Add these methods (alongside `testOllama`):
```swift
    private func saveCloudKey() {
        do { try Keychain.saveCloudLLMKey(cloudKeyInput); cloudKeyInput = ""; cloudHasSavedKey = true; cloudTestResult = nil }
        catch { cloudTestResult = error.localizedDescription }
    }

    private func clearCloudKey() {
        try? Keychain.deleteCloudLLMKey()
        cloudHasSavedKey = false
        cloudTestResult = nil
    }

    private func testCloud() {
        cloudTesting = true
        cloudTestResult = nil
        Task {
            let key = Keychain.loadCloudLLMKey() ?? ""
            let err = await CloudLLM.testConnection(apiURL: appState.cloudAPIURL, model: appState.cloudModel, apiKey: key)
            cloudTestResult = err ?? "Connected."
            cloudTesting = false
        }
    }
```

And reflect the saved key on appear — add a `.task` to the `PorcelainPage` (or the existing
body's outermost view):
```swift
        .task { cloudHasSavedKey = Keychain.loadCloudLLMKey() != nil }
```

(If a `.task` already exists on the body, merge this line into it.)

- [ ] **Step 5: Build + suite (UI verified live — no unit test, per convention)**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 251 tests.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/UI/AISettingsView.swift
git commit -m "feat(hub): Cloud backend config + key management + test-connection UI"
```

---

### Task 6: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Flip the M3 status cell and append an M3-2b note**

Status cell → `🔶 Sub-project 1 + 2 (2a Ollama + 2b Cloud) shipped` (M3 sub-project 2 now
complete). Append a note summarizing: `Polish/Redactor.swift` (faithful `NSRegularExpression`
port of the old app's 10-detector redactor + Luhn/phone/entropy validators + overlap resolution
+ stable placeholders + `rehydrate`, ~11 ported tests); `Polish/CloudLLM.swift`
(redact → `/chat/completions` Bearer temp-0.3 → `stripLLMWrapper` → rehydrate, fail-closed;
pure helpers tested + `testConnection`); generalized `Keychain` (private account core; M4.2
AssemblyAI path unchanged; new cloud-LLM key methods); `.cloud` added to `activePolishBackend()`
so dictation polish **and Reply Assist** get Cloud (auto-redacted) for free; `cloudAPIURL`
(default `https://api.openai.com/v1`)/`cloudModel` (default `gpt-4o-mini`) settings, key in
Keychain; AI Polish Cloud config section (URL/model/key + Save/Clear/Test + upfront redaction
privacy line). Note the deliberate scope: Chronicler stays System-only; redaction is cloud-only
(System/Ollama on-device). State tests added and the count (~262), and that the live provider
round-trip is owed (needs a real API key) — matching M4.2/2a's "pure pieces tested, live
separate" status.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: M3-2b Cloud polish backend shipped — M3 sub-project 2 complete"
```
