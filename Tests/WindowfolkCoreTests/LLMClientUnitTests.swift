import Foundation
import Testing
@testable import WindowfolkCore

/// LLMRequestConfig 与 FakeLLMClient 的单元测试（任务 11.5，Requirement 19.2）。
/// 返回值校验属性（Property 34）和超时测试在 LLMTests.swift（任务 11.6）。
@Suite struct LLMClientUnitTests {
    private let config = LLMRequestConfig(
        endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
        model: "gpt-test", apiKey: "sk-secret-123456")

    private func payload(_ name: ResidentName) -> PromptPayload {
        PromptPayload(
            purpose: .thought(name), localDate: LocalDate(year: 2026, month: 10, day: 20),
            events: [], timeZone: TimeZone(identifier: "UTC")!)
    }

    @Test func configTextNeverContainsAPIKey() {
        var dumped = ""
        dump(config, to: &dumped)
        for text in [config.description, config.debugDescription, "\(config)", String(reflecting: config), dumped] {
            #expect(!text.contains(config.apiKey))
            #expect(text.contains("***"))
        }
        #expect(config.description.contains("gpt-test"))
    }

    @Test func fakeFollowsScriptThenRepeatsLast() async {
        let fake = FakeLLMClient([.text("你好"), .failure(.httpStatus(500)), .timeout, .text("  \n")])
        var results: [LLMResult] = []
        for _ in 0..<6 { results.append(await fake.complete(payload(.dudu), config: config)) }
        #expect(results == [
            .success("你好"), .failure(.httpStatus(500)), .failure(.timeout),
            .failure(.emptyText), .failure(.emptyText), .failure(.emptyText),
        ])
        #expect(await fake.requestCount == 6)
    }

    @Test func fakeRecordsPayloadsInOrder() async {
        let fake = FakeLLMClient([.text("ok")])
        _ = await fake.complete(payload(.dudu), config: config)
        _ = await fake.complete(payload(.doodoo), config: config)
        #expect(await fake.payloads == [payload(.dudu), payload(.doodoo)])
    }

    @Test func emptyScriptFailsWithTransport() async {
        let fake = FakeLLMClient([])
        #expect(await fake.complete(payload(.dudu), config: config) == .failure(.transport))
        #expect(await fake.requestCount == 1)
    }

    @Test func clientIsUsableThroughProtocol() async {
        let client: any LLMClient = FakeLLMClient([.text("嗯")])
        let r = await LLMTimeout.run(.seconds(5)) { await client.complete(payload(.dudu), config: config) }
        #expect(r == .success("嗯"))
    }
}
