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
