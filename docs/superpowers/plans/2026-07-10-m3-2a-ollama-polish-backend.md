# M3 Sub-project 2a — Ollama Polish Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local **Ollama** model as a selectable AI-polish backend alongside `Disabled`
and `System`, so dictation polish + Reply Assist can run through a user-chosen local model.

**Architecture:** New `Ollama: PolishBackend` conformer (pure testable helpers + effectful
`polish`/`checkStatus`/`listModels`), a shared `PolishStyle.systemPrompt(targetLanguage:)`, a
ported `stripLLMWrapper` post-processor (Ollama-only), one `AppState.activePolishBackend()`
dispatch that both the dictation-polish path and Reply Assist route through, and an Ollama
config section in the AI Polish settings.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), `URLSession`, existing `PolishBackend` protocol,
`PorcelainPage`/`PorcelainSection`/`porcelainField()` UI components. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-10-m3-2a-ollama-polish-backend-design.md`.

## Global Constraints

- **Cloud is out of scope** — this pass is Ollama only (fully local, no egress). Do not add a
  `.cloud` case, Keychain changes, or a redactor.
- **`nonisolated`** on every new type/free function (`Ollama`, `stripLLMWrapper`,
  `PolishStyle.systemPrompt`) — the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` will
  otherwise pin them and break `PolishBackend` conformance / the pure-function tests (the exact
  gotcha `CloudEngine`/`ParakeetEngine` hit).
- **New settings use the `access(keyPath:)`/`withMutation(keyPath:)` pattern** (they back a
  Picker/field that must re-render on change), matching `polishBackend`.
- **Preserve the fail-safe**: any polish failure (disabled, unavailable, unreachable, timeout,
  error, empty model) must return the *original* text — dictated text is never dropped.
- **`SystemLLM` output is left byte-for-byte unchanged** — `stripLLMWrapper` applies to Ollama
  only.
- **UI uses `Color.Porcelain.*` tokens** (adaptive), `PorcelainSection`, `.porcelainField()` —
  no native `Form`/`.roundedBorder`, no adaptive system colors.
- Run `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test` after
  every task; it must end `** TEST SUCCEEDED **`. Baseline is **219** tests; the count grows as
  tasks add tests.

---

### Task 1: `PolishStyle.systemPrompt(targetLanguage:)` + refactor `SystemLLM`

**Files:**
- Modify: `omwhisper-native/Polish/PolishBackend.swift`
- Modify: `omwhisper-native/Polish/SystemLLM.swift`
- Test: `omwhisper-nativeTests/PolishStyleSystemPromptTests.swift` (create)

**Interfaces:**
- Produces: `PolishStyle.systemPrompt(targetLanguage: String?) -> String` — used by every backend.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/PolishStyleSystemPromptTests.swift`:

```swift
import Testing
@testable import OmWhisper

struct PolishStyleSystemPromptTests {
    @Test func nonTranslateReturnsPromptVerbatim() {
        let s = PolishStyle(id: UUID(), name: "Concise", prompt: "Make it concise.", isBuiltIn: true)
        #expect(s.systemPrompt(targetLanguage: "Spanish") == "Make it concise.")
        #expect(s.systemPrompt(targetLanguage: nil) == "Make it concise.")
    }

    @Test func translateSubstitutesLanguage() {
        let s = PolishStyle(id: UUID(), name: "Translate", prompt: "Translate to {language}.",
                            isBuiltIn: true, requiresTargetLanguage: true)
        #expect(s.systemPrompt(targetLanguage: "German") == "Translate to German.")
    }

    @Test func translateWithNilLanguageLeavesPlaceholder() {
        let s = PolishStyle(id: UUID(), name: "Translate", prompt: "Translate to {language}.",
                            isBuiltIn: true, requiresTargetLanguage: true)
        #expect(s.systemPrompt(targetLanguage: nil) == "Translate to {language}.")
    }
}
```

- [ ] **Step 2: Run it — expect FAIL** (no `systemPrompt` member)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|value of type 'PolishStyle' has no member"`
Expected: a compile error about the missing `systemPrompt` member.

- [ ] **Step 3: Add the shared helper**

In `Polish/PolishBackend.swift`, after the `PolishStyle` struct, add:

```swift
nonisolated extension PolishStyle {
    /// The system prompt for this style. Substitutes `{language}` when the style
    /// needs a target language, else returns `prompt` verbatim. Shared by every backend.
    func systemPrompt(targetLanguage: String?) -> String {
        guard requiresTargetLanguage, let targetLanguage else { return prompt }
        return prompt.replacingOccurrences(of: "{language}", with: targetLanguage)
    }
}
```

- [ ] **Step 4: Refactor `SystemLLM` to use it**

In `Polish/SystemLLM.swift`, change `polish(...)`'s first two lines from:

```swift
        let instructions = Self.instructions(for: style, targetLanguage: targetLanguage)
        let session = LanguageModelSession(instructions: instructions)
```
to:
```swift
        let session = LanguageModelSession(instructions: style.systemPrompt(targetLanguage: targetLanguage))
```

and delete the now-unused private helper:

```swift
    private static func instructions(for style: PolishStyle, targetLanguage: String?) -> String {
        guard style.requiresTargetLanguage, let targetLanguage else { return style.prompt }
        return style.prompt.replacingOccurrences(of: "{language}", with: targetLanguage)
    }
```

- [ ] **Step 5: Run — expect PASS + full suite green**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 222 tests.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Polish/PolishBackend.swift omwhisper-native/Polish/SystemLLM.swift omwhisper-nativeTests/PolishStyleSystemPromptTests.swift
git commit -m "refactor(polish): extract shared PolishStyle.systemPrompt(targetLanguage:)"
```

---

### Task 2: `stripLLMWrapper` post-processor

**Files:**
- Create: `omwhisper-native/Polish/PolishPostProcessing.swift`
- Test: `omwhisper-nativeTests/PolishPostProcessingTests.swift` (create)

**Interfaces:**
- Produces: `func stripLLMWrapper(_ input: String) -> String` (nonisolated, module-internal).

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/PolishPostProcessingTests.swift`:

```swift
import Testing
@testable import OmWhisper

struct PolishPostProcessingTests {
    @Test func stripsOutputPrefix() {
        #expect(stripLLMWrapper("Output: Hello world") == "Hello world")
    }

    @Test func stripsHereIsPreamble() {
        #expect(stripLLMWrapper("Here is the polished text:\n\nHello world") == "Hello world")
    }

    @Test func stripsTrailingParentheticalCommentary() {
        #expect(stripLLMWrapper("Hello world\n\n(I removed the filler words)") == "Hello world")
    }

    @Test func stripsInlineTrailingCommentary() {
        #expect(stripLLMWrapper("I went back home. I made some minor adjustments to it.") == "I went back home.")
    }

    @Test func leavesCleanTextUnchanged() {
        #expect(stripLLMWrapper("Just normal text.") == "Just normal text.")
    }

    @Test func leavesMultiParagraphContentUnchanged() {
        let t = "First paragraph here.\n\nSecond paragraph with more detail follows."
        #expect(stripLLMWrapper(t) == t)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (no `stripLLMWrapper`)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|cannot find 'stripLLMWrapper'"`
Expected: `cannot find 'stripLLMWrapper' in scope`.

- [ ] **Step 3: Implement the port**

Create `omwhisper-native/Polish/PolishPostProcessing.swift`:

```swift
//
//  PolishPostProcessing.swift
//  OmWhisper
//
//  Port of the old Tauri app's `strip_llm_wrapper` (src-tauri/src/ai/mod.rs) — trims
//  preamble/postamble that chat models add despite being told not to ("Output:",
//  "Here is the polished text:", trailing "(I removed the filler words)"). Applied to
//  Ollama output only; Foundation Models is well-behaved and left untouched.
//

import Foundation

nonisolated func stripLLMWrapper(_ input: String) -> String {
    var text = input
    if let r = text.range(of: "Output:"), r.lowerBound == text.startIndex {
        text = String(text[r.upperBound...])
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    let lines = text.components(separatedBy: "\n")
    if lines.isEmpty { return text }

    // Drop a leading preamble line ending in ':' that is followed by a blank line.
    var start = 0
    if lines.count > 1,
       lines[0].trimmingCharacters(in: .whitespaces).hasSuffix(":"),
       lines[1].trimmingCharacters(in: .whitespaces).isEmpty {
        start = 2
    }

    // Drop trailing blank / meta-commentary lines.
    var end = lines.count
    while end > start {
        let line = lines[end - 1].trimmingCharacters(in: .whitespaces)
        if line.isEmpty || isMetaCommentary(line) { end -= 1 } else { break }
    }

    if start >= end { return text }

    var result = Array(lines[start..<end])
    if let last = result.last, let stripped = stripInlineCommentary(last) {
        result[result.count - 1] = stripped
    }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isMetaCommentary(_ line: String) -> Bool {
    if line.hasPrefix("(") && line.hasSuffix(")") { return true }
    if line.count >= 150 { return false }
    let lower = line.lowercased()
    let prefixes = [
        "note:", "i removed some", "i removed filler", "i removed the filler",
        "i corrected the", "i corrected some", "i corrected grammar",
        "i cleaned up", "i made some adjustments", "i made some changes",
        "i made some minor", "i adjusted the",
        "let me know if you'd like", "let me know if you need any",
    ]
    if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
    if (lower.hasPrefix("here is") || lower.hasPrefix("here's")),
       line.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
        return true
    }
    return false
}

private func stripInlineCommentary(_ line: String) -> String? {
    for sep in [". ", "! ", "? "] {
        var searchStart = line.startIndex
        while let r = line.range(of: sep, range: searchStart..<line.endIndex) {
            let after = line[r.upperBound...].drop(while: { $0.isWhitespace })
            if after.count < 100, isMetaCommentary(String(after)) {
                // Keep text up to and including the punctuation mark (r.lowerBound).
                let throughPunct = line[...r.lowerBound]
                return String(throughPunct).trimmingCharacters(in: .whitespaces)
            }
            searchStart = r.upperBound
        }
    }
    return nil
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 228 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Polish/PolishPostProcessing.swift omwhisper-nativeTests/PolishPostProcessingTests.swift
git commit -m "feat(polish): port stripLLMWrapper post-processor (Ollama-only)"
```

---

### Task 3: `Ollama` backend (`PolishBackend` conformer + Settings helpers)

**Files:**
- Create: `omwhisper-native/Polish/Ollama.swift`
- Test: `omwhisper-nativeTests/OllamaTests.swift` (create)

**Interfaces:**
- Consumes: `PolishBackend`, `PolishStyle.systemPrompt` (Task 1), `stripLLMWrapper` (Task 2).
- Produces: `Ollama(baseURL:model:)`, `Ollama.checkStatus(baseURL:)`, `Ollama.listModels(baseURL:)`,
  and static pure helpers `chatURL`/`tagsURL`/`requestBody`/`parseChatContent`/`parseModelNames`.

- [ ] **Step 1: Write the failing test (pure helpers only — no network)**

Create `omwhisper-nativeTests/OllamaTests.swift`:

```swift
import Foundation
import Testing
@testable import OmWhisper

struct OllamaTests {
    @Test func buildsChatAndTagsURLsTrimmingTrailingSlash() {
        #expect(Ollama.chatURL(baseURL: "http://localhost:11434")?.absoluteString == "http://localhost:11434/api/chat")
        #expect(Ollama.chatURL(baseURL: "http://localhost:11434/")?.absoluteString == "http://localhost:11434/api/chat")
        #expect(Ollama.tagsURL(baseURL: "http://localhost:11434//")?.absoluteString == "http://localhost:11434/api/tags")
    }

    @Test func requestBodyHasStreamFalseAndSystemUserMessages() throws {
        let data = Ollama.requestBody(model: "llama3.2", systemPrompt: "Be concise.", text: "hi there")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["model"] as? String == "llama3.2")
        #expect(obj["stream"] as? Bool == false)
        let messages = obj["messages"] as! [[String: String]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "Be concise.")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "hi there")
    }

    @Test func parsesChatContentTrimmed() {
        let data = Data(#"{"message":{"content":"  polished text  "}}"#.utf8)
        #expect(Ollama.parseChatContent(data) == "polished text")
    }

    @Test func parseChatContentReturnsNilOnMalformed() {
        #expect(Ollama.parseChatContent(Data("not json".utf8)) == nil)
        #expect(Ollama.parseChatContent(Data(#"{"unexpected":1}"#.utf8)) == nil)
    }

    @Test func parsesModelNames() {
        let data = Data(#"{"models":[{"name":"llama3.2"},{"name":"qwen2.5"}]}"#.utf8)
        #expect(Ollama.parseModelNames(data) == ["llama3.2", "qwen2.5"])
    }

    @Test func parseModelNamesEmptyOnMalformed() {
        #expect(Ollama.parseModelNames(Data("nope".utf8)) == [])
        #expect(Ollama.parseModelNames(Data(#"{"models":[]}"#.utf8)) == [])
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (no `Ollama` type)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|cannot find 'Ollama'"`
Expected: `cannot find 'Ollama' in scope`.

- [ ] **Step 3: Implement `Ollama.swift`**

Create `omwhisper-native/Polish/Ollama.swift`:

```swift
//
//  Ollama.swift
//  OmWhisper
//
//  PolishBackend backed by a local Ollama server (POST /api/chat, stream:false).
//  Fully local — nothing leaves the device. Pure helpers (URL/body/parse) are
//  directly unit-tested; the localhost round-trip is verified live. See
//  docs/superpowers/specs/2026-07-10-m3-2a-ollama-polish-backend-design.md.
//
//  nonisolated: the project's MainActor-by-default would otherwise pin the type,
//  breaking `nonisolated func polish` (PolishBackend) and the pure-function tests
//  — same gotcha CloudEngine/ParakeetEngine hit.
//

import Foundation

nonisolated struct Ollama: PolishBackend {
    var baseURL: String
    var model: String

    // ponytail: fixed 30s ceiling — Ollama's first response can include a model
    // load; the paste path's raw-text fallback already covers a timeout. Promote
    // to a user setting only if people with big models ask.
    private static let timeout: TimeInterval = 30

    enum OllamaError: Error, LocalizedError {
        case badURL, unreachable, httpStatus(Int), emptyResponse
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid Ollama URL."
            case .unreachable: return "Couldn't reach Ollama. Is it running?"
            case .httpStatus(let code): return "Ollama returned HTTP \(code)."
            case .emptyResponse: return "Ollama returned an empty response."
            }
        }
    }

    // MARK: Pure helpers (unit-tested)

    static func chatURL(baseURL: String) -> URL? { URL(string: trimTrailingSlashes(baseURL) + "/api/chat") }
    static func tagsURL(baseURL: String) -> URL? { URL(string: trimTrailingSlashes(baseURL) + "/api/tags") }

    private static func trimTrailingSlashes(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    private struct ChatMessage: Codable { let role: String; let content: String }
    private struct ChatRequest: Codable { let model: String; let stream: Bool; let messages: [ChatMessage] }
    private struct ChatResponse: Decodable { struct Message: Decodable { let content: String }; let message: Message }
    private struct TagsResponse: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }

    static func requestBody(model: String, systemPrompt: String, text: String) -> Data {
        let req = ChatRequest(model: model, stream: false, messages: [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: text),
        ])
        return (try? JSONEncoder().encode(req)) ?? Data()
    }

    static func parseChatContent(_ data: Data) -> String? {
        guard let resp = try? JSONDecoder().decode(ChatResponse.self, from: data) else { return nil }
        return resp.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseModelNames(_ data: Data) -> [String] {
        guard let resp = try? JSONDecoder().decode(TagsResponse.self, from: data) else { return [] }
        return resp.models.map(\.name)
    }

    // MARK: PolishBackend

    func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
        guard let url = Self.chatURL(baseURL: baseURL) else { throw OllamaError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.requestBody(
            model: model,
            systemPrompt: style.systemPrompt(targetLanguage: targetLanguage),
            text: text
        )
        request.timeoutInterval = Self.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OllamaError.unreachable
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OllamaError.httpStatus(http.statusCode)
        }
        guard let content = Self.parseChatContent(data), !content.isEmpty else {
            throw OllamaError.emptyResponse
        }
        return stripLLMWrapper(content)
    }

    // MARK: Settings helpers (reachability + model list)

    static func checkStatus(baseURL: String) async -> Bool {
        guard let url = tagsURL(baseURL: baseURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    static func listModels(baseURL: String) async -> [String] {
        guard let url = tagsURL(baseURL: baseURL) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return parseModelNames(data)
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 234 tests.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Polish/Ollama.swift omwhisper-nativeTests/OllamaTests.swift
git commit -m "feat(polish): add Ollama PolishBackend + reachability/model helpers"
```

---

### Task 4: Wire `.ollama` into `AppState`

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `Ollama` (Task 3).
- Produces: `PolishBackendKind.ollama`, `AppState.ollamaBaseURL`, `AppState.ollamaModel`,
  `AppState.activePolishBackend() -> PolishBackend?`.

- [ ] **Step 1: Add the enum case + settings keys**

In `AppState.swift`, change the enum:
```swift
nonisolated enum PolishBackendKind: String, Codable, CaseIterable {
    case disabled, system, ollama
    // Sub-project 2b adds: case cloud
}
```

In `SettingsKeys`, add:
```swift
    static let ollamaBaseURL = "ollamaBaseURL"
    static let ollamaModel = "ollamaModel"
```

- [ ] **Step 2: Add the two settings (near `polishBackend`)**

After the `polishBackend` computed property, add:
```swift
    var ollamaBaseURL: String {
        get {
            access(keyPath: \.ollamaBaseURL)
            return UserDefaults.standard.string(forKey: SettingsKeys.ollamaBaseURL) ?? "http://localhost:11434"
        }
        set {
            withMutation(keyPath: \.ollamaBaseURL) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.ollamaBaseURL)
            }
        }
    }
    var ollamaModel: String {
        get {
            access(keyPath: \.ollamaModel)
            return UserDefaults.standard.string(forKey: SettingsKeys.ollamaModel) ?? ""
        }
        set {
            withMutation(keyPath: \.ollamaModel) {
                UserDefaults.standard.set(newValue, forKey: SettingsKeys.ollamaModel)
            }
        }
    }
```

- [ ] **Step 3: Add the single dispatch point**

Add near `polishedText(for:)`:
```swift
    /// The polish backend the user has configured, or nil when polish shouldn't
    /// run (Disabled, System-but-unavailable, or Ollama with no model chosen).
    /// The single place backend selection happens — both dictation polish and
    /// Reply Assist route through it.
    func activePolishBackend() -> PolishBackend? {
        switch polishBackend {
        case .disabled: return nil
        case .system: return SystemLLM.isAvailable() ? systemLLM : nil
        case .ollama: return ollamaModel.isEmpty ? nil : Ollama(baseURL: ollamaBaseURL, model: ollamaModel)
        }
    }
```

- [ ] **Step 4: Rewrite `polishedText(for:)` to use it**

Replace the body of `polishedText(for:)`:
```swift
    private func polishedText(for original: String) async -> String {
        // The one-time nudge fires only when System is selected but off — not for
        // Disabled or an unconfigured Ollama, which are deliberate "no polish" states.
        if polishBackend == .system, !SystemLLM.isAvailable() {
            if !didNudgeFoundationModelsUnavailable {
                didNudgeFoundationModelsUnavailable = true
                errorMessage = "Apple Intelligence is off — enable it in Settings > AI to use polish, or pasted raw text for now."
            }
            return original
        }
        guard let backend = activePolishBackend(), let style = activePolishStyle else { return original }
        do {
            let target = style.requiresTargetLanguage ? translateTargetLanguage : nil
            return try await backend.polish(original, style: style, targetLanguage: target)
        } catch {
            log.error("polishedText — polish failed: \(error)")
            return original
        }
    }
```

- [ ] **Step 5: Route Reply Assist through the same dispatch**

In `draftAndStream(...)`, replace:
```swift
        guard SystemLLM.isAvailable(), polishBackend == .system else {
            errorMessage = "Reply assist needs the System backend enabled in AI settings."
            return
        }
        let drafted: String
        do {
            drafted = try await systemLLM.polish(intent, style: style, targetLanguage: nil)
        } catch {
```
with:
```swift
        guard let backend = activePolishBackend() else {
            errorMessage = "Reply assist needs an AI polish backend enabled in AI settings."
            return
        }
        let drafted: String
        do {
            drafted = try await backend.polish(intent, style: style, targetLanguage: nil)
        } catch {
```

- [ ] **Step 6: Build + full suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 234 tests (no new tests; the suite staying green plus a clean build is the regression proof, matching how prior settings were added).

- [ ] **Step 7: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "feat(polish): route dictation polish + Reply Assist through activePolishBackend (adds Ollama)"
```

---

### Task 5: Ollama config UI in the AI Polish settings

**Files:**
- Modify: `omwhisper-native/UI/AISettingsView.swift`

**Interfaces:**
- Consumes: `Ollama.checkStatus`/`listModels` (Task 3), `AppState.ollamaBaseURL`/`ollamaModel`.

- [ ] **Step 1: Add local state for the connection check**

In `AISettingsView`, add below the existing `@State` properties:
```swift
    @State private var ollamaReachable: Bool?
    @State private var ollamaModels: [String] = []
    @State private var ollamaChecking = false
```

- [ ] **Step 2: Add the Ollama radio tag**

In the `PorcelainSection(eyebrow: "Backend")` Picker, add a third row after the System row:
```swift
                    Text("Ollama (local)").tag(PolishBackendKind.ollama)
```

- [ ] **Step 3: Add the reveal section**

Immediately after the `PorcelainSection(eyebrow: "Backend") { … }` block, add:
```swift
            if state.polishBackend == .ollama {
                PorcelainSection(eyebrow: "Ollama") {
                    TextField("Base URL", text: $state.ollamaBaseURL).porcelainField()
                    HStack {
                        Button(ollamaChecking ? "Checking…" : "Test Connection") { testOllama(state.ollamaBaseURL) }
                            .disabled(ollamaChecking)
                        if let ollamaReachable {
                            Text(ollamaReachable
                                 ? "Connected — \(ollamaModels.count) model\(ollamaModels.count == 1 ? "" : "s")"
                                 : "Couldn't reach Ollama. Is it running?")
                                .font(.caption)
                                .foregroundStyle(ollamaReachable ? Color.Porcelain.dim : .red)
                        }
                    }
                    if !ollamaModels.isEmpty {
                        Picker("Model", selection: $state.ollamaModel) {
                            Text("Select a model").tag("")
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .tint(Color.Porcelain.emerald)
                        .foregroundStyle(Color.Porcelain.ink)
                    } else if ollamaReachable == true {
                        Text("No models installed — run `ollama pull <model>` in Terminal.")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    } else if !state.ollamaModel.isEmpty {
                        Text("Model: \(state.ollamaModel)")
                            .font(.caption).foregroundStyle(Color.Porcelain.dim)
                    }
                    Text("Runs entirely on your Mac via Ollama. Nothing leaves this device.")
                        .font(.caption).foregroundStyle(Color.Porcelain.dim)
                }
            }
```

- [ ] **Step 4: Add the test-connection helper**

Add a private method to `AISettingsView` (alongside `trimmed`/`addStyle`):
```swift
    private func testOllama(_ baseURL: String) {
        ollamaChecking = true
        Task {
            let reachable = await Ollama.checkStatus(baseURL: baseURL)
            ollamaModels = reachable ? await Ollama.listModels(baseURL: baseURL) : []
            ollamaReachable = reachable
            ollamaChecking = false
        }
    }
```

(The view is `@MainActor` by default, so the `Task` is MainActor-isolated — the `@State`
writes after each `await` are already on the main actor; no `MainActor.run` needed.)

- [ ] **Step 5: Build + suite (UI is verified live, no unit test — project convention)**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | grep -E "error:|Test run with|TEST SUCCEEDED|TEST FAILED"`
Expected: `** TEST SUCCEEDED **`, 234 tests.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/UI/AISettingsView.swift
git commit -m "feat(hub): Ollama backend config + test-connection UI in AI Polish settings"
```

---

### Task 6: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Flip the M3 status cell and append an M3-2a note**

Change the M3 status cell to reflect sub-project 2 being partially shipped (2a Ollama done, 2b
Cloud deferred). Append a note summarizing: `Polish/Ollama.swift` (PolishBackend conformer,
pure helpers tested, localhost round-trip live-verified separately), shared
`PolishStyle.systemPrompt(targetLanguage:)`, ported `stripLLMWrapper` (Ollama-only), the single
`activePolishBackend()` dispatch that both dictation polish and Reply Assist now route through,
`ollamaBaseURL`/`ollamaModel` settings, and the AI Polish Ollama config section
(base-URL + Test Connection → model picker). Note the deliberate scope: Chronicler stays
System-only; Cloud + redaction are 2b. State the tests added (systemPrompt, stripLLMWrapper,
Ollama pure helpers) and that the count is 234, and that live verification against a real
Ollama install is owed.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "📝 docs: M3-2a Ollama polish backend shipped (Cloud/2b deferred)"
```
