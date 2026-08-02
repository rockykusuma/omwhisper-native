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
    /// Seconds. Defaults to the dictation figure -- see `dictationTimeout`.
    var timeout: TimeInterval = dictationTimeout

    /// The paste path can afford to give up: its raw-text fallback means a slow
    /// model costs the polish, not the words. Kept short so a paste is never
    /// held hostage.
    static let dictationTimeout: TimeInterval = 30

    /// Meetings and chronicles have NO fallback and the user is deliberately
    /// waiting, so they get room for a cold model load. Measured 2026-08-02:
    /// gemma4:8b answered in 5s warm but **36.4s from cold**, and Ollama evicts
    /// after ~5 minutes idle -- so at 30s the FIRST summary after any break
    /// failed every time, reported as "Couldn't reach Ollama".
    static let longFormTimeout: TimeInterval = 300

    enum OllamaError: Error, LocalizedError {
        case badURL, unreachable, timedOut(TimeInterval), httpStatus(Int), emptyResponse
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid Ollama URL."
            case .unreachable: return "Couldn't reach Ollama. Is it running?"
            case .timedOut(let seconds):
                // NOT "is it running?" -- it was. Conflating these sent people
                // to check a service that was already up.
                return "Ollama didn't respond within \(Int(seconds))s. A large model "
                     + "can take longer than that to load the first time — try again, "
                     + "or pick a smaller model."
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
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OllamaError.timedOut(timeout)
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
