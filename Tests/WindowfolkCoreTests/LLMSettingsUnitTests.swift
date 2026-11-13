import Foundation
import Testing
@testable import WindowfolkCore

/// LLMSettings、校验、FileLLMSettingsStore 与 InMemorySecretStore 的例子测试
/// （任务 11.7，Requirement 11.1、11.3、11.4、11.5、11.6、11.9、12.6、19.4）。
/// 只使用临时目录和内存 Key 存储，不访问 `~/Library/Application Support/Windowfolk/` 和钥匙串。
@Suite struct LLMSettingsUnitTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-settings-\(UUID().uuidString)", isDirectory: true)
    }

    private let valid = LLMSettings(diaryEnabled: true, thoughtsEnabled: true,
                                    endpoint: "  https://api.example.com/v1/chat/completions \n",
                                    model: " gpt-4o-mini ")

    @Test func defaultsAreOffAndEmpty() {
        let s = LLMSettings()
        #expect(!s.diaryEnabled && !s.thoughtsEnabled)
        #expect(s.endpoint.isEmpty && s.model.isEmpty)
        #expect(!s.diaryDisclosureAcknowledged && !s.thoughtsDisclosureAcknowledged)
    }

    @Test func validSettingsProduceTrimmedConfig() throws {
        #expect(LLMSettingsValidation.issues(valid, apiKey: " sk-123 ").isEmpty)
        let c = try #require(LLMSettingsValidation.config(valid, apiKey: " sk-123 "))
        #expect(c.endpoint.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(c.model == "gpt-4o-mini")
        #expect(c.apiKey == "sk-123")
        #expect(LLMSettingsValidation.effective(valid, apiKey: "sk-123") == valid)
    }

    @Test func blankFieldsAreReported() {
        let s = LLMSettings(diaryEnabled: true, thoughtsEnabled: true, endpoint: "  ", model: "")
        #expect(LLMSettingsValidation.issues(s, apiKey: "\t") == [.missingEndpoint, .missingModel, .missingAPIKey])
        #expect(LLMSettingsValidation.issues(s, apiKey: nil) == [.missingEndpoint, .missingModel, .missingAPIKey])
        #expect(LLMSettingsValidation.config(s, apiKey: "k") == nil)
        let e = LLMSettingsValidation.effective(s, apiKey: "k")
        #expect(!e.diaryEnabled && !e.thoughtsEnabled)
    }

    @Test(arguments: ["api.example.com", "ftp://example.com/x", "http://", "https:///path", "http:example.com", "://x"])
    func invalidEndpoints(_ endpoint: String) {
        var s = valid
        s.endpoint = endpoint
        #expect(LLMSettingsValidation.issues(s, apiKey: "k") == [.invalidEndpoint])
        #expect(LLMSettingsValidation.config(s, apiKey: "k") == nil)
        #expect(!LLMSettingsValidation.effective(s, apiKey: "k").diaryEnabled)
    }

    @Test(arguments: ["http://localhost:11434/v1/chat/completions", "HTTPS://Example.com"])
    func acceptedEndpoints(_ endpoint: String) {
        var s = valid
        s.endpoint = endpoint
        #expect(LLMSettingsValidation.issues(s, apiKey: "k").isEmpty)
        #expect(LLMSettingsValidation.config(s, apiKey: "k") != nil)
    }

    @Test func keychainFailureCountsAsMissingKey() {
        let failed: Result<String?, SecretStoreError> = .failure(.operationFailed(status: -25300))
        #expect(LLMSettingsValidation.issues(valid, apiKeyResult: failed) == [.missingAPIKey, .keychainFailure])
        #expect(LLMSettingsValidation.config(valid, apiKeyResult: failed) == nil)
        let e = LLMSettingsValidation.effective(valid, apiKeyResult: failed)
        #expect(!e.diaryEnabled && !e.thoughtsEnabled)
        #expect(LLMSettingsValidation.config(valid, apiKeyResult: .success("k")) != nil)
    }

    @Test func fileStoreRoundTripsAndOmitsKey() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileLLMSettingsStore(directory: dir)
        #expect(store.load() == LLMSettings())
        var s = valid
        s.diaryDisclosureAcknowledged = true
        #expect(store.save(s))
        #expect(store.load() == s)
        let text = try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(!text.lowercased().contains("apikey"))
    }

    @Test func fileStoreReturnsDefaultsOnCorruptFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        #expect(FileLLMSettingsStore(directory: dir).load() == LLMSettings())
    }

    @Test func inMemorySecretStore() {
        let store = InMemorySecretStore()
        #expect(store.readAPIKey() == .success(nil))
        #expect((try? store.writeAPIKey("sk-1").get()) != nil)
        #expect(store.readAPIKey() == .success("sk-1"))
        store.failWrites = true
        #expect((try? store.writeAPIKey("sk-2").get()) == nil)
        #expect(store.storedAPIKey == "sk-1")
        store.failWrites = false
        store.failReads = true
        #expect((try? store.readAPIKey().get()) == nil)
        store.failReads = false
        _ = store.writeAPIKey(nil)
        #expect(store.readAPIKey() == .success(nil))
    }
}
