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

@Suite("Ollama timeouts")
struct OllamaTimeoutTests {
    @Test("a timeout does not claim Ollama is down")
    func timeoutIsNotReportedAsUnreachable() {
        let timedOut = Ollama.OllamaError.timedOut(300).errorDescription ?? ""
        // Measured: gemma4:8b takes 36.4s from cold vs 5s warm, and Ollama
        // evicts after ~5 min idle. Every URLSession failure used to become
        // "Couldn't reach Ollama. Is it running?" — sending people to check a
        // service that was already up.
        #expect(!timedOut.localizedCaseInsensitiveContains("is it running"))
        #expect(timedOut.contains("300"))
        #expect(Ollama.OllamaError.unreachable.errorDescription?
            .localizedCaseInsensitiveContains("is it running") == true)
    }

    @Test("long-form work gets more room than the paste path")
    func longFormTimeoutExceedsDictation() {
        // Dictation can give up — its fallback pastes the user's own words.
        // A meeting summary has no fallback and the user is deliberately waiting.
        #expect(Ollama.longFormTimeout > Ollama.dictationTimeout)
        #expect(Ollama.dictationTimeout == 30)
        #expect(Ollama(baseURL: "http://x", model: "m").timeout == Ollama.dictationTimeout)
    }
}
