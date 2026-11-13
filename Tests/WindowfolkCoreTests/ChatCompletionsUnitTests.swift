import Foundation
import Testing
@testable import WindowfolkCore

/// Chat Completions 请求构造与响应解析的单元测试（任务 15.1，Requirement 12.3、12.7）。不发起网络请求。
@Suite struct ChatCompletionsUnitTests {
    private let config = LLMRequestConfig(
        endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
        model: "gpt-test", apiKey: "sk-secret-123456")

    private let payload = PromptPayload(
        purpose: .diary(.dudu), localDate: LocalDate(year: 2026, month: 10, day: 20),
        events: [], timeZone: TimeZone(identifier: "UTC")!)

    @Test func requestPostsToConfiguredEndpointWithBearerHeader() throws {
        let req = try ChatCompletions.makeRequest(payload, config: config)
        #expect(req.url == config.endpoint)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret-123456")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func requestBodyHasModelAndMessagesOnly() throws {
        let req = try ChatCompletions.makeRequest(payload, config: config)
        let data = try #require(req.httpBody)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(config.apiKey))

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["model", "messages"])
        #expect(json["model"] as? String == "gpt-test")
        let messages = try #require(json["messages"] as? [[String: String]])
        let expected = payload.messages()
        #expect(messages.count == expected.count)
        for (m, e) in zip(messages, expected) {
            #expect(m == ["role": e.role, "content": e.content])
        }
        #expect(messages.map { $0["role"] } == ["system", "user"])
    }

    @Test func parsesFirstChoiceContent() {
        let body = #"{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"今天很开心"}},{"message":{"content":"第二个"}}]}"#
        #expect(ChatCompletions.parseResponse(statusCode: 200, data: Data(body.utf8)) == .success("今天很开心"))
    }

    @Test func nonSuccessStatusIsHTTPFailure() {
        let body = Data(#"{"choices":[{"message":{"content":"hi"}}]}"#.utf8)
        for code in [199, 301, 401, 429, 500] {
            #expect(ChatCompletions.parseResponse(statusCode: code, data: body) == .failure(.httpStatus(code)))
        }
        #expect(ChatCompletions.parseResponse(statusCode: 299, data: body) == .success("hi"))
    }

    @Test func malformedBodiesAreInvalidResponse() {
        let bodies = [
            "", "not json", #"{}"#, #"{"choices":[]}"#, #"{"choices":[{"message":{}}]}"#,
            #"{"choices":[{"message":{"content":null}}]}"#, #"{"choices":[{"message":{"content":3}}]}"#,
        ]
        for b in bodies {
            #expect(ChatCompletions.parseResponse(statusCode: 200, data: Data(b.utf8)) == .failure(.invalidResponse))
        }
    }

    @Test func blankContentIsEmptyText() {
        let body = Data(#"{"choices":[{"message":{"content":"  \n\t"}}]}"#.utf8)
        #expect(ChatCompletions.parseResponse(statusCode: 200, data: body) == .failure(.emptyText))
    }
}
