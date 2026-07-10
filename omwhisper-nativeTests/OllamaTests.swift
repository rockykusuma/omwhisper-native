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
