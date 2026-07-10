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
